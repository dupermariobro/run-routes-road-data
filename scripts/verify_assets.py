#!/usr/bin/env python3
"""Check a built asset directory against its manifest before publishing.

Every listed file must be present with matching size and SHA-256, URLs must point
at the manifest's release tag, and no unlisted files may be present. Prints
"<release_tag> <region_count>" on success.
"""

import hashlib
import json
import os
import sys


def main():
    root = sys.argv[1]
    manifest = json.load(open(os.path.join(root, "manifest.json")))
    tag = manifest["release_tag"]
    listed = {"manifest.json", "manifest.json.sig"}
    for region in manifest["regions"]:
        name = os.path.basename(region["url"])
        listed.add(name)
        with open(os.path.join(root, name), "rb") as handle:
            data = handle.read()
        if len(data) != region["bytes"] or hashlib.sha256(data).hexdigest() != region["sha256"]:
            sys.exit(f"{name}: size or SHA-256 does not match manifest")
        if f"/releases/download/{tag}/" not in region["url"]:
            sys.exit(f"{name}: URL does not point at release {tag}")
    extra = sorted(set(os.listdir(root)) - listed)
    if extra:
        sys.exit(f"Unlisted files in asset dir: {extra}")
    print(tag, len(manifest["regions"]))


if __name__ == "__main__":
    main()
