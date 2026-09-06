#!/usr/bin/env python3
"""Every ledger row that claims a wave closed must quote the command that proved it.

This replaces a two-line grep that lived in .github/workflows/ci.yml. That version
counted proof strings across the whole document and compared the total against the
row count, which is a weaker property than its name: one row quoting three results
covered a neighbour quoting none. Worse, when the document was archived to a
subdirectory the greps hit a missing file, `rows` became empty, `[ "" -gt 0 ]`
errored, the condition went false and the step exited 0 — a gate reporting green
while measuring nothing.

The invariant this file enforces, and the reason it is a script with its own test:

    a gate may go green only on a positive measurement. It asserts every
    precondition of that measurement — the input exists, it is non-empty, the
    denominator is greater than zero — and fails when any is unmet, so the
    absence of the thing to measure is red, never zero.

Checking is per row, not per document. A row is a `### موج`/`### wave` heading and
everything up to the next heading; it is proven when its own body quotes a verifier
result. Rows that are known to have closed without one are listed in the backlog
file with a reason, exactly as tools/gate_ratchet.py does for gates: the gate then
fails on CHANGE — a new unproven row, or a listed row that has quietly acquired a
proof and left the list stale — rather than on the standing debt.

Usage:
    python3 tools/ledger_proof_gate.py [ledger.md ...]   # defaults to the ledger below
    python3 tools/ledger_proof_gate.py --backlog b.json ledger.md

Exit 0 only when every ledger measured cleanly; 1 on any gap; 2 on a usage error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The ledger moved into docs/archive_flagged/ when its prose was archived. The rows
# still make closure claims, so they still owe their proof: the path is named here
# as an explicit decision rather than left as an implication of the move.
DEFAULT_LEDGERS = ["docs/archive_flagged/PLAN_five_tickets_v4.md"]
DEFAULT_BACKLOG = "docs/ledger_backlog.json"

ROW_HEADING = re.compile(r"^###\s+(?:موج|wave)\b.*$", re.MULTILINE)

# Verbatim tool output, quoted into the row as the runner printed it.
LITERAL_OUTPUT = re.compile(r"All tests passed|No issues found")

# The ledger's other, equally valid form: a summary table whose line carries both
# the command and what it returned — `dart analyze/test  call_core  ->  169 tests,
# clean`. The first version of this gate recognised only LITERAL_OUTPUT and so
# called two fully-evidenced rows unproven; a gate that misreads its own project's
# vocabulary produces false red, which is how gates get switched off.
COMMAND = re.compile(
    r"\b(?:dart\s+(?:analyze|test|format|run)|flutter\s+(?:test|analyze|build|drive)"
    r"|python3\s+\S|bash\s+\S|node\s+--test|npm\s+(?:test|run)|gh\s+run)",
    re.IGNORECASE,
)
RESULT = re.compile(
    r"(?:All tests passed|No issues found|\bclean\b|\b\d+\s+tests?\b|\bexit\s+0\b|\bno issues\b)",
    re.IGNORECASE,
)


def row_is_proven(body: str) -> bool:
    """True when the row quotes a verifier result, in either accepted form.

    A file list with test counts beside it is deliberately NOT proof: it says what
    was written, not what was run. The property this gate defends is that the row
    quotes the command whose exit decided the claim.
    """
    if LITERAL_OUTPUT.search(body):
        return True
    return any(COMMAND.search(line) and RESULT.search(line) for line in body.splitlines())


class GateError(Exception):
    """A precondition of the measurement is unmet — always red, never zero."""


def split_rows(text: str) -> list[tuple[str, str]]:
    """Return [(heading, body)] — body runs to the next row heading or EOF."""
    marks = [(m.start(), m.end(), m.group(0).strip()) for m in ROW_HEADING.finditer(text)]
    rows = []
    for i, (_, end, heading) in enumerate(marks):
        stop = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        rows.append((heading, text[end:stop]))
    return rows


def measure(path: Path) -> list[tuple[str, bool]]:
    """[(heading, proven)] for one ledger. Raises GateError on a dead input."""
    if not path.is_file():
        raise GateError(f"{path}: ledger not found — the gate cannot measure a missing file")
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        raise GateError(f"{path}: ledger is empty")
    rows = split_rows(text)
    if not rows:
        raise GateError(
            f"{path}: no '### موج' / '### wave' rows found — either the ledger lost its "
            f"rows or the heading pattern drifted; both are red"
        )
    return [(heading, row_is_proven(body)) for heading, body in rows]


def load_backlog(path: Path) -> dict[str, str]:
    """{heading: reason} of rows accepted as closed without a quoted verifier."""
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("unproven_rows", {})
    if not isinstance(entries, dict):
        raise GateError(f"{path}: 'unproven_rows' must be an object of heading -> reason")
    return entries


def check(ledgers: list[Path], backlog_path: Path, out=sys.stdout) -> int:
    backlog = load_backlog(backlog_path)
    seen_unproven: set[str] = set()
    failures: list[str] = []

    for ledger in ledgers:
        try:
            rows = measure(ledger)
        except GateError as exc:
            failures.append(str(exc))
            print(f"FAIL {exc}", file=out)
            continue

        proven = sum(1 for _, ok in rows if ok)
        print(f"{ledger}: {len(rows)} row(s), {proven} quoting a command result", file=out)
        for heading, ok in rows:
            if ok:
                continue
            seen_unproven.add(heading)
            if heading in backlog:
                print(f"  known-unproven  {heading}  ({backlog[heading]})", file=out)
            else:
                failures.append(f"{ledger}: {heading} claims a wave closed without quoting the command that proved it")
                print(f"  NEW GAP         {heading}", file=out)

    # The other failure direction: a listed row that has since acquired a proof.
    # A backlog only ever seen growing proves nothing about the rows it excuses.
    for heading in sorted(set(backlog) - seen_unproven):
        failures.append(f"{backlog_path}: '{heading}' is listed as unproven but now quotes a result, or no longer exists — remove the stale entry")
        print(f"  STALE ENTRY     {heading}", file=out)

    print(f"unproven rows accepted by the backlog: {len(seen_unproven & set(backlog))}", file=out)
    if failures:
        for line in failures:
            print(f"::error::{line}", file=out)
        return 1
    print("ledger proof gate: every row carries its verifier output", file=out)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ledgers", nargs="*", default=None, help="ledger markdown files")
    parser.add_argument("--backlog", default=None, help="path to the backlog JSON")
    args = parser.parse_args(argv)

    names = args.ledgers or DEFAULT_LEDGERS
    ledgers = [Path(n) if Path(n).is_absolute() else REPO_ROOT / n for n in names]
    backlog = Path(args.backlog) if args.backlog else REPO_ROOT / DEFAULT_BACKLOG
    if args.backlog and not Path(args.backlog).is_absolute():
        backlog = REPO_ROOT / args.backlog
    try:
        return check(ledgers, backlog)
    except GateError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
