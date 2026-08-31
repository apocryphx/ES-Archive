#!/usr/bin/env bash
#
# reset-embedder-selection.sh — clear ES Archive's cached embedder choice
#
# Background:
#   ESVectorEngine caches its cold-start heuristic result in NSUserDefaults so
#   subsequent launches don't re-run the priority/readiness scan. After the
#   May 6 2026 BGE migration, machines that had previously cached NLCE keep
#   selecting NLCE forever — the cache wins step 2 of +activeEmbedder before
#   the priority-aware heuristic at step 3 ever runs.
#
#   Symptom: log line `[VectorQueue] '...' — 512 dimensions` (NLCE shape, not
#   BGE's 384), and `_ANECompiler : ANECCompile() FAILED` warnings from
#   NLContextualEmbedding's internal ANE dispatch.
#
# Effect:
#   Clears two NSUserDefaults keys read by ESVectorEngine:
#     - ESVectorEngine.preferredEmbedderIdentifier (explicit override, if any)
#     - ESVectorEngine.heuristicEmbedderIdentifier (cached cold-start result)
#   On next ES Archive launch, the cold-start heuristic re-runs from scratch
#   and picks the highest-priority registered embedder whose assets are ready
#   for the inferred content language — that's BGE (priority 100) for English
#   archives.
#
# Safe to run while ES Archive is running, but the new selection only takes
# effect after the next process launch. The script warns if ES Archive is
# already running.
#
# Usage:
#   ./reset-embedder-selection.sh         # interactive, prompts before delete
#   ./reset-embedder-selection.sh --force # delete without prompting

set -u

DOMAIN="com.elarity.es-memory-mcp"
PREF_KEY="ESVectorEngine.preferredEmbedderIdentifier"
HEUR_KEY="ESVectorEngine.heuristicEmbedderIdentifier"

force=0
[[ "${1:-}" == "--force" ]] && force=1

# --- Show current state -------------------------------------------------------

echo "ES Archive embedder-selection reset utility"
echo "------------------------------------------"
echo "Preference domain: ${DOMAIN}"
echo

current_pref=$(defaults read "$DOMAIN" "$PREF_KEY" 2>/dev/null || true)
current_heur=$(defaults read "$DOMAIN" "$HEUR_KEY" 2>/dev/null || true)

if [[ -z "$current_pref" && -z "$current_heur" ]]; then
    echo "Both keys are already unset. Nothing to reset."
    exit 0
fi

echo "Current values:"
if [[ -n "$current_pref" ]]; then
    echo "  ${PREF_KEY} = ${current_pref}"
else
    echo "  ${PREF_KEY} = (unset)"
fi
if [[ -n "$current_heur" ]]; then
    echo "  ${HEUR_KEY} = ${current_heur}"
else
    echo "  ${HEUR_KEY} = (unset)"
fi
echo

# --- Warn if ES Archive is running --------------------------------------------

running_pid=$(pgrep -x "ES Memory MCP" || true)
if [[ -n "$running_pid" ]]; then
    echo "⚠️  ES Memory MCP is currently running (PID ${running_pid})."
    echo "   The reset takes effect on next launch — quit and relaunch the app"
    echo "   after this script completes."
    echo
fi

# --- Confirm ------------------------------------------------------------------

if [[ $force -eq 0 ]]; then
    read -r -p "Clear both keys? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# --- Delete -------------------------------------------------------------------

deleted=0
if [[ -n "$current_pref" ]]; then
    defaults delete "$DOMAIN" "$PREF_KEY" 2>/dev/null && deleted=$((deleted + 1))
    echo "  ✓ deleted ${PREF_KEY}"
fi
if [[ -n "$current_heur" ]]; then
    defaults delete "$DOMAIN" "$HEUR_KEY" 2>/dev/null && deleted=$((deleted + 1))
    echo "  ✓ deleted ${HEUR_KEY}"
fi

# --- Verify -------------------------------------------------------------------

after_pref=$(defaults read "$DOMAIN" "$PREF_KEY" 2>/dev/null || true)
after_heur=$(defaults read "$DOMAIN" "$HEUR_KEY" 2>/dev/null || true)

if [[ -n "$after_pref" || -n "$after_heur" ]]; then
    echo
    echo "❌ Verification failed — at least one key persists. Inspect by hand:"
    echo "     defaults read ${DOMAIN}"
    exit 2
fi

echo
echo "Done. ${deleted} key(s) cleared."
if [[ -n "$running_pid" ]]; then
    echo
    echo "Next step: quit ES Memory MCP and relaunch. Watch Console.app for"
    echo "the cold-start log line:"
    echo "   ESVectorEngine: cold-start heuristic chose <id> (dim=N, maxSeqLen=M)"
    echo "Expect dim=384 (BGE) instead of dim=512 (NLCE)."
fi
