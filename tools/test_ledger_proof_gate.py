#!/usr/bin/env python3
"""Unit test for tools/ledger_proof_gate.py.

The defect this gate replaced could not be caught by running CI: the step went
green precisely because its input had gone missing, and a green step looks the
same either way. So the property under test here is the one a passing CI run
cannot demonstrate — that the gate is RED when there is nothing to measure.

Every case asserts an exit code, so a regression fails this file rather than
being absorbed by a zero.

Run: python3 tools/test_ledger_proof_gate.py    (exit 0 = all cases pass)
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ledger_proof_gate import check, row_is_proven, split_rows  # noqa: E402

FAILURES: list[str] = []


def case(name: str, got, want) -> None:
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: got {got!r}, want {want!r}")
        FAILURES.append(name)


def run(ledgers, backlog=None) -> int:
    """Run the gate over paths, swallowing its report."""
    return check(
        [Path(p) for p in ledgers],
        Path(backlog or "/nonexistent/backlog.json"),
        out=io.StringIO(),
    )


def write(tmp: Path, name: str, text: str) -> Path:
    p = tmp / name
    p.write_text(text, encoding="utf-8")
    return p


PROVEN_ROW = """### wave 1 · something closed · 2026-01-01
Prose about the wave.

```
dart analyze/test  call_core  ->  169 tests, clean
```
"""

LITERAL_ROW = """### wave 2 · another one · 2026-01-02
```
00:04 +287: All tests passed!
```
"""

UNPROVEN_ROW = """### wave 3 · closed with no runner output · 2026-01-03
```
packages/thing/lib/src/a.dart   new
packages/thing/test/a_test.dart new, 12 tests
```
"""


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # 1. The failure that started this: the input is gone. Red, not zero.
        case("missing ledger is red", run([tmp / "absent.md"]), 1)

        # 2. An empty file measures nothing.
        case("empty ledger is red", run([write(tmp, "empty.md", "   \n")]), 1)

        # 3. A file with no rows at all: either the rows went away or the heading
        #    pattern drifted. Both are red; neither is "0 of 0, fine".
        case("no rows is red", run([write(tmp, "norows.md", "# Title\n\nprose only\n")]), 1)

        # 4. Happy path.
        case("every row proven is green", run([write(tmp, "ok.md", PROVEN_ROW + LITERAL_ROW)]), 0)

        # 5. One row without a quoted result, not in any backlog.
        case("new gap is red", run([write(tmp, "gap.md", PROVEN_ROW + UNPROVEN_ROW)]), 1)

        # 6. The same gap, recorded in the backlog with a reason: the standing
        #    debt does not fail the build.
        gap = write(tmp, "gap2.md", PROVEN_ROW + UNPROVEN_ROW)
        heading = "### wave 3 · closed with no runner output · 2026-01-03"
        backlog = write(
            tmp,
            "backlog.json",
            json.dumps({"unproven_rows": {heading: "recorded, closing slot named"}}, ensure_ascii=False),
        )
        case("backlogged gap is green", run([gap], backlog), 0)

        # 7. The other direction, the one a growing-only backlog never proves: a
        #    listed row that has since acquired its proof leaves a stale entry.
        case("stale backlog entry is red", run([write(tmp, "ok2.md", PROVEN_ROW)], backlog), 1)

        # 8. Per row, not per document: the old gate compared a document-wide
        #    proof count against the row count, so one row quoting several results
        #    covered a neighbour quoting none.
        many = (
            "### wave 1 · a · 2026-01-01\n```\ndart test -> 10 tests, clean\n"
            "dart analyze -> No issues found\nflutter test -> 287 tests, clean\n```\n"
        )
        case("proof does not carry across rows", run([write(tmp, "cross.md", many + UNPROVEN_ROW)]), 1)

        # 9. Row splitting and the two accepted proof forms.
        case("rows split on headings", len(split_rows(PROVEN_ROW + LITERAL_ROW + UNPROVEN_ROW)), 3)
        case("summary-table line is proof", row_is_proven("dart analyze/test  x  ->  12 tests, clean"), True)
        case("verbatim runner output is proof", row_is_proven("00:04 +287: All tests passed!"), True)
        case("a file list with counts is not proof", row_is_proven("packages/a/test/a_test.dart new, 12 tests"), False)
        case("a bare command is not proof", row_is_proven("dart test"), False)

    print(f"\nledger proof gate self-test: {len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
