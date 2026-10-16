#!/usr/bin/env python3
"""Package the FLOODLINE source tree as a review-ready ZIP.

The r05 archive was assembled by hand, which meant the release asset could drift from the tree that
actually produced the place. This tool makes the archive a build stage: a fixed, reviewable file
list, no scratch probes, and a manifest inside the ZIP that records the revision, the place digest
and the byte size of every entry, so a reviewer can tell the archive apart from any other.

Writes releases/FLOODLINE-source.zip and prints the entry count and digest.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASES = ROOT / "releases"
ZIP_PATH = RELEASES / "FLOODLINE-source.zip"

# Explicitly listed: anything not named here is not shipped, so a stray probe or a local log can
# never ride along inside the release asset.
STATIC_FILES = [
    "README.md",
    "OPEN_IN_STUDIO.md",
    "HANDOFF.md",
    "default.project.json",
    "events.jsonl",
]
SOURCE_DIRS = ["src", "tools", "tests", "generated"]

# Scratch/one-off files that must never be packaged.
BLOCKED = re.compile(r"(^|/)probe[^/]*\.luau$|(^|/)\.private/|(^|/)\.env$|askpass")


def iter_entries() -> list[Path]:
    entries: list[Path] = []
    for name in STATIC_FILES:
        path = ROOT / name
        if path.exists():
            entries.append(path)
        else:
            print(f"[warn] missing optional file {name}", file=sys.stderr)
    for directory in SOURCE_DIRS:
        base = ROOT / directory
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file():
                entries.append(path)
    kept = []
    for path in entries:
        relative = path.relative_to(ROOT).as_posix()
        if BLOCKED.search(relative):
            print(f"[skip] {relative}")
            continue
        kept.append(path)
    return kept


def main() -> int:
    place = RELEASES / "FLOODLINE.rbxlx"
    place_bytes = place.read_bytes() if place.exists() else b""
    place_sha = hashlib.sha256(place_bytes).hexdigest() if place_bytes else "no place"
    revision = "unknown"
    config = ROOT / "src" / "shared" / "Config.luau"
    if config.exists():
        found = re.search(r'Version = "(r\d+)"', config.read_text(encoding="utf-8"))
        if found:
            revision = found.group(1)

    entries = iter_entries()
    files: list[dict] = []
    RELEASES.mkdir(exist_ok=True)
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in entries:
            relative = path.relative_to(ROOT).as_posix()
            data = path.read_bytes()
            archive.writestr(relative, data)
            files.append({
                "path": relative,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest()[:16],
            })
        manifest = {
            "revision": revision,
            "place": "releases/FLOODLINE.rbxlx",
            "placeBytes": len(place_bytes),
            "placeSha256": place_sha,
            "entries": len(files) + 1,  # the manifest itself
            "files": files,
            "note": "Source archive for FLOODLINE: Last District. Scratch probes, private "
                    "credentials and the stamped charter are excluded by construction.",
        }
        archive.writestr("SOURCE-MANIFEST.json", json.dumps(manifest, indent=2) + "\n")

    digest = hashlib.sha256(ZIP_PATH.read_bytes()).hexdigest()
    print(f"wrote {ZIP_PATH.relative_to(ROOT)}  {ZIP_PATH.stat().st_size} bytes  "
          f"{len(files) + 1} entries  revision {revision}  sha256 {digest[:16]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
