#!/usr/bin/env python3
"""Reads what tools/t2/sealed_hour_rig.sh left and says, row by row, whether
the line was seen: a letter written by an app that was then closed is opened
by the other side at least GAP minutes later, its receipt is read by the
sender on its own next start, and the receiver's panel drew THAT letter.

Eight rows: Mac -> phone and phone -> Mac, each for a text, a photo, a voice
note and a video. A row passes only if the letter opened, the gap between
"written" and "opened" is at least the gap asked for, the receipt was read,
and the receiver's own screen reader journaled the letter. Nothing is
inferred: a row whose facts are not in the files fails.

"On screen" is matched by identity, never by kind and time alone: the
receiver's `rx` event with the row's kind and sent_at names the letter's id,
and a `rig_screen dir=in` line for that id must show the body — for a text,
the exact bytes whose sha the row recorded; for media, its kind's summary.
The device's own finder value (only rows in the viewport at that instant,
2026-10-10 full4) is echoed as `in_view=` and does not decide the row.

The sender's own panel is matched the same way (`sent_seen`): its `tx` event
names the id and its `rig_screen dir=out` line must show the body. It goes
to --json as `out_seen`; .autorun/verify_p.py gates on it, this table does not.

Joins use the letter id when both records name one: lines printed since
2026-10-10 carry `id=` on written and row lines, journal events always do.
Older lines (full1..full4) fall back to the rule they were judged by — same
kind, sent_at within 5 ms — and re-derive byte for byte.

  sealed_hour_verdict.py <output dir> [gap minutes, default 45] [--json PATH]

--json writes the same eight rows as JSON (schema 1); stdout is unchanged.
The last line is `VERDICT hour PASS rows=8/8` or `VERDICT hour FAIL ...`.
"""
# The rig calls bare `python3`; /usr/bin/python3 on this Mac is 3.9, where a
# `datetime | None` field annotation fails at import unless it stays a string.
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

KINDS = ("text", "photo", "voice", "video")
# The run waits 46; the line is 45.
LINE_MIN = 45


def when(text):
    if not text or text == "-":
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def journal(*paths):
    rows = []
    for path in paths:
        if path.exists():
            for line in path.read_text(errors="replace").splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    return rows


def close(a, b):
    return a is not None and b is not None and abs((a - b).total_seconds()) < 0.005


def hms(at):
    return at.strftime("%H:%M:%S") if at else "-"


def iso(at):
    return at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if at else None


def sha8(text):
    return hashlib.sha256(text.encode()).hexdigest()[:8]


@dataclass(frozen=True)
class RigLine:
    """One `SEALED_RIG <tag> key=value ...` line; a value ends at the first space."""
    tag: str
    fields: dict = field(default_factory=dict)

    @classmethod
    def parse(cls, line):
        m = re.search(r"SEALED_RIG (\w+)", line)
        return cls(m.group(1) if m else "", dict(re.findall(r"(\w+)=(\S+)", line)))

    def get(self, key):
        return self.fields.get(key)


def drawn(rows, kind, sent, sha=None, letter_id=None, *, direction):
    """The id of the letter a panel drew, or None. direction "in": the
    receiver (rx + rig_screen dir=in); "out": the sender (tx + rig_screen
    dir=out)."""
    event = "rx" if direction == "in" else "tx"
    ids = {r.get("id") for r in rows
           if r.get("event") == event and r.get("kind") == kind and close(when(r.get("sent_at")), sent)}
    ids.discard(None)
    if letter_id:
        ids &= {letter_id}
    for r in rows:
        if r.get("event") != "rig_screen" or r.get("dir") != direction or r.get("id") not in ids:
            continue
        shown = r.get("screen_text", "")
        if kind == "text" and sha and sha8(shown) == sha:
            return r.get("id")
        # Media: the panel's summary "<kind> · <size>...", never the photo
        # errorBuilder's "photo received — this device cannot draw its format".
        if kind != "text" and shown.startswith(f"{kind} · "):
            return r.get("id")
    return None


def screen_seen(rows, kind, sent, sha=None, letter_id=None):
    """The receiver's panel drew this letter: the id comes from its `rx` event
    (kind + sent_at within 5 ms, or the id the row already names), and a
    `rig_screen dir=in` line for that id shows the body. A text needs [sha]
    and matches only the exact bytes; media match their kind's summary."""
    return drawn(rows, kind, sent, sha, letter_id, direction="in") is not None


def sent_seen(rows, kind, sent, sha=None, letter_id=None):
    """The sender's own panel drew this letter in its sent list: the id from
    its `tx` event (kind + sent_at within 5 ms, narrowed to [letter_id]), and
    a `rig_screen dir=out` line for that id shows the body."""
    return drawn(rows, kind, sent, sha, letter_id, direction="out") is not None


def joined(rec_id, rec_kind, rec_sent, kind, sent, letter_id):
    """By the letter id when both sides name one; else as before 2026-10-10:
    same kind, sent_at within 5 ms."""
    if letter_id and rec_id:
        return rec_id == letter_id
    return rec_kind == kind and close(when(rec_sent), sent)


@dataclass(frozen=True)
class Row:
    direction: str
    kind: str
    size: str
    sent: datetime | None
    opened: datetime | None
    receipt: datetime | None
    seen: bool
    out_seen: bool
    letter_id: str | None
    id_from: str | None
    sha: str | None
    in_view: str | None
    note: str

    @property
    def gap(self):
        return self.opened - self.sent if self.sent and self.opened else None

    def ok(self, need):
        return self.gap is not None and self.gap >= need and self.receipt is not None and self.seen

    def table_line(self, need):
        gap_text = str(self.gap).split(".")[0] if self.gap is not None else "-"
        return (f"{self.direction:<14} {self.kind:<6} {self.size:>7}  {hms(self.sent)}  {hms(self.opened)}  "
                f"{gap_text:<8}  {hms(self.receipt):<9} {'PASS' if self.ok(need) else 'FAIL'} {self.note}")

    def as_json(self, need):
        return {"direction": self.direction, "kind": self.kind, "id": self.letter_id, "id_from": self.id_from,
                "bytes": int(self.size) if self.size.isdigit() else None,
                "written": iso(self.sent), "opened": iso(self.opened),
                "gap_s": self.gap.total_seconds() if self.gap is not None else None,
                "receipt": iso(self.receipt), "on_screen": self.seen, "out_seen": self.out_seen,
                "sha": self.sha, "in_view": {"true": True, "false": False}.get(self.in_view),
                "pass": self.ok(need)}


@dataclass(frozen=True)
class Inputs:
    fixtures: dict
    written: list
    mac_rows: list
    mac_journal: list
    phone: list
    phone_all: list

    @classmethod
    def load(cls, out):
        path = out / "mac_lines.txt"
        lines = [RigLine.parse(l) for l in path.read_text(errors="replace").splitlines()] if path.exists() else []
        return cls(fixtures={l.get("kind"): l.get("sha") for l in lines if l.tag == "fixture"},
                   written=[l for l in lines if l.tag == "written" and l.get("dir") == "mac_to_phone"],
                   mac_rows=[l for l in lines if l.tag == "row"],
                   mac_journal=journal(out / "mac_journal.jsonl"),
                   phone=journal(out / "phone_events_4_phone_final.jsonl"),
                   phone_all=journal(*sorted(out.glob("phone_events_[24]_*.jsonl"))))


def mac_to_phone(inp, kind):
    # Written on the Mac, opened in the phone's journal, receipt read by the
    # Mac on its next start, drawn by the phone.
    w = next((f for f in reversed(inp.written) if f.get("kind") == kind), None)
    sent = when(w.get("sent_at")) if w else None
    wid = w.get("id") if w else None
    rx = next((r for r in reversed(inp.phone) if r.get("event") == "rx"
               and joined(r.get("id"), r.get("kind"), r.get("sent_at"), kind, sent, wid)), None)
    back = next((f for f in reversed(inp.mac_rows) if f.get("dir") == "mac_to_phone"
                 and joined(f.get("id"), f.get("kind"), f.get("sent_at"), kind, sent, wid)), None)
    receipt = when(back.get("receipt_read_at")) if back and back.get("receipt") == "true" else None
    letter_id = wid or (rx.get("id") if rx else None)
    sha = inp.fixtures.get(kind)
    seen = screen_seen(inp.phone_all, kind, sent, sha, letter_id)
    return Row(direction="mac -> phone", kind=kind, size=str(rx.get("bytes")) if rx else "-", sent=sent,
               opened=when(rx.get("opened_at")) if rx else None, receipt=receipt, seen=seen,
               out_seen=sent_seen(inp.mac_journal, kind, sent, sha, letter_id), letter_id=letter_id,
               id_from="line" if wid else ("journal" if letter_id else None), sha=sha, in_view=None,
               note=f"on_screen={str(seen).lower()}")


def phone_to_mac(inp, kind):
    # Opened on the Mac (its own line), receipt read in the phone's journal,
    # drawn by the Mac.
    got = next((f for f in reversed(inp.mac_rows) if f.get("dir") == "phone_to_mac"
                and f.get("kind") == kind and f.get("opened") == "true"), None)
    g = got.get if got else (lambda key: None)
    sent, gid, sha = when(g("sent_at")), g("id"), g("sha")
    back = next((r for r in reversed(inp.phone) if r.get("event") == "receipt_rx"
                 and joined(r.get("id"), r.get("kind"), r.get("sent_at"), kind, sent, gid)), None)
    receipt = when(back.get("receipt_at")) if back else None
    found = drawn(inp.mac_journal, kind, sent, sha, gid, direction="in")
    seen = found is not None
    # The device's finder before 2026-10-10 printed in-viewport as on_screen.
    in_view = (g("in_view") or g("on_screen")) if got else None
    note = f"sha={sha} on_screen={str(seen).lower()} in_view={in_view}" if got else ""
    letter_id = gid or found
    return Row(direction="phone -> mac", kind=kind, size=str(g("bytes")) if got else "-", sent=sent,
               opened=when(g("opened_at")), receipt=receipt, seen=seen,
               out_seen=sent_seen(inp.phone_all, kind, sent, sha, letter_id), letter_id=letter_id,
               id_from="line" if gid else ("journal" if found else None), sha=sha, in_view=in_view,
               note=note)


def phone_gap(out):
    # The writer was off while its letters waited: the phone's journal has no
    # line between its two sessions.
    a = journal(out / "phone_events_2_phone_opened_and_wrote.jsonl")
    b = journal(out / "phone_events_3_phone_before_mac.jsonl")
    if not (a and b):
        return None, None
    return ("no line" if a[-1].get("at") == b[-1].get("at") else "MOVED"), a[-1].get("at")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out", type=Path)
    ap.add_argument("gap", type=int, nargs="?", default=LINE_MIN)
    ap.add_argument("--json", type=Path, metavar="PATH")
    args = ap.parse_args(argv)
    need = timedelta(minutes=min(args.gap, LINE_MIN))
    inp = Inputs.load(args.out)
    rows = [mac_to_phone(inp, k) for k in KINDS] + [phone_to_mac(inp, k) for k in KINDS]
    passed = sum(r.ok(need) for r in rows)
    verdict = "PASS" if passed == len(rows) else "FAIL"
    still, last = phone_gap(args.out)
    starts = [r.get("at") for r in inp.phone if r.get("event") == "start"]
    print("direction      kind   bytes    written   opened    gap       receipt read by the writer")
    for row in rows:
        print(row.table_line(need))
    if still:
        print(f"phone journal between its two sessions: {still} (last {last})")
    print(f"phone app starts in its journal: {starts[-2:] if starts else 'none recorded'}")
    print(f"VERDICT hour {verdict} rows={passed}/{len(rows)} gap>={int(need.total_seconds() // 60)}min")
    if args.json:  # after VERDICT: stdout is the rig's verdict.txt and VERDICT stays its last line
        args.json.write_text(json.dumps({
            "schema": 1, "run": args.out.name, "gap_min": int(need.total_seconds() // 60),
            "verdict": verdict, "passed": passed, "rows_total": len(rows),
            "rows": [r.as_json(need) for r in rows],
            "phone_journal_between_sessions": still, "phone_journal_last": last,
            "phone_starts": starts[-2:]}, indent=2) + "\n")
    return 0 if passed == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
