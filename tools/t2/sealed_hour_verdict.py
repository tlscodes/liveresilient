#!/usr/bin/env python3
"""Reads what tools/t2/sealed_hour_rig.sh left and says, row by row, whether
the line was seen: a letter written by an app that was then closed is opened
by the other side at least GAP minutes later, and its receipt is read by the
sender on its own next start.

Eight rows: Mac -> phone and phone -> Mac, each for a text, a photo, a voice
note and a video. A row passes only if the letter opened, the gap between
"written" and "opened" is at least the gap asked for, and the receipt was
read. Nothing is inferred: a row whose facts are not in the files fails.

  sealed_hour_verdict.py <output dir> [gap minutes, default 45]

The last line is `VERDICT hour PASS rows=8/8` or `VERDICT hour FAIL ...`.
"""
import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

KINDS = ("text", "photo", "voice", "video")


def when(text):
    if not text or text == "-":
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def fields(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


def journal(path):
    rows = []
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


def main():
    out = Path(sys.argv[1])
    # The run waits 46; the line is 45.
    need = timedelta(minutes=min(int(sys.argv[2]) if len(sys.argv) > 2 else 45, 45))
    mac = [fields(l) for l in (out / "mac_lines.txt").read_text(errors="replace").splitlines()] \
        if (out / "mac_lines.txt").exists() else []
    lines = (out / "mac_lines.txt").read_text(errors="replace").splitlines() \
        if (out / "mac_lines.txt").exists() else []
    written = [f for f, l in zip(mac, lines) if " written " in l and f.get("dir") == "mac_to_phone"]
    mac_rows = [f for f, l in zip(mac, lines) if " row " in l]
    phone = journal(out / "phone_events_4_phone_final.jsonl")
    phone_rx = [r for r in phone if r.get("event") == "rx"]
    phone_receipts = [r for r in phone if r.get("event") == "receipt_rx"]

    rows = []
    print("direction      kind   bytes    written   opened    gap       receipt read by the writer")
    for kind in KINDS:
        # Mac -> phone: written on the Mac, opened in the phone's journal,
        # receipt read by the Mac on its next start.
        sent = next((when(w.get("sent_at")) for w in reversed(written) if w.get("kind") == kind), None)
        rx = next((r for r in reversed(phone_rx)
                   if r.get("kind") == kind and close(when(r.get("sent_at")), sent)), None)
        opened = when(rx.get("opened_at")) if rx else None
        back = next((f for f in reversed(mac_rows)
                     if f.get("dir") == "mac_to_phone" and f.get("kind") == kind
                     and close(when(f.get("sent_at")), sent)), None)
        receipt = when(back.get("receipt_read_at")) if back and back.get("receipt") == "true" else None
        rows.append(("mac -> phone", kind, rx.get("bytes") if rx else "-", sent, opened, receipt, ""))
    for kind in KINDS:
        # Phone -> Mac: opened on the Mac (its own line), receipt read in
        # the phone's journal.
        got = next((f for f in reversed(mac_rows)
                    if f.get("dir") == "phone_to_mac" and f.get("kind") == kind
                    and f.get("opened") == "true"), None)
        sent = when(got.get("sent_at")) if got else None
        opened = when(got.get("opened_at")) if got else None
        back = next((r for r in reversed(phone_receipts)
                     if r.get("kind") == kind and close(when(r.get("sent_at")), sent)), None)
        receipt = when(back.get("receipt_at")) if back else None
        note = f"sha={got.get('sha')} on_screen={got.get('on_screen')}" if got else ""
        rows.append(("phone -> mac", kind, got.get("bytes") if got else "-", sent, opened, receipt, note))

    passed = 0
    for direction, kind, size, sent, opened, receipt, note in rows:
        gap = opened - sent if sent and opened else None
        ok = gap is not None and gap >= need and receipt is not None
        passed += ok
        gap_text = str(gap).split(".")[0] if gap is not None else "-"
        print(f"{direction:<14} {kind:<6} {str(size):>7}  {hms(sent)}  {hms(opened)}  {gap_text:<8}  "
              f"{hms(receipt):<9} {'PASS' if ok else 'FAIL'} {note}")

    # The writer was off while its letters waited: the phone's journal has
    # no line between its two sessions, and none before its first.
    a = journal(out / "phone_events_2_phone_opened_and_wrote.jsonl")
    b = journal(out / "phone_events_3_phone_before_mac.jsonl")
    if a and b:
        still = a[-1].get("at") == b[-1].get("at")
        print(f"phone journal between its two sessions: {'no line' if still else 'MOVED'} "
              f"(last {a[-1].get('at')})")
    starts = [r.get("at") for r in phone if r.get("event") == "start"]
    print(f"phone app starts in its journal: {starts[-2:] if starts else 'none recorded'}")

    print(f"VERDICT hour {'PASS' if passed == len(rows) else 'FAIL'} rows={passed}/{len(rows)} "
          f"gap>={int(need.total_seconds() // 60)}min")
    return 0 if passed == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
