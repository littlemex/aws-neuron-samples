"""Qwen2.5-VL vision encoder for NxD Inference.

Qwen2.5-VL changed the vision tower versus Qwen2-VL in two ways:
  1. norm1 / norm2 in VisionBlock: LayerNorm (weight+bias) → RMSNorm (weight only)
  2. VisionBlock MLP: fc1+act+fc2 (2-matrix GELU) → gate_proj+up_proj+down_proj (SwiGLU)
  3. PatchMerger.ln_q: LayerNorm (weight+bias) → RMSNorm (weight only)

NxDI's existing Qwen2-VL vision classes use LayerNorm + 2-matrix MLP, so loading a
Qwen2.5-VL-7B checkpoint produces:
  - missing_keys: blocks.{i}.norm1.bias, blocks.{i}.norm2.bias, merger.ln_q.bias,
                  blocks.{i}.mlp.fc1.*, blocks.{i}.mlp.fc2.*
  - unexpected_keys: blocks.{i}.mlp.gate_proj.*, blocks.{i}.mlp.up_proj.*,
                     blocks.{i}.mlp.down_proj.*

This module provides fixed replacements that match the Qwen2.5-VL checkpoint layout.
All NxDI infrastructure (DP scatter/gather, bucket padding, compile pipeline) is
inherited unchanged from the Qwen2-VL base classes.

Key classes:
  Qwen25RMSNorm              – weight-only RMSNorm matching Qwen2.5-VL checkpoint
  Qwen25VLVisionMlp          – SwiGLU 3-matrix MLP matching Qwen2.5-VL checkpoint
  Qwen25VLVisionBlock        – VisionBlock using the above (replaces Qwen2VLVisionBlock)
  Qwen25PatchMerger          – PatchMerger with RMSNorm ln_q (replaces PatchMerger)
  NeuronQwen25VisionModel    – full vision model using Qwen2.5-VL blocks/merger
  NeuronQwen25VLForImageEncoding – NeuronApplicationBase wrapper; convert_hf_to_neuron_state_dict
                                   handles the attn.qkv / attn.proj remap (same as Qwen2-VL)
"""

import os
import logging
from typing import List, Optional, Tuple

import torch
from torch import nn
from safetensors.torch import save_file
from transformers.activations import ACT2FN
from transformers.models.qwen2_vl.image_processing_qwen2_vl import smart_resize
from transformers.models.qwen2_vl.modeling_qwen2_vl import VisionRotaryEmbedding, PatchEmbed

from neuronx_distributed.parallel_layers.layers import ColumnParallelLinear, RowParallelLinear, SPMDRank
from neuronx_distributed.parallel_layers.mappings import (
    scatter_to_process_group_spmd,
    gather_from_tensor_model_parallel_region_with_dim,
)
from neuronx_distributed.parallel_layers.parallel_state import get_data_parallel_group
from neuronx_distributed_inference.models.application_base import NeuronApplicationBase
from neuronx_distributed_inference.models.config import InferenceConfig
from neuronx_distributed_inference.models.model_wrapper import EncoderModelInstance, ModelWrapper
from neuronx_distributed_inference.modules.padding import pad_tensor, pad_with_first_batchline
from neuronx_distributed_inference.modules.attention.attention_base import NeuronAttentionBase
from neuronx_distributed_inference.modules.attention.utils import apply_rotary_pos_emb
from neuronx_distributed_inference.models.qwen2_vl.utils.vision_utils import (
    calculate_max_grid_size, get_image_dimensions
)
from neuronx_distributed_inference.models.qwen2_vl.utils.input_processor import (
    prepare_generation_inputs_hf
)
from neuronx_distributed_inference.utils.distributed import get_dp_rank_spmd

# Re-use the attention + rotary helpers from the Qwen2-VL NxDI base; they are
# architecture-neutral (they only depend on embed_dim / num_heads).
from neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl_vision import (
    Qwen2VLVisionRotaryEmbedding,
    NeuronQwen2VLAttention,
    Qwen2VLVisionModelWrapper,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Qwen2.5-VL specific building blocks
# ---------------------------------------------------------------------------

class Qwen25RMSNorm(nn.Module):
    """Weight-only RMSNorm matching Qwen2.5-VL's Qwen2RMSNorm.

    Checkpoint key layout (after visual. prefix strip):
      blocks.{i}.norm1.weight   shape=(embed_dim,)   dtype=bfloat16
      blocks.{i}.norm2.weight   shape=(embed_dim,)   dtype=bfloat16
      merger.ln_q.weight        shape=(embed_dim,)   dtype=bfloat16
    No bias key exists in the Qwen2.5-VL checkpoint.
    """

    def __init__(self, hidden_size: int, eps: float = 1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(hidden_size))
        self.variance_epsilon = eps

    def forward(self, hidden_states: torch.Tensor) -> torch.Tensor:
        input_dtype = hidden_states.dtype
        hidden_states = hidden_states.to(torch.float32)
        variance = hidden_states.pow(2).mean(-1, keepdim=True)
        hidden_states = hidden_states * torch.rsqrt(variance + self.variance_epsilon)
        return self.weight * hidden_states.to(input_dtype)


class Qwen25VLVisionMlp(nn.Module):
    """SwiGLU MLP matching Qwen2.5-VL vision block MLP.

    Checkpoint key layout (after visual. prefix strip):
      blocks.{i}.mlp.gate_proj.weight / .bias
      blocks.{i}.mlp.up_proj.weight   / .bias
      blocks.{i}.mlp.down_proj.weight / .bias
    """

    def __init__(self, dim: int, hidden_dim: int, hidden_act: str, dtype=torch.bfloat16) -> None:
        super().__init__()
        self.gate_proj = ColumnParallelLinear(dim, hidden_dim, gather_output=False, dtype=dtype)
        self.up_proj   = ColumnParallelLinear(dim, hidden_dim, gather_output=False, dtype=dtype)
        self.down_proj = RowParallelLinear(
            hidden_dim, dim, input_is_parallel=True, dtype=dtype, reduce_dtype=dtype
        )
        self.act_fn = ACT2FN[hidden_act]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.down_proj(self.act_fn(self.gate_proj(x)) * self.up_proj(x))


class Qwen25VLVisionBlock(nn.Module):
    """Qwen2.5-VL VisionBlock: RMSNorm + SwiGLU MLP.

    Structural differences vs Qwen2-VL (NxDI base):
      norm1/norm2: LayerNorm(weight+bias) → Qwen25RMSNorm(weight only)
      mlp:         VisionMlp(fc1/fc2)    → Qwen25VLVisionMlp(gate/up/down_proj)
    forward() is identical to Qwen2VLVisionBlock.
    """

    def __init__(self, vision_config) -> None:
        super().__init__()
        dtype = vision_config.neuron_config.torch_dtype
        self.norm1 = Qwen25RMSNorm(vision_config.embed_dim, eps=1e-6)
        self.norm2 = Qwen25RMSNorm(vision_config.embed_dim, eps=1e-6)
        # Cast weight to target dtype after init (RMSNorm initialises to float32 ones)
        self.norm1.weight.data = self.norm1.weight.data.to(dtype)
        self.norm2.weight.data = self.norm2.weight.data.to(dtype)

        mlp_hidden_dim = int(vision_config.embed_dim * vision_config.mlp_ratio)
        self.attn = NeuronQwen2VLAttention(vision_config)
        self.mlp = Qwen25VLVisionMlp(
            dim=vision_config.embed_dim,
            hidden_dim=mlp_hidden_dim,
            hidden_act=vision_config.hidden_act,
            dtype=dtype,
        )

    def forward(
        self,
        hidden_states: torch.Tensor,
        position_embeddings: Optional[Tuple[torch.Tensor, torch.Tensor]] = None,
    ) -> torch.Tensor:
        attn_output = self.attn(
            self.norm1(hidden_states),
            position_embeddings=position_embeddings,
        )[0]
        hidden_states = hidden_states + attn_output
        hidden_states = hidden_states + self.mlp(self.norm2(hidden_states))
        return hidden_states


class Qwen25PatchMerger(nn.Module):
    """PatchMerger with RMSNorm ln_q for Qwen2.5-VL.

    Checkpoint key layout (after visual. prefix strip):
      merger.ln_q.weight        (no bias)
      merger.mlp.0.weight / .bias
      merger.mlp.2.weight / .bias
    """

    def __init__(self, dim: int, context_dim: int, spatial_merge_size: int = 2,
                 dtype=torch.bfloat16) -> None:
        super().__init__()
        self.hidden_size = context_dim * (spatial_merge_size ** 2)
        self.ln_q = Qwen25RMSNorm(context_dim, eps=1e-6)
        self.ln_q.weight.data = self.ln_q.weight.data.to(dtype)
        self.mlp = nn.Sequential(
            ColumnParallelLinear(
                self.hidden_size, self.hidden_size, gather_output=False, dtype=dtype
            ),
            nn.GELU(),
            RowParallelLinear(
                self.hidden_size, dim, input_is_parallel=True, dtype=dtype, reduce_dtype=dtype
            ),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.mlp(self.ln_q(x).view(-1, self.hidden_size))
        return x


# ---------------------------------------------------------------------------
# Vision model and application wrapper
# ---------------------------------------------------------------------------

class NeuronQwen25VisionModel(nn.Module):
    """Full vision model for Qwen2.5-VL.

    Identical to NeuronQwen2VisionModel from the NxDI Qwen2-VL source except
    that blocks use Qwen25VLVisionBlock and merger uses Qwen25PatchMerger.
    All DP scatter/gather, bucket padding, and rotary logic is replicated
    verbatim so the compilation pipeline is unchanged.
    """

    def __init__(self, config: InferenceConfig) -> None:
        super().__init__()
        self.config = config
        self.vision_config = config.vision_config

        self.spatial_merge_size = self.vision_config.spatial_merge_size

        self.patch_embed = PatchEmbed(
            patch_size=self.vision_config.patch_size,
            temporal_patch_size=self.vision_config.temporal_patch_size,
            in_channels=self.vision_config.in_channels,
            embed_dim=self.vision_config.embed_dim,
        ).to(self.vision_config.neuron_config.torch_dtype)

        head_dim = self.vision_config.embed_dim // self.vision_config.num_heads
        self.rotary_pos_emb = VisionRotaryEmbedding(head_dim // 2)

        self.blocks = nn.ModuleList(
            [Qwen25VLVisionBlock(self.vision_config) for _ in range(self.vision_config.depth)]
        )
        self.merger = Qwen25PatchMerger(
            dim=self.vision_config.hidden_size,
            context_dim=self.vision_config.embed_dim,
            spatial_merge_size=self.vision_config.spatial_merge_size,
            dtype=self.vision_config.neuron_config.torch_dtype,
        )

        image_width, image_height = get_image_dimensions(self.vision_config.neuron_config)
        self.max_grid_size = calculate_max_grid_size(
            image_width, image_height, patch_size=self.vision_config.patch_size
        )
        logger.info(
            f"Calculated max_grid_size={self.max_grid_size} for image dimensions "
            f"{image_width}x{image_height}"
        )

        self.precomputed_rotary_pos_emb = self.rotary_pos_emb(self.max_grid_size)
        self.register_buffer(
            "rotary_pos_emb_cache", self.precomputed_rotary_pos_emb, persistent=False
        )

        self.neuron_config = config.vision_config.neuron_config
        self.global_rank = SPMDRank(world_size=self.neuron_config.world_size)
        assert (
            self.neuron_config.world_size % self.neuron_config.tp_degree == 0
        ), "Invalid parallel config. world_size must be a multiple of tp_degree"
        self.dp_degree = self.neuron_config.world_size // self.neuron_config.tp_degree
        self.data_parallel_enabled = self.neuron_config.enable_ve_data_parallel
        if self.data_parallel_enabled:
            assert self.dp_degree > 1, (
                "enable_ve_data_parallel is True but dp_degree is 1. "
                "world_size must be greater than tp_degree to enable vision encoder data parallel."
            )
            non_dp_buckets = [b for b in self.neuron_config.buckets if b % self.dp_degree != 0]
            if non_dp_buckets:
                logger.warning(
                    f"enable_ve_data_parallel is True but buckets {non_dp_buckets} are not "
                    f"divisible by dp_degree={self.dp_degree}. These buckets will be compiled "
                    f"without vision encoder data parallel."
                )
        self.data_parallel_group = get_data_parallel_group()

    def rot_pos_ids(self, grid_thw):
        pos_ids = []
        for t, h, w in grid_thw:
            hpos_ids = torch.arange(h).unsqueeze(1).expand(-1, w)
            hpos_ids = hpos_ids.reshape(
                h // self.spatial_merge_size,
                self.spatial_merge_size,
                w // self.spatial_merge_size,
                self.spatial_merge_size,
            )
            hpos_ids = hpos_ids.permute(0, 2, 1, 3).flatten()

            wpos_ids = torch.arange(w).unsqueeze(0).expand(h, -1)
            wpos_ids = wpos_ids.reshape(
                h // self.spatial_merge_size,
                self.spatial_merge_size,
                w // self.spatial_merge_size,
                self.spatial_merge_size,
            )
            wpos_ids = wpos_ids.permute(0, 2, 1, 3).flatten()
            pos_ids.append(torch.stack([hpos_ids, wpos_ids], dim=-1).repeat(t, 1))
        return torch.cat(pos_ids, dim=0)

    def pad_to_text_seq_len(self, hidden_states):
        padded_length = self.config.neuron_config.seq_len
        hidden_states = hidden_states.to(self.config.text_config.neuron_config.torch_dtype)
        hidden_size = hidden_states.shape[-1]
        hidden_states, _ = pad_tensor(hidden_states, (padded_length, hidden_size), pad_value=0)
        return hidden_states.view(-1, hidden_size).unsqueeze(0)

    def forward(self, hidden_states: torch.Tensor, grid_thw: torch.Tensor):
        hidden_states = self.patch_embed(hidden_states)

        assert grid_thw[:, 1:].max() < self.max_grid_size, (
            f"Grid size {grid_thw[:, 1:].max()} exceeds max_grid_size {self.max_grid_size}. "
            f"Increase default_image_width/height in vision_neuron_config."
        )
        pos_ids = self.rot_pos_ids(grid_thw)
        rotary_pos_emb = self.rotary_pos_emb_cache[pos_ids].flatten(1)
        emb = torch.cat((rotary_pos_emb, rotary_pos_emb), dim=-1)
        cos_emb = emb.cos()
        sin_emb = emb.sin()

        num_images = grid_thw.shape[0]
        cos_emb = cos_emb.reshape(num_images, -1, cos_emb.shape[-1])
        sin_emb = sin_emb.reshape(num_images, -1, sin_emb.shape[-1])
        hidden_states = hidden_states.reshape(num_images, -1, hidden_states.shape[-1])

        if self.data_parallel_enabled and num_images % self.dp_degree == 0:
            dp_rank = get_dp_rank_spmd(self.global_rank.get_rank(), self.neuron_config.tp_degree)
            hidden_states = scatter_to_process_group_spmd(
                hidden_states, partition_dim=0, rank=dp_rank,
                process_group=self.data_parallel_group,
            )
            cos_emb = scatter_to_process_group_spmd(
                cos_emb, partition_dim=0, rank=dp_rank,
                process_group=self.data_parallel_group,
            )
            sin_emb = scatter_to_process_group_spmd(
                sin_emb, partition_dim=0, rank=dp_rank,
                process_group=self.data_parallel_group,
            )

        position_embeddings = (cos_emb, sin_emb)
        for blk in self.blocks:
            hidden_states = blk(hidden_states, position_embeddings)

        hidden_states_merger = self.merger(hidden_states)

        if self.data_parallel_enabled and num_images % self.dp_degree == 0:
            hidden_states_merger = gather_from_tensor_model_parallel_region_with_dim(
                hidden_states_merger, gather_dim=0,
                process_group=self.data_parallel_group,
            )

        return self.pad_to_text_seq_len(hidden_states_merger)


class NeuronQwen25VLForImageEncoding(NeuronApplicationBase):
    """NeuronApplicationBase wrapper for Qwen2.5-VL vision encoder.

    Inherits compile/load/forward infrastructure from NeuronApplicationBase.
    The convert_hf_to_neuron_state_dict performs the same attn.qkv / attn.proj
    remap as the Qwen2-VL base class.  No additional remap is needed because:
      - gate_proj / up_proj / down_proj keys pass through unchanged
      - norm1.weight / norm2.weight / merger.ln_q.weight pass through unchanged
      - norm1.bias / norm2.bias / merger.ln_q.bias do NOT exist in Qwen2.5-VL
        checkpoints, and Qwen25RMSNorm has no bias parameter, so no mismatch
    """

    _model_cls = NeuronQwen25VisionModel

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.model_wrapper = self.get_model_wrapper_cls()
        self.model = self.model_wrapper(
            config=self.config,
            model_cls=self._model_cls,
            tag=self._model_cls.__name__,
            compiler_args=self.get_compiler_args(),
            priority_model_idx=0,
        )
        self.models.append(self.model)

    def get_model_wrapper_cls(self):
        return Qwen2VLVisionModelWrapper

    def forward(self, pixel_values, grid_thw):
        return self.models[0](pixel_values, grid_thw)

    def get_compiler_args(self):
        compiler_args = (
            "--auto-cast=none --model-type=transformer "
            "--tensorizer-options='--enable-ccop-compute-overlap "
            "--cc-pipeline-tiling-factor=2 ' -O1 "
            "--internal-hlo2tensorizer-options='--verify-hlo=true'"
        )
        logger.info(
            f"Compiling {self._model_cls.__name__} vision model with args: {compiler_args}"
        )
        return compiler_args

    @staticmethod
    def update_state_dict_for_tied_weights(state_dict):
        pass

    @staticmethod
    def load_hf_model(model_path, **kwargs):
        from transformers import Qwen2_5_VLForConditionalGeneration
        from transformers import Qwen2_5_VLConfig

        class _HFVisionModel(torch.nn.Module):
            def __init__(self, model_path, **kwargs):
                super().__init__()
                self.hf_config = Qwen2_5_VLConfig.from_pretrained(model_path, **kwargs)
                # Load only vision weights to save host memory during conversion
                full = Qwen2_5_VLForConditionalGeneration.from_pretrained(
                    model_path, low_cpu_mem_usage=True, **kwargs
                )
                self.visual = full.visual
                del full

            def forward(self, pixel_values, grid_thw):
                return self.visual(pixel_values, grid_thw)

            def save_pretrained(self, save_model_path):
                self.hf_config.save_pretrained(save_model_path)
                save_file(self.state_dict(), os.path.join(save_model_path, "model.safetensors"))

        return _HFVisionModel(model_path, **kwargs)

    @staticmethod
    def convert_hf_to_neuron_state_dict(
        state_dict: dict, inference_config: InferenceConfig
    ) -> dict:
        """Remap Qwen2.5-VL checkpoint keys to NxDI layout.

        Key remaps applied:
          visual.* prefix strip          (same as Qwen2-VL)
          .attn.qkv.  → .attn.qkv_proj.Wqkv.   (fused QKV, same as Qwen2-VL)
          .attn.proj. → .attn.o_proj.            (output proj, same as Qwen2-VL)

        No remap needed for:
          gate_proj / up_proj / down_proj  (pass-through, already match model keys)
          norm1.weight / norm2.weight      (pass-through, already match Qwen25RMSNorm.weight)
          merger.ln_q.weight               (pass-through)

        Keys absent from Qwen2.5-VL checkpoint (no action required):
          norm1.bias, norm2.bias, merger.ln_q.bias  (Qwen25RMSNorm has no bias param)
          blocks.{i}.mlp.fc1.*, blocks.{i}.mlp.fc2.*  (Qwen2-VL only)
        """
        new_state_dict = {}
        for key, value in state_dict.items():
            if "visual." in key:
                key = key.replace("visual.", "")
                if ".attn.qkv." in key:
                    key = key.replace(".attn.qkv.", ".attn.qkv_proj.Wqkv.")
                elif ".attn.proj." in key:
                    key = key.replace(".attn.proj.", ".attn.o_proj.")
            new_state_dict[key] = (
                value.clone()
                .detach()
                .contiguous()
                .to(inference_config.vision_config.neuron_config.torch_dtype)
            )

        new_state_dict["global_rank.rank"] = torch.arange(
            0, inference_config.vision_config.neuron_config.world_size, dtype=torch.int32
        )

        del state_dict
        return new_state_dict

    @classmethod
    def get_config_cls(cls):
        from neuronx_distributed_inference.models.qwen2_vl.modeling_qwen2_vl import (
            Qwen2VLInferenceConfig,
        )
        return Qwen2VLInferenceConfig

    @classmethod
    def prepare_input_args(cls, prompts, images, processor, role="user", config=None):
        if len(prompts) > 1:
            raise NotImplementedError("Qwen2.5-VL currently only supports batch size 1")
        if isinstance(prompts, list):
            prompts = prompts[0]
        if images and isinstance(images, list) and isinstance(images[0], list):
            images = images[0]
        inputs = prepare_generation_inputs_hf(prompts, images, processor, role, config)
        vision_inputs = None
        if hasattr(inputs, "pixel_values") and hasattr(inputs, "image_grid_thw"):
            vision_inputs = {
                "pixel_values": inputs.pixel_values,
                "image_grid_thw": inputs.image_grid_thw,
            }
        return inputs.input_ids, inputs.attention_mask, vision_inputs
