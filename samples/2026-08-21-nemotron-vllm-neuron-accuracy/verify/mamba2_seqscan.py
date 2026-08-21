"""A neuronx-cc-friendly single-layer Mamba2 selective scan (fixed-length sequential unroll).

Hugging Face's `NemotronHMamba2Mixer.torch_forward` prefill path uses a chunked SSD
scan (segment_sum / decay_chunk). Compiling that path on neuronx-cc for a small,
sub-chunk-size sequence length fails with "too many strides" / NCC_IMPR902 (see
`ssd.py` in this directory for the plugin's own SSD reformulation that works around
this at chunk granularity).

This module takes a different, deliberately simpler approach at single-layer scale:
it recomputes the Mamba2 recurrence

    h_t = h_{t-1} * dA_t + dB_t * x_t      (dA_t = exp(dt_t * A), dB_t = dt_t * B_t)
    y_t = (h_t . C_t) + D * x_t

as a plain Python `for` loop over `seq_len`, with no `segment_sum`, no chunk
splitting, and no multi-level strided views. Because `seq_len` is fixed at trace
time, the loop is statically unrolled by `torch.compile` / `torch_neuronx.trace`
into `seq_len` sequential steps — this is mathematically identical to HF's own
decode-time recurrence, just applied across the whole prefill instead of one step
at a time.

`SeqScanMamba2Mixer` subclasses `NemotronHMamba2Mixer` and only overrides
`torch_forward` (the prefill SSM computation); `conv1d` / `in_proj` / `out_proj` /
`norm` are inherited unchanged, since those were independently confirmed to compile
correctly on Neuron.

Known compile-time footgun this file works around: when the pre-scan projection is
sliced with `torch.split` and one of the requested split sizes is exactly zero
(`d_mlp == 0`, which is NemotronH's actual configuration), neuronx-cc has been
observed to mis-compile the split so that every position after the first timestep
in the SSM output is wrong, even though the shapes are correct and the split
contains no genuinely empty slices for the *non-zero* pieces. The fix is to avoid
`torch.split` with a zero-sized piece entirely and use plain slicing (`narrow`-style
indexing) instead, which this file does throughout, even where a zero-sized slice is
not currently expected, so the code stays correct if `d_mlp` ever changes.
"""
import torch
import torch.nn as nn

from transformers.models.nemotron_h.modeling_nemotron_h import NemotronHMamba2Mixer


class SeqScanMamba2Mixer(NemotronHMamba2Mixer):
    """Prefill variant that computes the SSM recurrence as a sequential scan."""

    def torch_forward(self, input_states, cache_params=None, attention_mask=None):
        batch_size, seq_len, _ = input_states.shape
        dtype = input_states.dtype

        projected_states = self.in_proj(input_states)
        d_mlp = (projected_states.shape[-1] - 2 * self.intermediate_size
                 - 2 * self.n_groups * self.ssm_state_size - self.num_heads) // 2

        # Slice with explicit offsets rather than torch.split, to avoid the
        # zero-sized-split miscompile described in the module docstring.
        gate_size = self.intermediate_size
        off = 2 * d_mlp
        gate = projected_states[..., off:off + gate_size]
        off += gate_size
        hidden_states = projected_states[..., off:off + self.conv_dim]
        off += self.conv_dim
        dt = projected_states[..., off:off + self.num_heads]
        hidden_states = hidden_states.transpose(1, 2)

        # Depthwise causal conv1d (inherited behavior, sliced back to seq_len).
        hidden_states = self.act(self.conv1d(hidden_states)[..., :seq_len].transpose(1, 2))

        gn = self.n_groups * self.ssm_state_size
        _im = self.intermediate_size
        B = hidden_states[..., _im:_im + gn]
        C = hidden_states[..., _im + gn:_im + 2 * gn]
        hidden_states = hidden_states[..., :_im]

        A = -torch.exp(self.A_log.float())  # [num_heads]

        dt = nn.functional.softplus(dt + self.dt_bias)          # [b, l, h]
        dt = torch.clamp(dt, self.time_step_min)

        H, P, N = self.num_heads, self.head_dim, self.ssm_state_size
        G = self.n_groups
        rep = H // G

        x = hidden_states.reshape(batch_size, seq_len, H, P).float()      # [b,l,h,p]
        B = B.reshape(batch_size, seq_len, G, N).float()                  # [b,l,g,n]
        C = C.reshape(batch_size, seq_len, G, N).float()
        B = B.repeat_interleave(rep, dim=2)                               # [b,l,h,n]
        C = C.repeat_interleave(rep, dim=2)

        dA = torch.exp(dt.float() * A)                                    # [b,l,h]

        # Sequential scan; statically unrolled by the compiler for fixed seq_len.
        h = torch.zeros(batch_size, H, P, N, dtype=torch.float32, device=x.device)
        ys = []
        for t in range(seq_len):
            dA_t = dA[:, t]                    # [b,h]
            dt_t = dt[:, t].float()            # [b,h]
            x_t = x[:, t]                      # [b,h,p]
            B_t = B[:, t]                      # [b,h,n]
            C_t = C[:, t]                      # [b,h,n]
            dBx = (dt_t[..., None, None] * B_t[:, :, None, :]) * x_t[..., None]
            h = h * dA_t[..., None, None] + dBx
            y_t = (h * C_t[:, :, None, :]).sum(dim=-1)
            ys.append(y_t)
        y = torch.stack(ys, dim=1)             # [b,l,h,p]

        D = self.D[..., None]                  # [h,1]
        y = y + x * D                          # [b,l,h,p]
        y = y.reshape(batch_size, seq_len, -1)

        scan_output = self.norm(y, gate)
        contextualized_states = self.out_proj(scan_output.to(dtype))
        return contextualized_states
