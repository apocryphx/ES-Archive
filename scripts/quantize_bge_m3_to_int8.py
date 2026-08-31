#!/usr/bin/env python3
"""
Quantize BGEM3Encoder.mlpackage from fp16 to int8 weights.

Halves the model size (~1.08 GB → ~542 MB) with retrieval-quality-equivalent
output (cosine vs original ≥ 0.999 — see ES_Archive/BGEM3Embedder/README.md
for empirical results across English, German, and multilingual inputs).

Tool: coremltools.optimize.coreml.linear_quantize_weights
Mode: per-channel symmetric int8 (Apple's recommended config for transformer
weight-only quantization). Activations stay fp16 — Core ML does not require
activation quantization to achieve the size win.

Why int8 not 4-bit palettization: the kmeans-based 4-bit palettization path
(coremltools' OpPalettizerConfig with mode="kmeans") produces sklearn k-means
overflow warnings on this XLMRoberta variant and lands at cosine ~0.91 — far
worse than the documented 0.95+ target. int4 linear quant is honest but the
~0.05 cosine drift recalibrates ES Archive's score thresholds. int8 is the
clean win: 13 s wallclock, no numerical issues, basically lossless.

Requires: coremltools >= 9.0  (no torch needed; this is post-training
weight-only quantization on an existing Core ML mlpackage).

    python3 -m venv .venv
    .venv/bin/pip install 'coremltools>=9.0' numpy
    .venv/bin/python scripts/quantize_bge_m3_to_int8.py [--src PATH] [--dst PATH]
"""
import argparse, os, shutil, sys, time

DEFAULT_SRC = "ES_Archive/BGEM3Embedder/BGEM3Encoder.mlpackage"
DEFAULT_DST = "ES_Archive/BGEM3Embedder/BGEM3Encoder.mlpackage"


def du(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / (1024 * 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--src", default=DEFAULT_SRC,
                        help=f"source .mlpackage (default: {DEFAULT_SRC})")
    parser.add_argument("--dst", default=DEFAULT_DST,
                        help=f"destination .mlpackage (default: {DEFAULT_DST}; same as src is OK — original is overwritten)")
    parser.add_argument("--keep-original",
                        help="path to copy the original to before overwriting (e.g. ./BGEM3Encoder_fp16_backup.mlpackage)")
    args = parser.parse_args()

    if not os.path.isdir(args.src):
        sys.exit(f"error: source mlpackage not found: {args.src}")

    # Lazy import — gives a clean error if the venv isn't set up.
    try:
        import coremltools as ct
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
        )
    except ImportError as e:
        sys.exit(f"error: coremltools not installed in this Python — run "
                 f"`pip install 'coremltools>=9.0'` first ({e})")

    if args.keep_original:
        if os.path.exists(args.keep_original):
            sys.exit(f"error: --keep-original path already exists: {args.keep_original}")
        print(f"Backing up original → {args.keep_original}")
        shutil.copytree(args.src, args.keep_original)

    print(f"Loading {args.src}  ({du(args.src):.0f} MB)")
    model = ct.models.MLModel(args.src, compute_units=ct.ComputeUnit.CPU_ONLY)

    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int8",
            granularity="per_channel",
        )
    )

    print("Quantizing (per-channel symmetric int8) ...")
    t0 = time.time()
    quantized = linear_quantize_weights(model, config)
    print(f"  done in {time.time()-t0:.1f}s")

    # Save to a temp path, then atomically swap if dst == src.
    tmp_dst = args.dst + ".tmp"
    if os.path.exists(tmp_dst):
        shutil.rmtree(tmp_dst)
    quantized.save(tmp_dst)

    if os.path.abspath(args.dst) == os.path.abspath(args.src):
        # Overwriting in place: remove src, then move tmp into place.
        shutil.rmtree(args.src)
    elif os.path.exists(args.dst):
        shutil.rmtree(args.dst)
    shutil.move(tmp_dst, args.dst)

    print(f"\nWrote {args.dst}  ({du(args.dst):.0f} MB)")


if __name__ == "__main__":
    main()
