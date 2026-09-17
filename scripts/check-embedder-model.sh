#!/bin/sh
#
# check-embedder-model.sh — build-phase guard for the embedder model.
#
# The EmbeddingGemma model lives in a git submodule (ES_Archive/Embedders/
# embeddinggemma-300m-qat-q4_0-coreml, hosted on Hugging Face via LFS). A clone
# made without --recurse-submodules leaves that directory empty, so the build
# produces an .app WITHOUT the model — and the engine then fails SILENTLY at
# runtime: semantic search returns "No memories in your scope yet" and the host
# process sits at ~64 MB instead of ~500 MB. This was found the hard way in the
# UDS live test (see design-decisions/uds-live-test-report-hardened.md). A red
# build is cheaper than that mystery.
#
# The check verifies the SHIPPABLE PRODUCT (ground truth), so it catches both a
# missing source file and a file that was never added to the target's resources.
# Wired as a Run Script phase into both app targets, after "Copy Bundle Resources".
#
set -u

RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
SRC="${SRCROOT}/ES_Archive/Embedders/embeddinggemma-300m-qat-q4_0-coreml"

status=0
require() {
    if [ ! -e "$RES/$1" ]; then
        echo "error: embedder resource missing from the built bundle: $1" >&2
        status=1
    fi
}

# .mlpackage source is compiled to .mlmodelc in the bundle; the tokenizer is copied as-is.
require "EmbeddingGemmaEncoder.mlmodelc"
require "embeddinggemma.tokenizer.json"

if [ "$status" -ne 0 ]; then
    echo "error: The EmbeddingGemma model submodule is missing or empty, so this build" >&2
    echo "error: produced a silently non-functional engine (empty semantic search)." >&2
    echo "error: Restore it with:  git submodule update --init  (needs git-lfs), which fills:" >&2
    echo "error:   $SRC" >&2
    echo "error: (EmbeddingGemmaEncoder.mlpackage + embeddinggemma.tokenizer.json), confirm" >&2
    echo "error: they are members of this target's Copy Bundle Resources phase, then rebuild." >&2
    exit 1
fi

# Reject the com.apple.quarantine xattr on the built model. A git checkout does
# not set it, but a model dropped in from a browser download carries it, and
# the CoreML compile copies that attribute into the bundle's .mlmodelc. An App
# Store / TestFlight upload then fails validation with error 91109. Catch it
# here as a red build (a read-only scan of these already-declared input
# resources, so it stays sandbox-compatible) instead of after a long upload
# round-trip.
bad=$(find "$RES/EmbeddingGemmaEncoder.mlmodelc" "$RES/embeddinggemma.tokenizer.json" -type f 2>/dev/null | while IFS= read -r f; do
    if xattr "$f" 2>/dev/null | grep -qi "com.apple.quarantine"; then printf '%s\n' "${f#$RES/}"; fi
done)
if [ -n "$bad" ]; then
    echo "error: the embedder model carries com.apple.quarantine — App Store / TestFlight" >&2
    echo "error: upload will fail (error 91109). Offending file(s):" >&2
    printf 'error:   %s\n' $bad >&2
    echo "error: Run scripts/strip-model-quarantine.sh, then rebuild / re-archive." >&2
    exit 1
fi

echo "note: embedder model present in bundle and quarantine-free (EmbeddingGemmaEncoder.mlmodelc + tokenizer)."
