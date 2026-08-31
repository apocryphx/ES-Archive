#!/bin/sh
# Build and run the standalone UDS transport test harness. No Xcode target: it
# clang-compiles the real transport sources (MCPUnixSocketServer, MCPSocketClient,
# ESEngineSocket) with a stub handler — no Core Data / AppKit — so it runs fast
# and anywhere. Exit code reflects PASS/FAIL.
#
#   Testing/uds-transport/run.sh
#
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/es-uds-test.$$"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

xcrun --sdk macosx clang \
  -fobjc-arc -O0 -g -Wall \
  -I "$ROOT/ES_Archive" \
  -I "$ROOT/ES_Archive/Server" \
  -I "$ROOT/ES_Archive/Stdio" \
  -o "$OUT" \
  "$ROOT/Testing/uds-transport/test_main.m" \
  "$ROOT/ES_Archive/Server/MCPUnixSocketServer.m" \
  "$ROOT/ES_Archive/Server/ESEngineSocket.m" \
  "$ROOT/ES_Archive/Stdio/MCPSocketClient.m" \
  -framework Foundation

"$OUT"
status=$?
rm -f "$OUT"
exit $status
