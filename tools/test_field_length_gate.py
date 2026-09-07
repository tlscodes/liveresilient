#!/usr/bin/env python3
"""Unit test for tools/dossier/field_length_gate.py.

The defect this gate exists for is invisible to the eye and to CI alike: a
prepared block that is longer than the form field it is pasted into looks
perfectly correct in the document, and the browser drops the overflow without a
warning. So the properties worth pinning are the ones a passing run cannot
show — that the gate is RED on an over-long block, on a missing file, and on a
file with no blocks at all.

Run: python3 tools/test_field_length_gate.py    (exit 0 = all cases pass)
"""

from __future__ import annotations

import io
import sys
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "dossier"))

from field_length_gate import check, parse  # noqa: E402

FAILURES: list[str] = []
FENCE = "```"


def case(name: str, got, want) -> None:
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: got {got!r}, want {want!r}")
        FAILURES.append(name)


def run(paths) -> int:
    with redirect_stdout(io.StringIO()):
        return check([Path(p) for p in paths])


def doc(*blocks: str) -> str:
    return "".join(blocks)


def block(title: str, body: str, limit: int | None = None) -> str:
    declared = (
        f'\n<!-- FIELD LIMIT {limit} characters — form field "x" -->\n' if limit else ""
    )
    return f"## {title}\n{declared}\n{FENCE}\n{body}\n{FENCE}\n\n"


def write(tmp: Path, name: str, text: str) -> Path:
    p = tmp / name
    p.write_text(text, encoding="utf-8")
    return p


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # 1. The gate cannot measure what is not there.
        case("missing file is red", run([tmp / "absent.md"]), 1)
        case("no blocks is red", run([write(tmp, "empty.md", "# Title\n\nprose\n")]), 1)

        # 2. A block inside its declared limit passes; one character over fails.
        #    "abcd\n" is five characters counting the newline, which is what a
        #    paste may carry and therefore what the gate measures.
        case("inside the limit is green", run([write(tmp, "ok.md", doc(block("A", "abcd", 5)))]), 0)
        case("one over the limit is red", run([write(tmp, "over.md", doc(block("A", "abcd", 4)))]), 1)

        # 3. An undeclared block is measured and printed but cannot fail: most
        #    fields have no limit, and inventing one would be a guess.
        case(
            "undeclared block cannot fail",
            run([write(tmp, "undecl.md", doc(block("A", "x" * 10_000)))]),
            0,
        )

        # 4. One over-long block among several fails the whole file.
        many = doc(block("A", "abcd", 100), block("B", "y" * 50, 10), block("C", "z", 100))
        case("one bad block fails the file", run([write(tmp, "mixed.md", many)]), 1)

        # 5. Parsing: title, limit and measured size, including the newline.
        blocks = parse(write(tmp, "parse.md", doc(block("Abstract", "abcd", 1000))))
        case("one block parsed", len(blocks), 1)
        case("title parsed", blocks[0].title, "Abstract")
        case("limit parsed", blocks[0].limit, 1000)
        case("size counts the trailing newline", blocks[0].size, 5)

    print(f"\nfield length gate self-test: {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
