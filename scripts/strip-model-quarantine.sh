#!/bin/sh
#
# strip-model-quarantine.sh — remove com.apple.quarantine from the embedder model.
#
# The EmbeddingGemma model is downloaded (gitignored; see .gitignore), and macOS
# stamps every downloaded file with the com.apple.quarantine extended attribute.
# The CoreML compile copies that xattr straight into the built .mlmodelc, and an
# App Store / TestFlight upload then fails validation with:
#
#   91109: Invalid package contents. The package contains one or more files with
#   the com.apple.quarantine extended file attribute … This attribute isn't
#   permitted in macOS apps distributed on TestFlight or the App Store.
#
# Run this once after (re)provisioning the model into
# ES_Archive/Embedders/EmbeddingGemmaEmbedder/, then rebuild / re-archive. It is a
# no-op once the source is clean. The build-phase guard (check-embedder-model.sh)
# fails the build if you forget, so you find out in seconds, not after an upload.
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT/ES_Archive/Embedders/EmbeddingGemmaEmbedder"

stripped=0
for p in "$MODEL/EmbeddingGemmaEncoder.mlpackage" "$MODEL/embeddinggemma.tokenizer.json"; do
    if [ -e "$p" ]; then
        xattr -rc "$p"          # clear all xattrs; model blobs need none
        echo "stripped: ${p#$ROOT/}"
        stripped=$((stripped + 1))
    fi
done

if [ "$stripped" -eq 0 ]; then
    echo "warning: no model found under ${MODEL#$ROOT/} — nothing to strip." >&2
    exit 0
fi
echo "done — the embedder model source is quarantine-free; rebuild or re-archive."
