#!/bin/sh
# Onboarding drill against the REAL ES Archive MCP binary (an unsigned Debug
# build — not sandboxed, never opens the live archive's store; the script aborts
# if the host's store is anywhere under ~/Library/Containers). Replays Claude
# Desktop's probe handoff and checks who greets: the probe must stand down once
# its session ended, the promoted host must greet during startup, and a host
# promoted later must stay quiet. Takes ~45 s (the 30 s startup window is real).
#
#   xcodebuild -workspace ES-Archive.xcworkspace -scheme "ES Archive MCP" \
#       -configuration Debug build CODE_SIGNING_ALLOWED=NO
#   Testing/stdio-onboarding/run.sh [path/to/ES Archive MCP.app]
#
# See design-decisions/mid-session-reelection.md.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/ES-Archive-*/Build/Products/Debug/"ES Archive MCP.app" | head -1)}"
BIN="$APP/Contents/MacOS/ES Archive MCP"
[ -x "$BIN" ] || { echo "no built app at: $BIN" >&2; exit 2; }
FAKE_HOME="${TMPDIR:-/tmp}/es-onboarding-drill.$$"
python3 "$HERE/e2e_onboarding.py" "$BIN" "$FAKE_HOME"
status=$?
rm -rf "$FAKE_HOME"
exit $status
