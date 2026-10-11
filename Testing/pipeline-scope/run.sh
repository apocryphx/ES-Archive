#!/bin/sh
# Persona-scope drill for the pipeline executor, against the REAL ES Archive
# MCP binary (an unsigned Debug build — not sandboxed, never opens the live
# archive's store; the script aborts if the host's store is anywhere under
# ~/Library/Containers). Two authors share one engine; each stores entries
# minutes apart. A stage that builds its own fetch (arc's time window) must
# not hand the other author's entries to the stages after it: the diagnostic
# count must equal what is rendered, and `… | arc | tag X` must not tag the
# other author's entries. Takes ~10 s.
#
#   xcodebuild -workspace ES-Archive.xcworkspace -scheme "ES Archive MCP" \
#       -configuration Debug build CODE_SIGNING_ALLOWED=NO
#   Testing/pipeline-scope/run.sh [path/to/ES Archive MCP.app]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/ES-Archive-*/Build/Products/Debug/"ES Archive MCP.app" | head -1)}"
BIN="$APP/Contents/MacOS/ES Archive MCP"
[ -x "$BIN" ] || { echo "no built app at: $BIN" >&2; exit 2; }
FAKE_HOME="${TMPDIR:-/tmp}/es-pipeline-scope-drill.$$"
python3 "$HERE/e2e_pipeline_scope.py" "$BIN" "$FAKE_HOME"
status=$?
rm -rf "$FAKE_HOME"
exit $status
