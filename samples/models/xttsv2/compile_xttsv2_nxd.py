"""XTTSv2 GPT Transformer compile script for AWS Neuron (NxD Inference).

Run on a Trainium / Inferentia2 instance with the AWS Neuron SDK
(``neuronx-distributed-inference``) installed.

Compiles both the Prefill and Decode models in BF16 and writes the
artefacts to --output-dir. BF16 is mandatory: FP16 attention overflows
on the 30-layer XTTSv2 GPT decoder and produces ~68% WER. trn2 uses
BF16 as its native dtype (8-bit exponent vs FP16's 5-bit), so attention
softmax stays numerically stable.

Idempotency:
  After a successful compile we drop a ``.compile_metadata.json`` marker
  in --output-dir. The matching task json (xttsv2-precompile.json) gates
  the slow compile step on whether this marker exists.

Usage:
    python compile_xttsv2_nxd.py \
        --model-path /models/XTTS-v2 \
        --output-dir /models/xttsv2-neuron-nxd \
        --tp-degree 4
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile the XTTSv2 GPT decoder for AWS Neuron (BF16)."
    )
    parser.add_argument(
        "--model-path",
        required=True,
        help="XTTSv2 checkpoint directory (must contain config.json and model.pth).",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Where to write the compiled NEFF + prefill/ + decode/ subdirs.",
    )
    parser.add_argument(
        "--tp-degree",
        type=int,
        default=4,
        help=(
            "Tensor parallel degree. trn2.3xlarge / trn2.48xlarge with LNC=2 "
            "give 4 logical cores per chip; default 4 uses one full chip. "
            "Use 2 for trn1.2xlarge."
        ),
    )
    parser.add_argument(
        "--seq-len",
        type=int,
        default=1081,
        help=(
            "Static sequence length (default 1081 = max_audio_tokens(605) + "
            "max_text_tokens(402) + max_prompt_tokens(70) + 4 separators). "
            "Must match XTTSv2InferenceConfig.max_seq_len exactly."
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # Lazy import: this script only runs on Neuron-enabled instances. Fail
    # with a clear error if someone tries to run it from a laptop.
    try:
        import torch
        from neuronx_distributed_inference.models.config import NeuronConfig
    except ImportError as exc:
        print(f"[ERROR] Neuron SDK import failed: {exc}", file=sys.stderr)
        print(
            "[ERROR] Run this on a Trainium / Inferentia2 instance with the "
            "Neuron NxD Inference venv activated.",
            file=sys.stderr,
        )
        sys.exit(1)

    # neuron_xttsv2 lives next to this script. Add the parent dir to
    # sys.path so the import works regardless of cwd (the task runner
    # invokes this from SERVE_DIR which is one level above).
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        from neuron_xttsv2.application_gpt import NeuronApplicationXTTSv2GPT
        from neuron_xttsv2.config import XTTSv2InferenceConfig
    except ImportError as exc:
        print(
            f"[ERROR] Failed to import neuron_xttsv2 package: {exc}",
            file=sys.stderr,
        )
        print(
            "[ERROR] Make sure neuron_xttsv2/ is a sibling of this script "
            "(samples/models/xttsv2/neuron_xttsv2/).",
            file=sys.stderr,
        )
        sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)

    print("[INFO] XTTSv2 Neuron compile starting")
    print(f"[INFO]   checkpoint dir : {args.model_path}")
    print(f"[INFO]   compiled dir   : {args.output_dir}")
    print(f"[INFO]   tp_degree      : {args.tp_degree}")
    print(f"[INFO]   seq_len        : {args.seq_len}")
    print(f"[INFO]   dtype          : bfloat16  (mandatory; FP16 produces ~68% WER)")
    print()

    neuron_config = NeuronConfig(
        batch_size=1,
        tp_degree=args.tp_degree,
        seq_len=args.seq_len,
        torch_dtype=torch.bfloat16,
    )
    config = XTTSv2InferenceConfig(neuron_config=neuron_config)
    if config.max_seq_len != args.seq_len:
        print(
            f"[ERROR] config.max_seq_len ({config.max_seq_len}) != "
            f"--seq-len ({args.seq_len}). They must match exactly.",
            file=sys.stderr,
        )
        sys.exit(2)

    print("[INFO] compile shape:")
    print(f"  gpt_layers           : {config.gpt_layers}")
    print(f"  gpt_n_heads          : {config.gpt_n_heads}")
    print(f"  gpt_n_model_channels : {config.gpt_n_model_channels}")
    print(f"  head_dim             : {config.head_dim}")
    print(f"  max_seq_len          : {config.max_seq_len}")
    print()

    # Application is constructed with the OUTPUT path (not the checkpoint
    # path); the checkpoint is only consulted at load_weights() time so we
    # can compile against a zero-initialised state dict here.
    app = NeuronApplicationXTTSv2GPT(args.output_dir, config)

    print(
        "[INFO] compiling... typical wall time on trn2 is 30-60 minutes; "
        "newer SDKs report 10-20 minutes."
    )
    t_start = time.time()
    try:
        app.compile(compiled_model_path=args.output_dir)
    except Exception as exc:
        print(f"[ERROR] compile failed: {exc}", file=sys.stderr)
        raise

    elapsed = time.time() - t_start

    # Drop the idempotency marker so xttsv2-precompile.json's 10-skip-if-cached
    # task can short-circuit on subsequent runs. Keep the schema flat so
    # operators can grep / inspect it without parsing.
    metadata = {
        "model_id": "xttsv2",
        "tp_degree": args.tp_degree,
        "seq_len": args.seq_len,
        "dtype": "bfloat16",
        "model_path": args.model_path,
        "compiled_at": int(time.time()),
        "compile_seconds": round(elapsed, 1),
        "backend": "nxd_inference",
    }
    marker_path = os.path.join(args.output_dir, ".compile_metadata.json")
    with open(marker_path, "w", encoding="utf-8") as fh:
        json.dump(metadata, fh, indent=2)
        fh.write("\n")

    minutes = int(elapsed // 60)
    seconds = elapsed - minutes * 60
    print()
    print(f"[OK] compile complete in {minutes}m {seconds:.1f}s")
    print(f"[OK] artefacts written to: {args.output_dir}")
    print(f"[OK] idempotency marker  : {marker_path}")


if __name__ == "__main__":
    main()
