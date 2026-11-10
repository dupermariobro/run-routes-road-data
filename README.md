# Run Routes road data

Offline major-road data for the [Run Routes](https://github.com/dupermariobro) iPhone app.
The app uses it to check how much of a generated running route follows highways
and arterials, entirely on the phone. Users download only their own state, once.
No route or location data is sent anywhere.

Data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
available under the [Open Database License (ODbL 1.0)](https://opendatacommons.org/licenses/odbl/1-0/).
Extracts courtesy of [Geofabrik](https://download.geofabrik.de/).

## What's published

Each [release](https://github.com/dupermariobro/run-routes-road-data/releases) contains:

| File | Contents |
|---|---|
| `manifest.json` | Every region: id, name, data date, download URL, size, SHA-256, road count |
| `manifest.json.sig` | Base64 Ed25519 signature over the exact bytes of `manifest.json` |
| `us-xx-YYMMDD-road-safety-v1.sqlite.xz` | One file per region (50 states, DC, Puerto Rico, U.S. Virgin Islands) |

First release (`road-data-2026-11-10`, OSM data of 2026-11-08): 53 regions,
about 100 MB in total. Median 1.5 MB per region; largest California 8.8 MB, Texas 7.1 MB,
Florida 5.3 MB; smallest U.S. Virgin Islands 0.05 MB.

The app always reads the newest manifest from the stable URL:

```
https://github.com/dupermariobro/run-routes-road-data/releases/latest/download/manifest.json
```

## File format

Each region is an xz-compressed SQLite database, schema `run-routes-road-safety-v1`.
These are the same road tables the app bundles for Illinois, so its existing reader opens them unchanged.

- `road_ways`: OSM `highway=motorway|motorway_link|trunk|trunk_link|primary|primary_link` ways, with `osm_id`, `name`, `ref`, `classification`, `maxspeed`, `foot`
- `road_geometry_chunks`: up to 12 points per chunk, little-endian float32 `lon,lat` pairs
- `road_geometry_rtree`: R-tree over chunk bounding boxes
- `metadata`: `region_id`, `region_name`, `west`/`south`/`east`/`north`, `road_schema_version`, `road_data_version`, `road_data_date`, source and license fields, counts

## Verifying a download

```bash
base64 -d < manifest.json.sig > manifest.sig.bin
openssl pkeyutl -verify -rawin -pubin -inkey signing/road-data-ed25519.pub.pem \
  -in manifest.json -sigfile manifest.sig.bin
shasum -a 256 us-il-*.sqlite.xz   # compare with the manifest entry
```

The raw 32-byte public key (for `CryptoKit.Curve25519.Signing.PublicKey(rawRepresentation:)`)
is in `signing/road-data-ed25519.pub.raw.b64`.

## Rebuilding

`scripts/build-and-publish.sh` downloads each region's Geofabrik extract, keeps
only major roads (`osmium tags-filter`), exports line geometry, builds the
SQLite file, compresses it, signs the manifest, and publishes a release.
It works one region at a time (peak disk ~2 GB) and deletes its work directory
when it exits. Nothing is published unless every region builds. A region whose
road count falls below half of the previous release stops the run.

```bash
scripts/build-and-publish.sh --regions "us-il us-ri" --no-publish --out /tmp/rr   # test build
scripts/build-and-publish.sh                                                      # full build + publish
scripts/publish-release.sh /tmp/rr-full                                           # publish a reviewed build
```

Needs `osmium-tool`, `xz`, `openssl` 3+, an authenticated `gh`, and the signing
key in the macOS login keychain (service `run-routes-road-data signing key`).

### Schedule

A LaunchAgent runs the full build yearly on 10 November at 03:30 on the Mac
mini, logs to `~/Library/Logs/run-routes-road-data.log`, and reports the result
to Mission Control Open Loops (`run-routes/road-data-refresh`). It needs a
logged-in session, because it reads the login keychain and `gh` credentials.

```bash
schedule/install.sh            # install or update for this checkout
schedule/install.sh --remove   # uninstall
```

### Signing key

The private key exists only in the Mac mini's login keychain. If it's lost, generate a
new pair, commit the new public key, and ship an app update that trusts it.
Keep a backup in a password manager:

```bash
security find-generic-password -s "run-routes-road-data signing key" -w | base64 -d
```
