#!/usr/bin/env bash
#
# publish-registry.sh — GitHub release + MCP registry entry for ES Archive MCP
#
# Prerequisites, in order:
#   1. Xcode: Archive the "ES Archive MCP" scheme → Distribute App → Direct
#      Distribution (Developer ID, notarized, stapled) → export the .app.
#   2. packaging/package-mcpb.sh "/path/to/ES Archive MCP.app"
#      → packaging/ES-Archive-MCP.mcpb
#   3. gh auth status         (GitHub CLI logged in, repo scope)
#   4. mcp-publisher login github   (once; interactive device flow)
#
# Then:
#   packaging/publish-registry.sh            # release + publish
#   packaging/publish-registry.sh --dry-run  # release nothing, validate only
#
# Version comes from bundle/manifest.json. The release tag is v<version>; if
# the release already exists the asset is replaced. The registry entry is
# packaging/registry/server.json with __VERSION__ and __SHA256__ filled in,
# written to packaging/registry/server.generated.json (gitignored).

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
MCPB="$ROOT/ES-Archive-MCP.mcpb"
TEMPLATE="$ROOT/registry/server.json"
OUT="$ROOT/registry/server.generated.json"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[[ -f "$MCPB" ]] || { echo "missing $MCPB — run package-mcpb.sh first" >&2; exit 1; }

VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROOT/bundle/manifest.json")"
TAG="v$VERSION"
SHA="$(shasum -a 256 "$MCPB" | cut -d' ' -f1)"
echo "[registry] version $VERSION, sha256 $SHA"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" "$TEMPLATE" > "$OUT"
echo "[registry] wrote $OUT"

echo "[registry] validate"
mcp-publisher validate "$OUT"

if (( DRY )); then echo "[registry] dry run, stopping before release and publish"; exit 0; fi

echo "[registry] GitHub release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$MCPB" --clobber
else
  gh release create "$TAG" "$MCPB" \
    --title "ES Archive MCP $VERSION" \
    --notes "Notarized Developer ID build of ES Archive MCP $VERSION as a Claude Desktop extension (.mcpb). The Mac App Store build is at https://apps.apple.com/app/id6806891612. sha256: $SHA"
fi

# The registry fetches the asset to verify the hash, so wait until GitHub serves it.
URL="https://github.com/apocryphx/ES-Archive/releases/download/$TAG/ES-Archive-MCP.mcpb"
for i in $(seq 1 12); do
  curl -sILo /dev/null -w '%{http_code}' "$URL" | grep -q '^302\|^200' && break
  sleep 5
done

echo "[registry] publish"
mcp-publisher publish "$OUT"
echo "[registry] done: https://registry.modelcontextprotocol.io/?search=es-archive"
