#!/bin/zsh
# Deploy the canonical skill files to the local skill folders:
#   skills/claude/es-archive-*/SKILL.md → Claude (Code, Desktop, claude.ai packages)
#   skills/codex/*/                     → Codex (~/.codex/skills)
#
# The repo is the source of truth — see skills/README.md. Run this after any
# edit to a SKILL.md here. Re-uploading .skill packages to claude.ai (if the
# skills are registered by upload) remains a manual step.

set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "$0")/../skills/claude" && pwd)"
CODEX_SKILLS_SRC="$(cd "$(dirname "$0")/../skills/codex" && pwd)"
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

# Claude Code reads skills from ~/.claude/skills — plain SKILL.md files, no
# .skill packaging. This is the deployment that live sessions actually load.
CC_SKILLS="$HOME/.claude/skills"
if [[ -d "$CC_SKILLS" ]]; then
    for src in "$REPO_SKILLS"/es-archive-*/SKILL.md; do
        name="$(basename "$(dirname "$src")")"
        mkdir -p "$CC_SKILLS/$name"
        cp "$src" "$CC_SKILLS/$name/SKILL.md"
        echo "deployed $name -> $CC_SKILLS"
    done
else
    echo "skip (missing): $CC_SKILLS"
fi

# Codex reads skills from ~/.codex/skills — one folder per skill (SKILL.md plus
# any agents/ metadata), copied whole.
CX_SKILLS="$HOME/.codex/skills"
if [[ -d "$CX_SKILLS" ]]; then
    for src in "$CODEX_SKILLS_SRC"/*/; do
        name="$(basename "$src")"
        mkdir -p "$CX_SKILLS/$name"
        rsync -a --delete "$src" "$CX_SKILLS/$name/"
        echo "deployed $name -> $CX_SKILLS"
    done
else
    echo "skip (missing): $CX_SKILLS"
fi
