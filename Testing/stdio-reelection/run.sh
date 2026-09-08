#!/bin/sh
# End-to-end host-loss drill against the REAL ES Archive MCP binary (an unsigned
# Debug build, so it is not sandboxed and never opens the live archive's store —
# the script refuses to proceed if the host's store is anywhere under
# ~/Library/Containers). Scenario: A hosts, B and C relay → SIGKILL A → B and C
# re-elect (one hosts, one relays) → the new host's stdin closes and it lingers
# for its peer → the peer leaves and the host exits. Needs a built Debug app:
#
#   xcodebuild -workspace ../ES-Projects.xcworkspace -scheme "ES Archive MCP" \
#       -configuration Debug build CODE_SIGNING_ALLOWED=NO
#   Testing/stdio-reelection/run.sh [path/to/ES Archive MCP.app]
#
# See design-decisions/mid-session-reelection.md.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/ES-Projects-*/Build/Products/Debug/"ES Archive MCP.app" | head -1)}"
BIN="$APP/Contents/MacOS/ES Archive MCP"
[ -x "$BIN" ] || { echo "no built app at: $BIN" >&2; exit 2; }
FAKE_HOME="${TMPDIR:-/tmp}/es-reelection-drill.$$"
python3 "$HERE/e2e_reelection.py" "$BIN" 1 "$FAKE_HOME"
status=$?
rm -rf "$FAKE_HOME"
exit $status
