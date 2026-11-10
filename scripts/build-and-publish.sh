#!/usr/bin/env bash
# Build roads-only SQLite files for every region in regions.json, sign a manifest,
# and publish them as a GitHub release. Processes one region at a time so peak
# disk use stays near the largest state's extract (~2 GB); the whole work
# directory is deleted on exit, success or failure.
#
#   scripts/build-and-publish.sh                  build all regions and publish
#   scripts/build-and-publish.sh --no-publish     build + sign, then stop (output kept in --out)
#   scripts/build-and-publish.sh --regions "us-il us-ri" --no-publish --out /tmp/rr
#
# Requires: osmium-tool, xz, openssl 3+, gh (authenticated), python3, and the
# signing key in the login keychain (see README).
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="dupermariobro/run-routes-road-data"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN_SERVICE="run-routes-road-data signing key"
USER_AGENT="run-routes-road-data/1 (+https://github.com/$REPO)"
MIN_FREE_GB=6

PUBLISH=1
ONLY_REGIONS=""
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-publish) PUBLISH=0 ;;
    --regions) ONLY_REGIONS="$2"; shift ;;
    --out) OUT_DIR="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done
if [[ $PUBLISH -eq 1 && -n "$ONLY_REGIONS" ]]; then
  echo "--regions is for test builds; combine it with --no-publish." >&2
  exit 64
fi
if [[ $PUBLISH -eq 0 && -z "$OUT_DIR" ]]; then
  echo "--no-publish needs --out <dir> to keep the results." >&2
  exit 64
fi

report_loop() {
  # Mirrors the result onto Mission Control's Open Loops board for scheduled runs.
  [[ "${RR_REPORT_LOOPS:-0}" == "1" ]] && command -v mc-loop >/dev/null || return 0
  local status="$1" next="$2"
  mc-loop open --key run-routes/road-data-refresh --project "Run Routes" \
    --title "Yearly road-data refresh" --owner claude --status "$status" \
    --next "$next" >/dev/null 2>&1 || true
  [[ "$status" == "in_progress" ]] && mc-loop done run-routes/road-data-refresh >/dev/null 2>&1 || true
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rr-road-data.XXXXXX")"
cleanup() {
  local code=$?
  rm -rf "$WORK"
  if [[ $code -ne 0 ]]; then
    report_loop blocked "Road-data refresh failed (exit $code). Log: ~/Library/Logs/run-routes-road-data.log"
  fi
}
trap cleanup EXIT

free_gb=$(df -g "$WORK" | awk 'NR==2 {print $4}')
if (( free_gb < MIN_FREE_GB )); then
  echo "Only ${free_gb} GB free; need ${MIN_FREE_GB} GB." >&2
  exit 1
fi

for tool in osmium xz openssl gh python3 shasum; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

RUN_DATE="$(date -u +%Y-%m-%d)"
TAG="road-data-$RUN_DATE"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"
ASSETS="$WORK/assets"
mkdir -p "$ASSETS"
ENTRIES="$WORK/entries.jsonl"
: > "$ENTRIES"

# Previous way counts guard against a truncated or broken upstream extract.
PREVIOUS="$WORK/previous-manifest.json"
curl -fsSL -A "$USER_AGENT" -o "$PREVIOUS" \
  "https://github.com/$REPO/releases/latest/download/manifest.json" 2>/dev/null || echo '{"regions":[]}' > "$PREVIOUS"

python3 -c 'import json,sys; [print(r["id"], r["name"].replace(" ", "_"), r["pbf_url"]) for r in json.load(open(sys.argv[1]))]' \
  "$ROOT_DIR/regions.json" > "$WORK/regions.txt"

while read -r region_id region_name_raw pbf_url; do
  if [[ -n "$ONLY_REGIONS" && " $ONLY_REGIONS " != *" $region_id "* ]]; then
    continue
  fi
  region_name="${region_name_raw//_/ }"
  started=$SECONDS
  pbf="$WORK/$region_id.osm.pbf"
  roads="$WORK/$region_id.roads.osm.pbf"
  geojson="$WORK/$region_id.geojsonseq"

  curl -fsSL --retry 4 --retry-delay 20 -A "$USER_AGENT" -o "$pbf" "$pbf_url"
  timestamp="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$pbf" 2>/dev/null || true)"
  data_date="${timestamp:0:10}"
  [[ "$data_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || data_date="$RUN_DATE"
  data_version="$region_id-$(echo "$data_date" | tr -d - | cut -c3-)-road-safety-v1"
  database="$WORK/$data_version.sqlite"

  osmium tags-filter "$pbf" \
    w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link \
    -O -o "$roads" --no-progress
  rm -f "$pbf"
  osmium export "$roads" -f geojsonseq --geometry-types=linestring -u type_id \
    -O -o "$geojson" --no-progress
  rm -f "$roads"
  counts="$(python3 "$ROOT_DIR/scripts/build_road_db.py" \
    --database "$database" --geojsonseq "$geojson" \
    --region-id "$region_id" --region-name "$region_name" \
    --data-version "$data_version" --data-date "$data_date")"
  rm -f "$geojson"

  check="$(sqlite3 "$database" "PRAGMA integrity_check;")"
  [[ "$check" == "ok" ]] || { echo "$region_id: integrity_check failed: $check" >&2; exit 1; }

  uncompressed_bytes=$(stat -f %z "$database")
  xz -9 -T0 "$database"
  asset="$database.xz"
  bytes=$(stat -f %z "$asset")
  sha256="$(shasum -a 256 "$asset" | awk '{print $1}')"
  mv "$asset" "$ASSETS/"

  python3 - "$ENTRIES" "$PREVIOUS" <<PY
import json, sys
counts = json.loads('''$counts''')
previous = {r["id"]: r for r in json.load(open(sys.argv[2])).get("regions", [])}
old = previous.get("$region_id", {}).get("way_count")
if old and counts["ways"] < old * 0.5:
    sys.exit(f"$region_id: way count fell from {old} to {counts['ways']}; refusing to publish")
entry = {
    "id": "$region_id",
    "name": "$region_name",
    "data_version": "$data_version",
    "data_date": "$data_date",
    "road_schema_version": "run-routes-road-safety-v1",
    "url": "$BASE_URL/$(basename "$asset")",
    "bytes": $bytes,
    "uncompressed_bytes": $uncompressed_bytes,
    "sha256": "$sha256",
    "way_count": counts["ways"],
}
with open(sys.argv[1], "a") as out:
    out.write(json.dumps(entry) + "\n")
PY
  printf '%-6s %-22s %6.2f MB  %6d ways  %4ds\n' "$region_id" "$region_name" \
    "$(echo "$bytes / 1048576" | bc -l)" "$(python3 -c "import json;print(json.loads('''$counts''')['ways'])")" \
    $((SECONDS - started))
done < "$WORK/regions.txt"

[[ -s "$ENTRIES" ]] || { echo "No regions were built." >&2; exit 1; }

python3 - "$ENTRIES" "$ASSETS/manifest.json" "$RUN_DATE" "$TAG" <<'PY'
import json, sys
regions = [json.loads(line) for line in open(sys.argv[1])]
manifest = {
    "schema": "run-routes-road-data-manifest-v1",
    "generated_at": sys.argv[3],
    "release_tag": sys.argv[4],
    "license": "ODbL-1.0",
    "attribution": "© OpenStreetMap contributors",
    "signature": "manifest.json.sig: base64 Ed25519 signature over the exact bytes of manifest.json",
    "regions": sorted(regions, key=lambda r: r["id"]),
}
with open(sys.argv[2], "w") as out:
    json.dump(manifest, out, indent=2, ensure_ascii=False)
    out.write("\n")
PY

# Sign the manifest's exact bytes; the app verifies with the public key in signing/.
key="$WORK/signing-key.pem"
( umask 077; security find-generic-password -s "$KEYCHAIN_SERVICE" -w | base64 -d > "$key" )
openssl pkeyutl -sign -rawin -inkey "$key" -in "$ASSETS/manifest.json" -out "$WORK/manifest.sig.bin"
rm -f "$key"
openssl pkeyutl -verify -rawin -pubin -inkey "$ROOT_DIR/signing/road-data-ed25519.pub.pem" \
  -in "$ASSETS/manifest.json" -sigfile "$WORK/manifest.sig.bin" >/dev/null
base64 < "$WORK/manifest.sig.bin" | tr -d '\n' > "$ASSETS/manifest.json.sig"

region_count=$(wc -l < "$ENTRIES" | tr -d ' ')
total_mb=$(du -sm "$ASSETS" | awk '{print $1}')
echo "Built $region_count regions, ${total_mb} MB total, signed manifest."

if [[ $PUBLISH -eq 0 ]]; then
  mkdir -p "$OUT_DIR"
  cp "$ASSETS"/* "$OUT_DIR"/
  echo "Not published. Output copied to $OUT_DIR"
  exit 0
fi

"$ROOT_DIR/scripts/publish-release.sh" "$ASSETS"
report_loop in_progress "Published $TAG ($region_count regions, ${total_mb} MB)"
