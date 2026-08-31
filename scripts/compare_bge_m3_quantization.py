#!/usr/bin/env python3
"""
Cosine-similarity comparison harness for BGE-M3 mlpackage variants.

Encodes a set of representative texts through two Core ML models, applies
the same CLS-pool + L2-normalize that BGEM3Embedder.m does at runtime
(taking last_hidden_state[0, 0, :]), and reports per-text cosine + summary.

Use it to validate any new quantization or palettization variant before
shipping. The retrieval-quality bar for BGE-M3 retrieval in this archive
is mean cosine ≥ 0.99 vs the fp16 baseline; below that, the score
distribution shifts enough to recalibrate thresholds.

Requires: coremltools, tokenizers, numpy. (Tokenizers is the small Rust-
backed HF lib — much smaller than the full transformers package.)

    pip install 'coremltools>=9.0' tokenizers numpy
    python3 scripts/compare_bge_m3_quantization.py \\
        --orig PATH/TO/BGEM3Encoder_fp16.mlpackage \\
        --variant PATH/TO/BGEM3Encoder_int8.mlpackage
"""
import argparse, sys

DEFAULT_TOKENIZER = "ES_Archive/BGEM3Embedder/bge-m3.tokenizer.json"
MAX_LEN = 512  # matches the BGEM3Encoder.mlpackage's fixed input shape

# Representative coverage: short English, prose English, ES Memory archive
# style, German, mixed multilingual.
DEFAULT_TEXTS = [
    "hello world",
    "The Cross-Substrate Dialogue between Gemma and GPT.",
    "ES Memory's vector engine uses cosine similarity over BGE-M3 embeddings.",
    "Die Sprache ist ein Werkzeug, das wir nicht ohne weiteres durchschauen.",
    ("Sentiment scoring removed from Electric Sheep schema after a paragraph-mode "
     "probe of NLTagger's classifier returned -0.6 for five distinct inputs and "
     "-1.0 for one. Scoring is now cosine x sigmoid(daysSinceLastAccess)."),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--orig", required=True, help="baseline .mlpackage (fp16 reference)")
    parser.add_argument("--variant", required=True, help="quantized/palettized .mlpackage to evaluate")
    parser.add_argument("--tokenizer", default=DEFAULT_TOKENIZER,
                        help=f"tokenizer.json path (default: {DEFAULT_TOKENIZER})")
    parser.add_argument("--cpu-only", action="store_true",
                        help="force CPU_ONLY for both models — neutralizes ANE/GPU compute-path drift")
    args = parser.parse_args()

    try:
        import coremltools as ct
        from tokenizers import Tokenizer
        import numpy as np
    except ImportError as e:
        sys.exit(f"error: missing dependency ({e}). Install: "
                 f"pip install 'coremltools>=9.0' tokenizers numpy")

    print(f"Tokenizer:  {args.tokenizer}")
    tok = Tokenizer.from_file(args.tokenizer)
    tok.enable_padding(length=MAX_LEN, pad_id=1, pad_token="<pad>")
    tok.enable_truncation(max_length=MAX_LEN)

    units = ct.ComputeUnit.CPU_ONLY if args.cpu_only else ct.ComputeUnit.CPU_AND_NE
    print(f"Compute:    {units}")
    print(f"Loading {args.orig}")
    m_orig = ct.models.MLModel(args.orig, compute_units=units)
    print(f"Loading {args.variant}")
    m_var  = ct.models.MLModel(args.variant, compute_units=units)

    def encode(text):
        e = tok.encode(text)
        return (np.array([e.ids],            dtype=np.int32),
                np.array([e.attention_mask], dtype=np.int32))

    def embed(model, ids, mask):
        out = model.predict({"input_ids": ids, "attention_mask": mask})
        h = out["last_hidden_state"]    # (1, MAX_LEN, hidden_dim)
        cls = h[0, 0, :].astype(np.float32)
        n = float(np.linalg.norm(cls))
        return cls / (n if n > 0 else 1.0)

    print(f"\n{'#':>2}  {'cos':>7}  text")
    print(f"{'-'*2}  {'-'*7}  {'-'*60}")
    cosines = []
    for i, text in enumerate(DEFAULT_TEXTS, 1):
        ids, mask = encode(text)
        a = embed(m_orig, ids, mask)
        b = embed(m_var,  ids, mask)
        c = float(np.dot(a, b))
        cosines.append(c)
        truncated = text[:60] + ("..." if len(text) > 60 else "")
        print(f"{i:>2}  {c:.5f}  {truncated}")

    cosines = np.array(cosines)
    print(f"\nSummary across {len(DEFAULT_TEXTS)} texts:")
    print(f"  mean cos:  {cosines.mean():.5f}")
    print(f"  min cos:   {cosines.min():.5f}")
    print(f"  max cos:   {cosines.max():.5f}")

    # Retrieval-quality gate: the threshold below which score distribution
    # shifts enough to recalibrate ES Memory's verbatim/paraphrase bands.
    if cosines.mean() < 0.99:
        print(f"\nWARNING: mean cosine {cosines.mean():.5f} is below 0.99 — variant "
              f"shifts score distribution enough to recalibrate thresholds.")
        sys.exit(2)


if __name__ == "__main__":
    main()
