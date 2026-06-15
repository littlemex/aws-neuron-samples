"""Qwen2.5-VL text backbone for NxD Inference.

Based on NxDI's existing `neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl_text`
(Qwen2-VL), adapted for Qwen2.5-VL specific config:
  - 7B variant (Qwen2.5-VL-7B-Instruct):  hidden=3584, layers=28, 28 Q / 4 KV (GQA 7:1)
  - 32B variant (Stockmark-DocReasoner):  hidden=5120, layers=64, 40 Q / 8 KV (GQA 5:1)
  - rope_theta=1e6, rope_scaling={'mrope_section': [16,24,24], 'type': 'default'}
  - tied_word_embeddings=False
  - weight key prefix: `model.*` (pure Qwen2.5-VL), `lm_head.weight`, `visual.*` (skipped here)

Used by `modeling_qwen25vl.py` (top-level VLM) and reused as a standalone
text backbone for sanity_qwen25vl.py.
"""

import gc
import logging
from typing import Optional, Tuple, List, Type

import torch
from torch import nn

from neuronx_distributed.parallel_layers import parallel_state
from neuronx_distributed.parallel_layers.layers import (
    ColumnParallelLinear,
    ParallelEmbedding,
)
from neuronx_distributed.utils import cpu_mode

from neuronx_distributed_inference.models.config import InferenceConfig, NeuronConfig
from neuronx_distributed_inference.models.llama.modeling_llama import NeuronLlamaMLP
from neuronx_distributed_inference.models.model_base import (
    NeuronBaseForCausalLM,
    NeuronBaseModel,
)
from neuronx_distributed_inference.modules.attention.attention_base import (
    NeuronAttentionBase,
)
from neuronx_distributed_inference.modules.attention.utils import _rotate_half
from neuronx_distributed_inference.modules.custom_calls import CustomRMSNorm
from transformers.models.llama.modeling_llama import LlamaRMSNorm

logger = logging.getLogger("Neuron")


# ---------------------------------------------------------------------------
# Multimodal RoPE (identical to Qwen2-VL)
# ---------------------------------------------------------------------------


def apply_multimodal_rotary_pos_emb(q, k, cos, sin, mrope_section, unsqueeze_dim=1):
    mrope_section = mrope_section * 2
    split_indices = [sum(mrope_section[: i + 1]) for i in range(len(mrope_section) - 1)]
    cos = torch.cat(
        [m[i % 3] for i, m in enumerate(torch.tensor_split(cos, split_indices, dim=-1))],
        dim=-1,
    ).unsqueeze(unsqueeze_dim)
    sin = torch.cat(
        [m[i % 3] for i, m in enumerate(torch.tensor_split(sin, split_indices, dim=-1))],
        dim=-1,
    ).unsqueeze(unsqueeze_dim)

    q_embed = (q * cos) + (_rotate_half(q) * sin)
    k_embed = (k * cos) + (_rotate_half(k) * sin)
    return q_embed, k_embed


def get_rmsnorm_cls():
    return LlamaRMSNorm if cpu_mode() else CustomRMSNorm


class NeuronStockmarkTextRotaryEmbedding(nn.Module):
    """3-axis multimodal rotary embedding for Qwen2.5-VL text backbone.

    Takes position_ids of shape [3, batch, seq_len] (temporal/height/width).
    For text-only, all 3 axes contain identical 1-D positions.

    HF Qwen2_5_VLRotaryEmbedding.forward (transformers v4.57.6, L513-L526)
    position_ids contract:
      - input is [3, B, S] (temporal/height/width axes)
      - inv_freq_expanded: [3, B, dim/2, 1]  (uses position_ids.shape[1] = B)
      - position_ids_expanded: [3, B, 1, S]

    The NxDI HuggingFaceGenerationAdapter passes 2D [B, S], so when we
    receive a 2D tensor we replicate it across all 3 axes. For text-only
    runs all 3 axes carry identical values, which matches HF.

    NOTE: at TKG (decode) time the *values* of position_ids that the
    adapter passes are aligned with HF via the rope_delta correction in
    NeuronStockmarkTextForCausalLM.prepare_inputs_for_generation below.
    """

    def __init__(self, config: InferenceConfig, device=None):
        super().__init__()
        self.dim = getattr(
            config, "head_dim", config.hidden_size // config.num_attention_heads
        )
        self.base = getattr(config, "rope_theta", 1000000.0)
        self.attention_scaling = 1.0
        self.register_buffer("inv_freq", None, persistent=False)
        self.inv_freq = self.get_inv_freqs(device)

    def get_inv_freqs(self, device: Optional[torch.device] = None) -> torch.Tensor:
        freq_indices = torch.arange(0, self.dim, 2, dtype=torch.float32, device=device)
        return 1.0 / (self.base ** (freq_indices / self.dim))

    def forward(self, x, position_ids):
        # NxDI standard caller passes position_ids as [B, S] (2-D).
        # Qwen2.5-VL M-RoPE expects [3, B, S] (temporal/height/width).
        # For text-only runs the single axis is replicated 3x -- numerically
        # identical to HF's get_rope_index text-only path (L1128-1133) which
        # also expands 1D positions to 3 equal axes.
        if position_ids.dim() == 2:
            # [B,S] -> [3,B,S]
            position_ids = position_ids.unsqueeze(0).expand(3, -1, -1)
        # position_ids is now [3, B, S]
        # Match HF L516: inv_freq_expanded uses position_ids.shape[1] = B
        inv_freq_expanded = self.inv_freq[None, None, :, None].expand(
            3, position_ids.shape[1], -1, 1
        )
        # Match HF L517: position_ids[:, :, None, :] -> [3, B, 1, S]
        position_ids_expanded = position_ids[:, :, None, :].float()

        device_type = (
            x.device.type
            if isinstance(x.device.type, str) and x.device.type != "mps"
            else "cpu"
        )
        with torch.autocast(device_type=device_type, enabled=False):
            # freqs: [3, B, dim/2, 1] @ [3, B, 1, S] -> [3, B, dim/2, S]
            # .transpose(2,3) -> [3, B, S, dim/2]
            freqs = (inv_freq_expanded.float() @ position_ids_expanded.float()).transpose(
                2, 3
            )
            emb = torch.cat((freqs, freqs), dim=-1)  # [3, B, S, dim]
            cos = emb.cos() * self.attention_scaling
            sin = emb.sin() * self.attention_scaling
        return cos.to(dtype=x.dtype), sin.to(dtype=x.dtype)


# ---------------------------------------------------------------------------
# Attention (GQA, M-RoPE, qkv_bias=True, o_bias=False)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextAttention(NeuronAttentionBase):
    def __init__(self, config: InferenceConfig, tensor_model_parallel_group=None):
        head_dim = getattr(
            config, "head_dim", config.hidden_size // config.num_attention_heads
        )
        super().__init__(
            config=config,
            tensor_model_parallel_group=tensor_model_parallel_group,
            hidden_size=config.hidden_size,
            num_attention_heads=config.num_attention_heads,
            num_key_value_heads=config.num_key_value_heads,
            head_dim=head_dim,
            num_cores_per_group=getattr(config, "num_cores_per_group", 1),
            qkv_bias=True,
            o_bias=False,
            rotary_emb=NeuronStockmarkTextRotaryEmbedding(config),
            rms_norm_eps=config.rms_norm_eps,
        )
        self.rope_theta = config.rope_theta
        self.rope_scaling = config.rope_scaling
        self.mrope_section = config.rope_scaling["mrope_section"]

    def apply_rotary_embedding(
        self, Q, K, V, position_ids, cos_cache, sin_cache, use_polar_compatible_rope
    ):
        # Root cause of TKG divergence (Agent investigation 2026-05-07):
        # NxDI's NeuronAttentionBase passes cos_cache/sin_cache across
        # decoder layers. In the CTE NEFF we computed cos_cache of shape
        # [3, B, S_cte, dim]; when the TKG NEFF starts calling us with
        # position_ids of shape [B, 1], cos_cache is already non-None so
        # the `if cos_cache is None` guard skips the recompute and every
        # decode step reuses CTE's rotary at position ~S_cte-1. This makes
        # the model hallucinate the same token forever (English: "Paris."
        # loop, Japanese: digit/hiragana repetition).
        #
        # Force recompute when the current call is a token-generation step
        # (seq_len == 1 on position_ids) so each new token gets its own
        # correct cos/sin for its absolute position.
        if self.rotary_emb is not None:
            # NxDI propagates cos_cache/sin_cache across decoder layers, which
            # creates a CTE->TKG staleness hazard specific to M-RoPE: the CTE
            # cos_cache has shape [3, B, S_cte, dim] and would be reused for
            # every decode step, pinning RoPE at the last prefill position.
            # M-RoPE is position-dependent so we must recompute per-step.
            # XLA fusion absorbs the cost when shapes are static within a NEFF.
            cos_cache, sin_cache = self.rotary_emb(V, position_ids)
            Q, K = apply_multimodal_rotary_pos_emb(
                Q, K, cos_cache, sin_cache, self.mrope_section
            )
        return Q, K, cos_cache, sin_cache


# ---------------------------------------------------------------------------
# Decoder Layer (pre-norm RMSNorm + attn + MLP)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextDecoderLayer(nn.Module):
    def __init__(self, config: InferenceConfig):
        super().__init__()
        self.hidden_size = config.hidden_size
        self.self_attn = NeuronStockmarkTextAttention(config)
        self.mlp = NeuronLlamaMLP(config)
        self.input_layernorm = get_rmsnorm_cls()(
            config.hidden_size, eps=config.rms_norm_eps
        )
        self.post_attention_layernorm = get_rmsnorm_cls()(
            config.hidden_size, eps=config.rms_norm_eps
        )

    def forward(
        self,
        hidden_states: torch.Tensor,
        attention_mask: Optional[torch.Tensor] = None,
        position_ids: Optional[torch.LongTensor] = None,
        past_key_value=None,
        **kwargs,
    ):
        residual = hidden_states
        hidden_states = self.input_layernorm(hidden_states)

        attn_output = self.self_attn(
            hidden_states=hidden_states,
            attention_mask=attention_mask,
            position_ids=position_ids,
            past_key_value=past_key_value,
            **kwargs,
        )
        # NeuronAttentionBase returns an AttentionOutput namedtuple
        hidden_states_sa = attn_output.hidden_states
        hidden_states = residual + hidden_states_sa

        residual = hidden_states
        hidden_states = self.post_attention_layernorm(hidden_states)
        hidden_states = self.mlp(hidden_states)[0]
        hidden_states = residual + hidden_states

        return (
            hidden_states,
            attn_output.present_key_value,
            attn_output.cos_cache,
            attn_output.sin_cache,
            None,
        )


# ---------------------------------------------------------------------------
# Text Model (pure text, no vision scatter)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextModel(NeuronBaseModel):
    def encode_vision_to_input(self, inputs_embeds, vision_embeddings, vision_mask) -> torch.Tensor:
        """Scatter vision embeddings into text embeddings at <|image_pad|> positions.

        Called by NeuronBaseModel.get_model_output() during context encoding when
        the top-level VLM (NeuronStockmarkVLForCausalLM) passes non-dummy
        vision_embeddings. For text-only forwards vision_mask is filled with
        (pad_limit - 1) so the scatter becomes a no-op.

        Args:
            inputs_embeds: [batch, seq_len, hidden_size] -- text token embeddings
            vision_embeddings: [batch, seq_len, hidden_size] -- padded vision embeds
            vision_mask: [batch, n_active_tokens, 1] int32 position indices

        Returns:
            inputs_embeds with vision positions replaced by vision embeddings.
        """
        from neuronx_distributed_inference.models.llama4.utils.encoder_utils import scatter_by_index_put
        return scatter_by_index_put(inputs_embeds, vision_embeddings, vision_mask)

    def setup_attr_for_model(self, config: InferenceConfig):
        self.on_device_sampling = (
            config.neuron_config.on_device_sampling_config is not None
        )
        self.tp_degree = config.neuron_config.tp_degree
        self.hidden_size = config.hidden_size
        self.num_attention_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.max_batch_size = config.neuron_config.max_batch_size
        self.buckets = config.neuron_config.buckets

    def init_model(self, config: InferenceConfig):
        self.padding_idx = config.pad_token_id
        self.vocab_size = config.vocab_size

        self.embed_tokens = ParallelEmbedding(
            config.vocab_size,
            config.hidden_size,
            config.pad_token_id,
            dtype=config.neuron_config.torch_dtype,
            shard_across_embedding=True,
            pad=True,
        )
        self.layers = nn.ModuleList(
            [
                NeuronStockmarkTextDecoderLayer(config)
                for _ in range(config.num_hidden_layers)
            ]
        )
        self.norm = get_rmsnorm_cls()(config.hidden_size, eps=config.rms_norm_eps)
        self.lm_head = ColumnParallelLinear(
            config.hidden_size,
            config.vocab_size,
            bias=False,
            pad=True,
            gather_output=not self.on_device_sampling,
            dtype=config.neuron_config.torch_dtype,
        )


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


class StockmarkTextNeuronConfig(NeuronConfig):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.attn_cls = NeuronStockmarkTextAttention


class StockmarkTextInferenceConfig(InferenceConfig):
    def add_derived_config(self):
        self.num_cores_per_group = 1
        for attr, default in (
            ("output_attentions", False),
            ("output_hidden_states", False),
            ("return_dict", True),
            ("use_cache", False),
            ("tie_word_embeddings", False),
        ):
            if not hasattr(self, attr):
                setattr(self, attr, default)

    def get_required_attributes(self) -> List[str]:
        return [
            "hidden_size",
            "intermediate_size",
            "num_attention_heads",
            "num_hidden_layers",
            "num_key_value_heads",
            "pad_token_id",
            "vocab_size",
            "max_position_embeddings",
            "rope_theta",
            "rms_norm_eps",
            "hidden_act",
        ]

    @classmethod
    def get_neuron_config_cls(cls) -> Type[StockmarkTextNeuronConfig]:
        return StockmarkTextNeuronConfig


# ---------------------------------------------------------------------------
# For-CausalLM wrapper (weight conversion)
# ---------------------------------------------------------------------------


class NeuronStockmarkTextForCausalLM(NeuronBaseForCausalLM):
    """Qwen2.5-VL series (7B Instruct / 32B Stockmark-DocReasoner) text-only NxDI driver.

    Weight layout (HF → NxDI):
      model.embed_tokens.weight       -> embed_tokens.weight
      model.layers.{i}.self_attn.*    -> layers.{i}.self_attn.*
      model.layers.{i}.mlp.*          -> layers.{i}.mlp.*
      model.layers.{i}.input_layernorm.weight -> layers.{i}.input_layernorm.weight
      model.layers.{i}.post_attention_layernorm.weight -> layers.{i}.post_attention_layernorm.weight
      model.norm.weight                -> norm.weight
      lm_head.weight                   -> lm_head.weight
      visual.*                         -> SKIPPED

    TKG / M-RoPE notes
    ------------------
    Qwen2.5-VL uses M-RoPE (3 axes: temporal/height/width). HF's
    prepare_inputs_for_generation does roughly the following:

      prefill step (cache_position[0]==0):
        get_rope_index() builds [3,B,S] position_ids and saves rope_deltas.
        For text-only inputs rope_deltas is 0 for every batch element.

      decode step (cache_position[0]>0):
        position_ids = cache_position[0] + rope_deltas  (i.e., L + delta)
        replicated across all 3 axes -> [3,B,1].
        For text-only delta=0, so position_ids = [[[L]],[[L]],[[L]]].

    NxDI's HuggingFaceGenerationAdapter always returns 2D [B,1] without
    adding rope_delta. For text-only inputs this is fine because delta=0,
    so the 2D->3D expand inside NeuronStockmarkTextRotaryEmbedding makes
    the adapter values numerically identical to HF.

    If you later add true multimodal inputs (images / video), rope_deltas
    becomes non-zero and the adapter's 2D position_ids will drift from
    HF's 3D values. In that case, enable the rope_delta correction in the
    prepare_inputs_for_generation override below.
    """

    _model_cls = NeuronStockmarkTextModel

    # Cached rope_deltas (saved after prefill, consumed at every decode step).
    # Always zero for text-only inputs; this slot becomes meaningful when
    # multimodal positional offsets are introduced.
    _rope_deltas: Optional[torch.Tensor] = None

    def prepare_inputs_for_generation(self, input_ids, attention_mask=None, **kwargs):
        """Apply M-RoPE rope_delta correction to the adapter's 2D position_ids.

        The HuggingFaceGenerationAdapter returns a 2D [B,S] position_ids,
        which NeuronStockmarkTextRotaryEmbedding broadcasts to 3 axes. For
        text-only runs (rope_delta=0) this matches HF exactly.

        Debug tip: if TKG step 0 diverges, print kv_cache_populated and the
        position_ids value here to compare against HF.
        """
        # Delegate to the base class (NeuronBaseForCausalLM) for the standard work.
        model_inputs = super().prepare_inputs_for_generation(
            input_ids, attention_mask=attention_mask, **kwargs
        )

        # --- M-RoPE rope_delta correction (placeholder for future multimodal) ---
        # For text-only inputs rope_deltas is always 0, so no correction is needed.
        # Uncomment the block below to enable it for image/video inputs:
        #
        # if self._rope_deltas is not None:
        #     pos = model_inputs.get("position_ids", None)
        #     if pos is not None and pos.dim() == 2:
        #         # kv_cache_populated=True decode step: pos=[B,1], value=cache_pos
        #         # HF value: cache_pos + rope_delta
        #         delta = self._rope_deltas.to(pos.device)  # [B,1]
        #         model_inputs["position_ids"] = pos + delta

        return model_inputs

    # NOTE: previously we overrode forward() to patch position_ids.masked_fill
    # so is_context_encoding would detect left-padded CTE correctly. With
    # padding_side="right" (NxDI native) adapter's own position_ids has min==0
    # and the override is no longer needed. Removing the override also avoids
    # subtle interactions with TKG KV-cache slot mapping.

    @staticmethod
    def load_hf_model(model_path, **kwargs):
        from transformers import Qwen2_5_VLForConditionalGeneration

        return Qwen2_5_VLForConditionalGeneration.from_pretrained(model_path, **kwargs)

    @staticmethod
    def convert_hf_to_neuron_state_dict(
        state_dict: dict, config: InferenceConfig
    ) -> dict:
        neuron_config = config.neuron_config
        num_layers = config.num_hidden_layers
        tp_degree = neuron_config.tp_degree

        new_sd = {}

        for key, value in state_dict.items():
            # Skip vision encoder weights
            if key.startswith("visual."):
                continue
            # Text backbone: strip `model.` prefix
            if key.startswith("model."):
                new_key = key[len("model.") :]
            else:
                new_key = key
            new_sd[new_key] = value.detach().clone() if hasattr(value, "detach") else value

        if neuron_config.fused_qkv:
            for i in range(num_layers):
                prefix = f"layers.{i}.self_attn"
                q_w = new_sd.pop(f"{prefix}.q_proj.weight")
                k_w = new_sd.pop(f"{prefix}.k_proj.weight")
                v_w = new_sd.pop(f"{prefix}.v_proj.weight")
                new_sd[f"{prefix}.qkv_proj.Wqkv.weight"] = torch.cat([q_w, k_w, v_w], dim=0)
                q_b = new_sd.pop(f"{prefix}.q_proj.bias", None)
                k_b = new_sd.pop(f"{prefix}.k_proj.bias", None)
                v_b = new_sd.pop(f"{prefix}.v_proj.bias", None)
                if q_b is not None and k_b is not None and v_b is not None:
                    new_sd[f"{prefix}.qkv_proj.Wqkv.bias"] = torch.cat([q_b, k_b, v_b], dim=0)

        # rank util tensors
        for i in range(num_layers):
            new_sd[f"layers.{i}.self_attn.rank_util.rank"] = torch.arange(
                0, tp_degree, dtype=torch.int32
            )
        if neuron_config.vocab_parallel:
            new_sd["embed_tokens.rank_util.rank"] = torch.arange(
                0, neuron_config.local_ranks_size
            )
        new_sd["rank_util.rank"] = torch.arange(0, tp_degree, dtype=torch.int32)

        gc.collect()
        return new_sd

    @staticmethod
    def update_state_dict_for_tied_weights(state_dict):
        # Stockmark-DocReasoner has tie_word_embeddings=False (explicit lm_head.weight)
        if "lm_head.weight" not in state_dict and "embed_tokens.weight" in state_dict:
            state_dict["lm_head.weight"] = state_dict["embed_tokens.weight"].clone()

    @classmethod
    def get_config_cls(cls):
        return StockmarkTextInferenceConfig

    def get_compiler_args(self):
        lnc = getattr(self.neuron_config, "logical_nc_config", None)
        args = (
            "--enable-saturate-infinity "
            "--enable-mixed-precision-accumulation "
            "--auto-cast=none "
            "--model-type transformer -O1"
        )
        if lnc is not None:
            args += f" --lnc={int(lnc)}"
        args += " --target=trn2"
        return args
