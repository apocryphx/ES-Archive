#!/bin/zsh
# Deploy the canonical skill files (skills/*/SKILL.md) to the local Claude
# skill folders and rebuild the .skill zip packages.
#
# The repo is the source of truth — see skills/README.md. Run this after any
# edit to a SKILL.md here. Re-uploading .skill packages to claude.ai (if the
# skills are registered by upload) remains a manual step.

set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "$0")/../skills" && pwd)"
TARGETS=("$HOME/Claude/Skills" "$HOME/Documents/Claude/Skills")

for target in "${TARGETS[@]}"; do
    [[ -d "$target" ]] || { echo "skip (missing): $target"; continue; }
    for src in "$REPO_SKILLS"/es-archive-*/SKILL.md; do
        name="$(basename "$(dirname "$src")")"
        mkdir -p "$target/$name"
        cp "$src" "$target/$name/SKILL.md"
        ( cd "$target" && rm -f "$name.skill" && zip -q "$name.skill" "$name/SKILL.md" )
        echo "deployed $name -> $target"
    done
done
