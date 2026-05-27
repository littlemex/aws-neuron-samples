#!/usr/bin/env python3
"""Pre-compile Whisper-large-v3 for AWS Neuron (trn2 / inf2).

Compiles the Whisper encoder, decoder and projection-output head separately
via torch_neuronx.trace() and saves the artifacts under --output-dir so the
inference server (whisper_server.py) can load them without recompilation.

Reference: https://github.com/samir-souza/laboratory/blob/master/05_Inferentia/24_WhisperV3/Whisper.ipynb
Adapted for trn2 instances with Neuron SDK 2.x.

Usage:
    python compile_whisper.py \
        --model-id openai/whisper-large-v3 \
        --output-dir /models/whisper-large-v3-neuron \
        --batch-size 1 \
        --max-dec-len 448
"""
from __future__ import annotations

import argparse
import json
import os
import time
import types

import torch
import torch.nn.functional as F
import torch_neuronx
from transformers import WhisperProcessor, WhisperForConditionalGeneration
from transformers.modeling_outputs import (
    BaseModelOutput,
    BaseModelOutputWithPastAndCrossAttentions,
)


def patch_model_forwards(model, processor, max_dec_len, output_attentions=False):
    """Replace encoder / decoder / proj_out forwards with Neuron-compatible
    versions that:
      - accept fixed-shape tensors (required for tracing),
      - pad / unpad dynamically at runtime,
      - dispatch to forward_neuron when a compiled graph is attached.
    """

    def enc_f(self, input_features, attention_mask=None, **kwargs):
        if attention_mask is None:
            attention_mask = torch.zeros(
                (input_features.shape[0], input_features.shape[1]), dtype=torch.int64
            )
        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(input_features, attention_mask)
        else:
            out = self.forward_(input_features, attention_mask, return_dict=True)
        return BaseModelOutput(**out)

    def dec_f(self, input_ids, attention_mask=None, encoder_hidden_states=None, **kwargs):
        # Workaround: the Neuron tracer rejects None args. When HF passes
        # (input_ids, attention_mask) without encoder_hidden_states, swap so
        # the encoder hidden states actually receive the tensor.
        if attention_mask is not None and encoder_hidden_states is None:
            encoder_hidden_states, attention_mask = attention_mask, encoder_hidden_states

        inp = [input_ids, encoder_hidden_states]
        if inp[0].shape[1] > self.max_length:
            raise RuntimeError(
                f"Decoded sequence length {inp[0].shape[1]} exceeds max {self.max_length}"
            )
        pad_size = self.max_length - inp[0].shape[1]
        inp[0] = F.pad(inp[0], (0, pad_size), "constant", processor.tokenizer.pad_token_id)

        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(*inp)
        else:
            out = self.forward_(
                input_ids=inp[0],
                encoder_hidden_states=inp[1],
                return_dict=True,
                use_cache=False,
                output_attentions=output_attentions,
            )

        out["last_hidden_state"] = out["last_hidden_state"][:, : input_ids.shape[1], :]
        if out.get("attentions") is not None:
            out["attentions"] = torch.stack(
                [
                    torch.mean(
                        o[:, :, : input_ids.shape[1], : input_ids.shape[1]],
                        axis=2,
                        keepdim=True,
                    )
                    for o in out["attentions"]
                ]
            )
        if out.get("cross_attentions") is not None:
            out["cross_attentions"] = torch.stack(
                [
                    torch.mean(o[:, :, : input_ids.shape[1], :], axis=2, keepdim=True)
                    for o in out["cross_attentions"]
                ]
            )
        return BaseModelOutputWithPastAndCrossAttentions(**out)

    def proj_out_f(self, inp):
        if inp.shape[1] > self.max_length:
            raise RuntimeError(
                f"Projection input length {inp.shape[1]} exceeds max {self.max_length}"
            )
        pad_size = self.max_length - inp.shape[1]
        x = F.pad(inp, (0, 0, 0, pad_size), "constant", processor.tokenizer.pad_token_id)
        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(x)
        else:
            out = self.forward_(x)
        return out[:, : inp.shape[1], :]

    if not hasattr(model.model.encoder, "forward_"):
        model.model.encoder.forward_ = model.model.encoder.forward
    if not hasattr(model.model.decoder, "forward_"):
        model.model.decoder.forward_ = model.model.decoder.forward
    if not hasattr(model.proj_out, "forward_"):
        model.proj_out.forward_ = model.proj_out.forward

    model.model.encoder.forward = types.MethodType(enc_f, model.model.encoder)
    model.model.decoder.forward = types.MethodType(dec_f, model.model.decoder)
    model.proj_out.forward = types.MethodType(proj_out_f, model.proj_out)

    model.model.decoder.max_length = max_dec_len
    model.proj_out.max_length = max_dec_len
    return model


def compile_encoder(model, batch_size, dim_enc, output_dir, suffix):
    filename = os.path.join(output_dir, f"whisper_{suffix}_{batch_size}_neuron_encoder.pt")
    if os.path.isfile(filename):
        print(f"[Encoder] Loading cached: {filename}")
        model.model.encoder.forward_neuron = torch.jit.load(filename)
        return

    print("[Encoder] Compiling...")
    inp = (
        torch.zeros([batch_size, dim_enc, 3000], dtype=torch.float32),
        torch.zeros([batch_size, dim_enc], dtype=torch.int64),
    )
    if hasattr(model.model.encoder, "forward_neuron"):
        del model.model.encoder.forward_neuron
    t0 = time.time()
    neuron_encoder = torch_neuronx.trace(
        model.model.encoder,
        inp,
        compiler_args="--model-type=transformer --auto-cast=all --auto-cast-type=bf16",
        compiler_workdir=os.path.join(output_dir, "enc_compile_workdir"),
        inline_weights_to_neff=False,
    )
    print(f"[Encoder] Compiled in {time.time() - t0:.1f}s")
    neuron_encoder.save(filename)
    model.model.encoder.forward_neuron = neuron_encoder
    print(f"[Encoder] Saved to {filename}")


def compile_decoder(model, batch_size, max_dec_len, dim_dec, output_dir, suffix):
    filename = os.path.join(
        output_dir, f"whisper_{suffix}_{batch_size}_{max_dec_len}_neuron_decoder.pt"
    )
    if os.path.isfile(filename):
        print(f"[Decoder] Loading cached: {filename}")
        model.model.decoder.forward_neuron = torch.jit.load(filename)
        return

    print("[Decoder] Compiling...")
    inp = (
        torch.zeros([batch_size, max_dec_len], dtype=torch.int64),
        torch.zeros([batch_size, 1500, dim_dec], dtype=torch.float32),
    )
    if hasattr(model.model.decoder, "forward_neuron"):
        del model.model.decoder.forward_neuron
    t0 = time.time()
    neuron_decoder = torch_neuronx.trace(
        model.model.decoder,
        inp,
        compiler_args="--model-type=transformer --auto-cast=all --auto-cast-type=bf16",
        compiler_workdir=os.path.join(output_dir, "dec_compile_workdir"),
        inline_weights_to_neff=True,
    )
    print(f"[Decoder] Compiled in {time.time() - t0:.1f}s")
    neuron_decoder.save(filename)
    model.model.decoder.forward_neuron = neuron_decoder
    print(f"[Decoder] Saved to {filename}")


def compile_proj_out(model, batch_size, max_dec_len, dim_dec, output_dir, suffix):
    filename = os.path.join(
        output_dir, f"whisper_{suffix}_{batch_size}_{max_dec_len}_neuron_proj.pt"
    )
    if os.path.isfile(filename):
        print(f"[ProjOut] Loading cached: {filename}")
        model.proj_out.forward_neuron = torch.jit.load(filename)
        return

    print("[ProjOut] Compiling...")
    inp = torch.zeros([batch_size, max_dec_len, dim_dec], dtype=torch.float32)
    if hasattr(model.proj_out, "forward_neuron"):
        del model.proj_out.forward_neuron
    t0 = time.time()
    neuron_proj = torch_neuronx.trace(
        model.proj_out,
        inp,
        compiler_args="--model-type=transformer --auto-cast=all --auto-cast-type=bf16",
        compiler_workdir=os.path.join(output_dir, "proj_compile_workdir"),
        inline_weights_to_neff=True,
    )
    print(f"[ProjOut] Compiled in {time.time() - t0:.1f}s")
    neuron_proj.save(filename)
    model.proj_out.forward_neuron = neuron_proj
    print(f"[ProjOut] Saved to {filename}")


def validate(model, cpu_model, processor):
    """Quick sanity check: compiled output should match CPU reference."""
    from datasets import load_dataset

    print("\n[Validation] Loading test audio sample...")
    dataset = load_dataset(
        "hf-internal-testing/librispeech_asr_dummy", "clean", split="validation"
    )
    sample = dataset[3]["audio"]
    input_features = processor(
        sample["array"], sampling_rate=sample["sampling_rate"], return_tensors="pt"
    ).input_features

    _ = model.generate(input_features, language="en", task="transcribe")
    torch.set_num_threads(1)

    t0 = time.time()
    y_neuron = model.generate(input_features, language="en", task="transcribe")
    neuron_time = time.time() - t0

    t0 = time.time()
    y_cpu = cpu_model.generate(input_features, language="en", task="transcribe")
    cpu_time = time.time() - t0

    text_neuron = processor.batch_decode(y_neuron, skip_special_tokens=True)
    text_cpu = processor.batch_decode(y_cpu, skip_special_tokens=True)

    print(f"[Validation] Neuron time: {neuron_time:.3f}s")
    print(f"[Validation] CPU time:    {cpu_time:.3f}s")
    print(f"[Validation] Speedup:     {cpu_time / neuron_time:.1f}x")
    print(f"[Validation] Neuron output: {text_neuron}")
    print(f"[Validation] CPU output:    {text_cpu}")

    if text_neuron == text_cpu:
        print("[Validation] [OK] outputs match")
    else:
        print("[Validation] [WARNING] outputs differ (may be due to bf16 precision)")


def main():
    parser = argparse.ArgumentParser(description="Compile Whisper for Neuron (trn2/inf2)")
    parser.add_argument("--model-id", type=str, default="openai/whisper-large-v3")
    parser.add_argument("--output-dir", type=str, default="/models/whisper-large-v3-neuron")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--max-dec-len", type=int, default=448)
    parser.add_argument("--output-attentions", action="store_true")
    parser.add_argument("--skip-validation", action="store_true")
    parser.add_argument("--skip-encoder", action="store_true")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    suffix = args.model_id.split("whisper-")[-1] if "whisper-" in args.model_id else "large-v3"

    print("=== Whisper Neuron Compilation ===")
    print(f"Model:           {args.model_id}")
    print(f"Output dir:      {args.output_dir}")
    print(f"Batch size:      {args.batch_size}")
    print(f"Max decoder len: {args.max_dec_len}")
    print(f"Attentions:      {args.output_attentions}")
    print()

    print("Loading model and processor...")
    processor = WhisperProcessor.from_pretrained(args.model_id)
    model = WhisperForConditionalGeneration.from_pretrained(args.model_id, torchscript=True)
    # torchscript=True forces config.use_return_dict to False, which makes
    # WhisperModel.forward try `decoder_outputs + encoder_outputs` and fail
    # because our patched sub-module forwards return dataclass objects.
    # We only torch_neuronx.trace sub-modules separately, so we don't actually
    # need torchscript-mode on the parent config — turn it off.
    model.config.torchscript = False
    processor.save_pretrained(args.output_dir)

    dim_enc = model.config.num_mel_bins  # 128 for large-v3
    dim_dec = model.config.d_model        # 1280 for large-v3
    print(f"Encoder dim (num_mel_bins): {dim_enc}")
    print(f"Decoder dim (d_model):      {dim_dec}")

    model = patch_model_forwards(
        model, processor, args.max_dec_len, output_attentions=args.output_attentions
    )

    if not args.skip_encoder:
        print("\nWarming up patched model on CPU...")
        from datasets import load_dataset

        dataset = load_dataset(
            "hf-internal-testing/librispeech_asr_dummy", "clean", split="validation"
        )
        sample = dataset[3]["audio"]
        input_features = processor(
            sample["array"], sampling_rate=sample["sampling_rate"], return_tensors="pt"
        ).input_features
        # language="en", task="transcribe" skips detect_language which triggers
        # WhisperModel.forward(decoder_outputs + encoder_outputs) — our patched
        # forwards return dataclasses that don't support `+`.
        _ = model.generate(input_features, language="en", task="transcribe")
        print("CPU warmup OK\n")
    else:
        print("\nSkipping CPU warmup (encoder skipped)\n")

    if not args.skip_encoder:
        compile_encoder(model, args.batch_size, dim_enc, args.output_dir, suffix)
    compile_decoder(model, args.batch_size, args.max_dec_len, dim_dec, args.output_dir, suffix)
    compile_proj_out(model, args.batch_size, args.max_dec_len, dim_dec, args.output_dir, suffix)

    metadata = {
        "model_id": args.model_id,
        "batch_size": args.batch_size,
        "max_dec_len": args.max_dec_len,
        "output_attentions": args.output_attentions,
        "dim_enc": dim_enc,
        "dim_dec": dim_dec,
        "suffix": suffix,
    }
    with open(os.path.join(args.output_dir, "compile_metadata.json"), "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"\nMetadata saved to {args.output_dir}/compile_metadata.json")

    if not args.skip_validation:
        cpu_model = WhisperForConditionalGeneration.from_pretrained(
            args.model_id, torchscript=True
        )
        validate(model, cpu_model, processor)

    print("\n=== Compilation complete ===")
    print(f"Artifacts saved to: {args.output_dir}")


if __name__ == "__main__":
    main()
