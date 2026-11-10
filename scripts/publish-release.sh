#!/usr/bin/env bash
# Publish a built, signed asset directory (manifest.json, manifest.json.sig and
# the .sqlite.xz files it lists) as the latest GitHub release.
#   scripts/publish-release.sh <asset-dir>
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="dupermariobro/run-routes-road-data"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${1:?usage: publish-release.sh <asset-dir>}"

# Refuse anything that doesn't verify end to end: signature, every listed file
# present with matching size and SHA-256, and no unlisted files.
SIG="$(mktemp)"
trap 'rm -f "$SIG"' EXIT
base64 -d < "$ASSETS/manifest.json.sig" > "$SIG"
openssl pkeyutl -verify -rawin -pubin -inkey "$ROOT_DIR/signing/road-data-ed25519.pub.pem" \
  -in "$ASSETS/manifest.json" -sigfile "$SIG" >/dev/null
read -r TAG REGION_COUNT < <(python3 - "$ASSETS" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json")))
listed = set()
for region in manifest["regions"]:
    name = os.path.basename(region["url"])
    listed.add(name)
    path = os.path.join(root, name)
    data = open(path, "rb").read()
    if len(data) != region["bytes"] or hashlib.sha256(data).hexdigest() != region["sha256"]:
        sys.exit(f"{name}: size or SHA-256 does not match manifest")
    if f"/releases/download/{manifest['release_tag']}/" not in region["url"]:
        sys.exit(f"{name}: URL does not point at release {manifest['release_tag']}")
extra = set(os.listdir(root)) - listed - {"manifest.json", "manifest.json.sig"}
if extra:
    sys.exit(f"Unlisted files in asset dir: {sorted(extra)}")
print(manifest["release_tag"], len(manifest["regions"]))
PY
)

gh release create "$TAG" "$ASSETS"/* --repo "$REPO" --latest \
  --title "Road data ${TAG#road-data-}" \
  --notes "Major-road (motorway, trunk, primary) geometry for $REGION_COUNT US regions, built from Geofabrik OpenStreetMap extracts. Data © OpenStreetMap contributors, available under the Open Database License (ODbL 1.0). Verify manifest.json against manifest.json.sig with signing/road-data-ed25519.pub.pem."

# Confirm the stable URL the app uses now resolves to this release's manifest.
live_tag="$(curl -fsSL "https://github.com/$REPO/releases/latest/download/manifest.json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["release_tag"])')"
[[ "$live_tag" == "$TAG" ]] || { echo "latest/download/manifest.json serves $live_tag, expected $TAG" >&2; exit 1; }
echo "Published $TAG ($REGION_COUNT regions): https://github.com/$REPO/releases/tag/$TAG"
