#!/usr/bin/env python3
"""Every prepared form block fits the field it is pasted into.

The submission file holds one fenced block per form field. Two of them were
over the field's `maxlength` — the abstract 1652 characters into 1000, the
budget answer 5694 into 4000 — and a browser truncates silently: it keeps the
opening characters and drops the rest with no warning, no error and no visual
cue. The abstract's cut fell mid-sentence and discarded the strongest evidence
in the block; the budget's fell mid-word and took two milestones' entire
justification with it while the table still asked for the full amount.

Nothing about that is visible by reading the document, which is why it survived
several careful passes. It is visible to `wc -c`, so that is the check.

A field's limit is declared in an HTML comment before its fence:

    <!-- FIELD LIMIT 1000 characters. ... -->

Blocks with no declared limit are measured and printed but cannot fail: most
fields have no limit, and inventing one would be a guess. A declaration whose
block is missing DOES fail, so a heading rename cannot silently disarm a limit.

Length is measured the conservative way — the fenced content INCLUDING its
trailing newline — because whether a paste carries that last newline depends on
how the text is selected, and the gate should not pass on the assumption that
it does not.

Usage:
    python3 tools/dossier/field_length_gate.py [file ...]

Exit 0 only when every declared limit is satisfied.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
DEFAULT_FILES = ["tools/dossier/NLNET_SUBMISSION_READY.md"]

HEADING = re.compile(r"^##\s+(?P<title>.+?)\s*$")
LIMIT = re.compile(r"FIELD LIMIT\s+(?P<n>[0-9]+)\s+characters", re.IGNORECASE)
FENCE = re.compile(r"^```")


class Block:
    def __init__(self, title: str, limit: int | None, text: str, line: int) -> None:
        self.title = title
        self.limit = limit
        self.text = text
        self.line = line

    @property
    def size(self) -> int:
        """Characters a paste carries, counting the trailing newline."""
        return len(self.text)


def parse(path: Path) -> list[Block]:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    blocks: list[Block] = []
    title = None
    limit = None
    i = 0
    while i < len(lines):
        line = lines[i]
        heading = HEADING.match(line.rstrip("\n"))
        if heading:
            title = heading.group("title")
            limit = None
            i += 1
            continue
        found = LIMIT.search(line)
        if found and title:
            limit = int(found.group("n"))
            i += 1
            continue
        if FENCE.match(line) and title:
            start = i + 1
            j = start
            while j < len(lines) and not FENCE.match(lines[j]):
                j += 1
            blocks.append(Block(title, limit, "".join(lines[start:j]), start + 1))
            title, limit = None, None
            i = j + 1
            continue
        i += 1
    return blocks


def check(paths: list[Path]) -> int:
    failures: list[str] = []
    for path in paths:
        if not path.is_file():
            print(f"::error::{path}: not found — the gate cannot measure a missing file")
            failures.append(str(path))
            continue
        blocks = parse(path)
        if not blocks:
            print(f"::error::{path}: no fenced field blocks found")
            failures.append(str(path))
            continue
        declared = 0
        print(f"{path}: {len(blocks)} field block(s)")
        for block in blocks:
            if block.limit is None:
                print(f"  {block.size:6d}  (no limit declared)  {block.title}")
                continue
            declared += 1
            headroom = block.limit - block.size
            state = "ok" if headroom >= 0 else "OVER"
            print(
                f"  {block.size:6d} / {block.limit:<6d} {state:4s} "
                f"({headroom:+d})  {block.title}  (line {block.line})"
            )
            if headroom < 0:
                failures.append(
                    f"{path}:{block.line}: '{block.title}' is {block.size} characters "
                    f"into a {block.limit}-character field — a browser will keep the first "
                    f"{block.limit} and discard the rest without saying so"
                )
        print(f"  {declared} block(s) carry a declared limit")
    for line in failures:
        print(f"::error::{line}")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    names = argv or DEFAULT_FILES
    paths = [Path(n) if Path(n).is_absolute() else REPO / n for n in names]
    return check(paths)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
