#!/usr/bin/env python3
"""Pre-compile Whisper-large-v3 via NxD Inference (neuronx_distributed_inference).

This replaces the legacy torch_neuronx.trace() approach in compile_whisper.py.
NxD Inference ships an official Whisper application
(NeuronApplicationWhisper) that handles encoder + decoder compilation,
KV-cache, attention masking, and tensor parallelism out of the box.

References:
  - https://github.com/aws-neuron/neuronx-distributed-inference/blob/main/src/neuronx_distributed_inference/models/whisper/modeling_whisper.py
  - https://zenn.dev/tosshi/articles/f6c49165c90e6d (NxD Whisper を採用する根拠)

Output layout:
    <output-dir>/
        encoder/                 # NxD encoder compiled artifacts
        decoder/                 # NxD decoder compiled artifacts (prefill + decode)
        compile_metadata.json    # tp_degree / dtype / source model id

Note:
    NxD Whisper の decode は dtype を fp16 / fp32 のみ受け付ける (utils/decoding.py
    が `assert dtype in [fp16, fp32]`)。voice-image-edit でこれまで bf16 を使って
    いたが、NxD 経路では fp16 default にする。

Usage:
    python compile_whisper_nxd.py \\
        --model-id openai/whisper-large-v3 \\
        --output-dir /models/whisper-large-v3-neuron-nxd \\
        --tp-degree 8 \\
        --batch-size 1 \\
        --dtype fp16
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import time

import torch
from transformers import WhisperProcessor

from neuronx_distributed_inference.models.config import NeuronConfig
from neuronx_distributed_inference.models.whisper.modeling_whisper import (
    NeuronApplicationWhisper,
    WhisperInferenceConfig,
)
from neuronx_distributed_inference.utils.hf_adapter import load_pretrained_config


_DTYPE_MAP = {
    "fp16": torch.float16,
    "fp32": torch.float32,
}


def _resolve_hf_snapshot(model_id_or_path: str) -> str:
    """Return a local directory containing the HF Whisper checkpoint.

    NxD Whisper expects ``model_path`` to be a directory on disk because it
    re-loads the underlying ``WhisperModel.from_pretrained()`` once for the
    encoder and once for the decoder. If the user passed a Hub ID, snapshot
    it via huggingface_hub so the directory path is concrete.
    """
    if os.path.isdir(model_id_or_path):
        return model_id_or_path
    try:
        from huggingface_hub import snapshot_download
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(
            "huggingface_hub is required to snapshot the model id "
            f"{model_id_or_path!r}: {exc}"
        )
    print(f"[Snapshot] Downloading {model_id_or_path}...")
    return snapshot_download(repo_id=model_id_or_path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Compile Whisper via NxD Inference")
    parser.add_argument("--model-id", default="openai/whisper-large-v3")
    parser.add_argument("--output-dir", default="/models/whisper-large-v3-neuron-nxd")
    parser.add_argument("--tp-degree", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument(
        "--dtype",
        choices=sorted(_DTYPE_MAP.keys()),
        default="fp16",
        help="Decoder dtype. NxD decoding only supports fp16/fp32.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Recompile even if the output directory already contains artifacts.",
    )
    args = parser.parse_args()

    torch_dtype = _DTYPE_MAP[args.dtype]
    os.makedirs(args.output_dir, exist_ok=True)
    metadata_path = os.path.join(args.output_dir, "compile_metadata.json")
    encoder_dir = os.path.join(args.output_dir, "encoder")
    decoder_dir = os.path.join(args.output_dir, "decoder")

    if (
        not args.force
        and os.path.isfile(metadata_path)
        and os.path.isdir(encoder_dir)
        and os.path.isdir(decoder_dir)
    ):
        print(f"[Skip] Artifacts already present in {args.output_dir}")
        print("       Pass --force to recompile.")
        return

    if args.force:
        for d in (encoder_dir, decoder_dir):
            if os.path.isdir(d):
                print(f"[Force] Removing previous {d}")
                shutil.rmtree(d)

    print("=== NxD Whisper compilation ===")
    print(f"Model id     : {args.model_id}")
    print(f"Output dir   : {args.output_dir}")
    print(f"TP degree    : {args.tp_degree}")
    print(f"Batch size   : {args.batch_size}")
    print(f"Decoder dtype: {args.dtype}")

    model_path = _resolve_hf_snapshot(args.model_id)
    print(f"Local checkpoint: {model_path}")

    print("\n[Processor] Saving processor to output_dir for runtime use...")
    processor = WhisperProcessor.from_pretrained(args.model_id)
    processor.save_pretrained(args.output_dir)

    neuron_config = NeuronConfig(
        batch_size=args.batch_size,
        torch_dtype=torch_dtype,
        tp_degree=args.tp_degree,
    )
    inference_config = WhisperInferenceConfig(
        neuron_config,
        load_config=load_pretrained_config(model_path),
    )

    print("\n[Build] Instantiating NeuronApplicationWhisper...")
    neuron_model = NeuronApplicationWhisper(model_path, config=inference_config)

    print("\n[Compile] Tracing encoder + decoder (this can take 30+ minutes)...")
    t0 = time.time()
    neuron_model.compile(args.output_dir)
    elapsed = time.time() - t0
    print(f"[Compile] Done in {elapsed/60:.1f} min")

    metadata = {
        "model_id": args.model_id,
        "tp_degree": args.tp_degree,
        "batch_size": args.batch_size,
        "dtype": args.dtype,
        "compiled_at": int(time.time()),
        "backend": "nxd_inference",
    }
    with open(metadata_path, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"\n[Done] Metadata: {metadata_path}")
    print(f"[Done] Encoder : {encoder_dir}")
    print(f"[Done] Decoder : {decoder_dir}")


if __name__ == "__main__":
    main()
