"""Top-level VLM orchestrator for Qwen2.5-VL series (7B Instruct / 32B Stockmark-DocReasoner) on NxDI.

Strategy (simplified after reviewing NxDI main-branch Qwen2-VL source):

  - vision encoder: `NeuronQwen25VisionModel` / `NeuronQwen25VLForImageEncoding`
    from `modeling_qwen25vl_vision.py` (this repo).  Qwen2.5-VL changed the
    vision tower versus Qwen2-VL: norm1/norm2/ln_q changed from LayerNorm
    (weight+bias) to RMSNorm (weight only), and VisionBlock MLP changed from
    fc1+act+fc2 to gate_proj+up_proj+down_proj (SwiGLU).  Using the original
    Qwen2-VL classes produces `missing_keys` for norm.bias and unexpected_keys
    for gate_proj/up_proj/down_proj, causing garbage vision embeddings.
  - text backbone: our existing `NeuronStockmarkTextModel` (M-RoPE aware,
    probe cos=0.999938, 6/6 coherent). We only add an `encode_vision_to_input`
    method on the text model for vision-token scatter.
  - top-level: subclass `NeuronQwen2VLForCausalLM` and swap `text_model_cls`
    to our Stockmark text. Also splice the `convert_hf_to_neuron_state_dict`
    so the text-side conversion goes through our implementation.

The NxDI top-level already handles:
  - 3 NEFF generation (vision + text CTE + text TKG)
  - vision encoder call + `generate_positions_from_mask` + `pad_positions`
  - dummy vision inputs for TKG / text-only path
  - forward() signature compatible with HuggingFaceGenerationAdapter.generate()
"""

import copy
import logging
from typing import Dict, List, Optional, Callable, Type, Tuple, Union

import torch
from transformers.modeling_outputs import CausalLMOutputWithPast

from neuronx_distributed_inference.models.config import NeuronConfig
from neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl import (
    Qwen2VLInferenceConfig,
    Qwen2VLNeuronConfig,
    NeuronQwen2VLForCausalLM,
    QWEN2_VL_TEXT_CONFIG_KEYS,
)
from neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl_text import (
    Qwen2VLTextModelWrapper,
)
from neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl_vision import (
    Qwen2VLVisionModelWrapper,
)
from modeling_qwen25vl_vision import (
    NeuronQwen25VisionModel,
    NeuronQwen25VLForImageEncoding,
)

from modeling_qwen25vl_text import (
    NeuronStockmarkTextModel,
    StockmarkTextNeuronConfig,
    StockmarkTextInferenceConfig,
    NeuronStockmarkTextForCausalLM,
)

logger = logging.getLogger("Neuron")


# ---------------------------------------------------------------------------
# NeuronConfig / InferenceConfig: inherit Qwen2-VL, no structural changes
# ---------------------------------------------------------------------------


class StockmarkVLNeuronConfig(Qwen2VLNeuronConfig):
    """Same structure as Qwen2VLNeuronConfig (default_image_width/height kwargs,
    base NeuronConfig fields). Behaves identically.
    """
    pass


class StockmarkVLInferenceConfig(Qwen2VLInferenceConfig):
    """Qwen2-VL inference config, wired to use StockmarkVLNeuronConfig.

    Adds a `from_pretrained` classmethod that reads HF config.json directly
    (Qwen2.5-VL layout) and forwards text_config / vision_config into the
    ImageToTextInferenceConfig machinery.

    We rely on Qwen2VLInferenceConfig.add_special_config() which sets
    qkv_bias=True / o_bias=False and propagates QWEN2_VL_TEXT_CONFIG_KEYS to
    text_config -- these values match Qwen2.5-VL's Stockmark-DocReasoner.
    """

    @classmethod
    def get_neuron_config_cls(cls) -> Type[NeuronConfig]:
        return StockmarkVLNeuronConfig

    @classmethod
    def from_pretrained(
        cls,
        model_path: str,
        text_neuron_config=None,
        vision_neuron_config=None,
        **kwargs,
    ) -> "StockmarkVLInferenceConfig":
        """Load Qwen2.5-VL config.json and build text_config / vision_config.

        HF Qwen2.5-VL config.json has:
          - top-level: model_type, architectures, vocab_size, vision_token_id,
            image_token_id, video_token_id, vision_start/end_token_id, ...
          - text_config: hidden_size, num_hidden_layers, num_attention_heads,
            num_key_value_heads, rope_theta, rope_scaling, ...
          - vision_config: depth, hidden_size, num_heads, intermediate_size,
            patch_size, spatial_merge_size, temporal_patch_size, ...
        """
        import json as _json
        import os as _os

        cfg_path = _os.path.join(model_path, "config.json")
        with open(cfg_path, "r") as f:
            cfg_dict = _json.load(f)

        # Qwen2.5-VL HF config uses `in_chans` in vision_config; NxDI Qwen2-VL
        # expects `in_channels`, `mlp_ratio`, `embed_dim`. Re-map:
        vision_dict = dict(cfg_dict.get("vision_config", {}))
        if "in_chans" in vision_dict and "in_channels" not in vision_dict:
            vision_dict["in_channels"] = vision_dict["in_chans"]
        # NxDI's Qwen2-VL expects `embed_dim` (== HF `hidden_size` for vision).
        if "embed_dim" not in vision_dict and "hidden_size" in vision_dict:
            vision_dict["embed_dim"] = vision_dict["hidden_size"]
        # NxDI's Qwen2-VL expects `mlp_ratio` (== HF `intermediate_size / hidden_size`).
        if "mlp_ratio" not in vision_dict:
            hs = vision_dict.get("hidden_size") or vision_dict.get("embed_dim")
            ims = vision_dict.get("intermediate_size")
            if hs and ims:
                vision_dict["mlp_ratio"] = ims / hs
        # vision hidden_size in NxDI Qwen2-VL is the text hidden_size (= out_hidden_size).
        # We override so merger knows where to project to.
        if "out_hidden_size" in vision_dict:
            vision_dict["hidden_size"] = vision_dict["out_hidden_size"]

        # The Qwen2.5-VL HF config has two possible layouts:
        #   (a) Stockmark-DocReasoner-VL-32B: text settings nested under text_config
        #   (b) Qwen2.5-VL-7B-Instruct (official): text settings flat at the top level
        # For pattern (b), if text_config is empty, gather text keys from the top level.
        text_dict = dict(cfg_dict.get("text_config", {}))
        if not text_dict:
            # flat layout: extract text keys from the top level
            _text_top_keys = (
                "hidden_size", "num_hidden_layers", "num_attention_heads",
                "num_key_value_heads", "head_dim", "intermediate_size",
                "max_position_embeddings", "rms_norm_eps", "rope_theta",
                "rope_scaling", "hidden_act", "vocab_size",
                "tie_word_embeddings", "torch_dtype", "use_cache",
                "attention_dropout", "initializer_range",
                "max_window_layers", "sliding_window", "use_sliding_window",
            )
            text_dict = {k: cfg_dict[k] for k in _text_top_keys if k in cfg_dict}

        # HF PretrainedConfig defaults required by NxDI model_base
        text_dict.setdefault("output_attentions", False)
        text_dict.setdefault("output_hidden_states", False)
        # The Qwen2.5-VL HF config leaves pad_token_id as None / unset, but NxDI's
        # validate_config() requires text_config.pad_token_id to be present, so we
        # fall back to eos_token_id (Qwen-family conventions treat EOS as PAD).
        if text_dict.get("pad_token_id") is None:
            text_dict["pad_token_id"] = (
                cfg_dict.get("pad_token_id")
                or cfg_dict.get("eos_token_id")
                or text_dict.get("eos_token_id")
            )

        # Build the merged kwargs dict expected by ImageToTextInferenceConfig
        inference_kwargs = {
            "text_config": text_dict,
            "vision_config": vision_dict,
            "_name_or_path": model_path,
        }
        # Top-level VL tokens / architectures
        for key in (
            "architectures", "model_type",
            "image_token_id", "video_token_id",
            "vision_token_id", "vision_start_token_id", "vision_end_token_id",
            "tie_word_embeddings", "vocab_size",
            "bos_token_id", "eos_token_id", "pad_token_id",
        ):
            if key in cfg_dict:
                inference_kwargs[key] = cfg_dict[key]
        # Also propagate the text-side scalars to top level so Qwen2VLInferenceConfig
        # validation (`assert getattr(self, key) == getattr(self.text_config, key)`) passes
        for key in (
            "hidden_size", "num_attention_heads", "num_hidden_layers",
            "num_key_value_heads", "intermediate_size",
            "max_position_embeddings", "rms_norm_eps", "rope_theta",
            "rope_scaling", "hidden_act",
        ):
            if key in text_dict:
                inference_kwargs.setdefault(key, text_dict[key])

        # NxDI Qwen2VLInferenceConfig.add_special_config copies all
        # QWEN2_VL_TEXT_CONFIG_KEYS from `self` to `self.text_config`; any key
        # in that list that is missing on `self` raises AttributeError. Ensure
        # every QWEN2_VL_TEXT_CONFIG_KEYS entry exists at top level, defaulting
        # to None so it becomes a benign attribute on both sides.
        for k in QWEN2_VL_TEXT_CONFIG_KEYS:
            inference_kwargs.setdefault(k, text_dict.get(k, None))

        inference_kwargs.update(kwargs)

        return cls(
            text_neuron_config=text_neuron_config,
            vision_neuron_config=vision_neuron_config,
            **inference_kwargs,
        )


# ---------------------------------------------------------------------------
# Top-level VLM: subclass Qwen2-VL, swap text model class to Stockmark's
# ---------------------------------------------------------------------------


class NeuronStockmarkVLForCausalLM(NeuronQwen2VLForCausalLM):
    """Qwen2.5-VL series VLM for NxDI (handles 7B Instruct and 32B Stockmark-DocReasoner).

    Identical wiring to NeuronQwen2VLForCausalLM except:
    - text_model_cls points to our M-RoPE-aware NeuronStockmarkTextModel
    - convert_hf_to_neuron_state_dict routes text weights through the
      Stockmark text ForCausalLM (which strips `model.` prefix, handles the
      fused_qkv=False layout our text NEFF expects).

    vision_model_cls, text_model_wrapper, vision_model_wrapper, and the
    forward() method are inherited unchanged from Qwen2-VL.
    """

    text_model_cls = NeuronStockmarkTextModel
    vision_model_cls = NeuronQwen25VisionModel

    text_model_wrapper = Qwen2VLTextModelWrapper
    vision_model_wrapper = Qwen2VLVisionModelWrapper

    @staticmethod
    def load_hf_model(model_path, **kwargs):
        """Load the full Qwen2.5-VL checkpoint (text + vision weights).

        We use Qwen2_5_VLForConditionalGeneration so the state_dict contains
        both `model.*` (text) and `visual.*` (vision) keys.
        """
        from transformers import Qwen2_5_VLForConditionalGeneration
        return Qwen2_5_VLForConditionalGeneration.from_pretrained(model_path, **kwargs)

    @staticmethod
    def convert_hf_to_neuron_state_dict(
        state_dict: dict, inference_config: StockmarkVLInferenceConfig
    ) -> dict:
        """Split conversion into vision and text halves.

        NxDI's NeuronQwen2VLForImageEncoding.convert_hf_to_neuron_state_dict
        handles the `visual.*` rename (`.attn.qkv.` -> `.attn.qkv_proj.Wqkv.`,
        `.attn.proj.` -> `.attn.o_proj.`) and inserts global_rank.rank.

        Our NeuronStockmarkTextForCausalLM.convert_hf_to_neuron_state_dict
        strips the `model.` prefix, skips any remaining `visual.*`, and inserts
        the per-layer rank_util tensors our text attention expects.
        """
        # Vision side: Qwen2.5-VL aware remap (RMSNorm + SwiGLU MLP keys)
        state_dict = NeuronQwen25VLForImageEncoding.convert_hf_to_neuron_state_dict(
            state_dict, inference_config
        )
        # Text side via our existing converter
        state_dict = NeuronStockmarkTextForCausalLM.convert_hf_to_neuron_state_dict(
            state_dict, inference_config.text_config
        )
        return state_dict

    @classmethod
    def get_config_cls(cls):
        return StockmarkVLInferenceConfig
