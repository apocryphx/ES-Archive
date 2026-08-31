#!/usr/bin/env bash
#
# package-mcpb.sh — notarized Xcode export → ES-Archive-MCP.mcpb
#
# The "ES Archive MCP" target is archived in Xcode and distributed via Direct
# Distribution (which signs with Developer ID, notarizes, and staples). Pass
# the exported .app to this script:
#
#   packaging/package-mcpb.sh "/path/to/ES Archive MCP.app"
#
# The Developer ID signature and notarization staple are preserved verbatim —
# no re-signing happens here (re-signing would void notarization and the app's
# CloudKit entitlements). A directly-spawned binary on a stranger's machine is
# exactly where Gatekeeper surprises are fatal, so notarization is not optional.

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"                     # …/ES-Archive/packaging
BUNDLE="$ROOT/bundle"
OUT="$ROOT/ES-Archive-MCP.mcpb"

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "usage: $0 \"/path/to/ES Archive MCP.app\"  (notarized Xcode export)" >&2
    exit 1
fi

echo "[package] staging bundle/server/"
rm -rf "$BUNDLE/server"
mkdir -p "$BUNDLE/server"
# --norsrc/--noqtn/--noacl: exports under ~/Documents pick up Finder/iCloud
# metadata (com.apple.FinderInfo on embedded frameworks) that makes strict
# codesign verification fail ("resource fork, Finder information, or similar
# detritus"). Copy without any of it — xattrs are not part of the signature
# seal, and the stapled notarization ticket is a regular file, so both survive.
ditto --norsrc --noqtn --noacl "$APP" "$BUNDLE/server/ES Archive MCP.app"

BUNDLED="$BUNDLE/server/ES Archive MCP.app"
echo "[package] verifying Developer ID + notarization on the bundled copy"
codesign -v --strict "$BUNDLED"
spctl -a -vv "$BUNDLED" 2>&1 | grep -q "Notarized Developer ID" || {
    echo "[package] app is not notarized (spctl)" >&2
    exit 1
}
xcrun stapler validate "$BUNDLED" >/dev/null || {
    echo "[package] notarization ticket not stapled" >&2
    exit 1
}

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "[package] validate manifest"
npx --yes @anthropic-ai/mcpb validate "$BUNDLE/manifest.json"

# Pack with zip -ry, not `mcpb pack`: the mcpb CLI follows symlinks and stores
# the embedded framework's binary three times as regular files, which destroys
# the Versions/Current symlink structure on extraction — Gatekeeper then
# rejects the app ("bundle format is ambiguous"). An .mcpb is a plain zip with
# manifest.json at the root, so zip -ry (store symlinks as symlinks) produces a
# fully compliant, smaller bundle.
echo "[package] pack mcpb (zip -ry, symlinks preserved)"
rm -f "$OUT"
(cd "$BUNDLE" && zip -q -r -y -X "$OUT" manifest.json icon.png server -x "*.DS_Store")

echo "[package] wrote $OUT"
ls -la "$OUT"
