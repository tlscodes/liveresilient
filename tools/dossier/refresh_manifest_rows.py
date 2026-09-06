#!/usr/bin/env python3
"""Refresh named rows of tools/dossier/manifest.tsv against the files on disk.

The manifest records the size and sha256 of every artifact the funding documents
send a reviewer to, and CI verifies each row on every push: if one is edited, the
documents cite a file that no longer says what was measured.

Which means an append-only results file that legitimately gains a measured row
also needs its recorded hash to move — and the only honest way to move it is to
re-read the file. Hand-editing a digest into the manifest defeats the whole
record. This script does the re-reading, prints the before and the after so the
change is visible in the commit, and refuses to touch a path that is not already
a row: adding an artifact to the record is a different act from refreshing one,
and belongs to collect_evidence.sh.

Usage:
    python3 tools/dossier/refresh_manifest_rows.py tools/dossier/app_journey_results.tsv
    python3 tools/dossier/refresh_manifest_rows.py --check      # verify every row

Exit 0 when every named row was refreshed (or, with --check, when every row
matches); 1 on a missing file or an unknown path; 2 on a usage error.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MANIFEST = REPO / "tools" / "dossier" / "manifest.tsv"


def rows() -> list[list[str]]:
    lines = MANIFEST.read_text(encoding="utf-8").splitlines()
    return [line.split("\t") for line in lines]


def check() -> int:
    bad = 0
    counted = 0
    for parts in rows()[1:]:
        if len(parts) < 3:
            continue
        counted += 1
        path = REPO / parts[0]
        if not path.is_file():
            print(f"::error::{parts[0]}: in the manifest, not on disk")
            bad += 1
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != parts[2]:
            print(f"::error::{parts[0]}: recorded {parts[2]}, on disk {digest}")
            bad += 1
    print(f"checked {counted} row(s), {bad} mismatched")
    return 1 if bad else 0


def refresh(targets: list[str]) -> int:
    lines = MANIFEST.read_text(encoding="utf-8").splitlines()
    wanted = set(targets)
    seen: set[str] = set()

    for i, line in enumerate(lines):
        parts = line.split("\t")
        if len(parts) < 3 or parts[0] not in wanted:
            continue
        path = REPO / parts[0]
        if not path.is_file():
            print(f"::error::{parts[0]} is in the manifest but not on disk")
            return 1
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        print(f"{parts[0]}")
        print(f"  was  size={parts[1]} sha256={parts[2]}")
        print(f"  now  size={len(data)} sha256={digest}")
        parts[1] = str(len(data))
        parts[2] = digest
        lines[i] = "\t".join(parts)
        seen.add(parts[0])

    missing = sorted(wanted - seen)
    for name in missing:
        print(f"::error::{name} is not a row in manifest.tsv; refreshing is not adding")
    if missing:
        return 1

    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"refreshed {len(seen)} row(s)")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if argv[0] == "--check":
        return check()
    return refresh(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
