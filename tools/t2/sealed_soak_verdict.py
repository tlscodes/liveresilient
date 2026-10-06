#!/usr/bin/env python3
"""Reads the two journals tools/t2/sealed_soak_rig.sh copied and says whether
the idle line was seen on each device.

Everything comes from the app's own journal lines, written by the letter
service while it ran:

  start   once, when the service starts: its process id, how many peers are
          pinned, today's request count so far and the cap
  alive   every thirty seconds: seconds up, requests since start, the
          longest any request has been open, looks made

The line, for each device, over H hours from its `start` line:

  on       an `alive` line at least every 45 seconds for the whole H hours
           (that, and not a process list, is what "the app was open" means)
  idle     nobody wrote and nothing arrived: no `warm`, `tx` or `rx` line
  one peer the `start` line says peers=1
  requests the count on the first `alive` line at or after H hours is at
           most LINE (default 133: a third of 400 a day, for 8 of 24 hours)
  open     the longest any request was open, on that same line, is at most
           2000 ms

  sealed_soak_verdict.py <output dir> [--progress] [hours=8] [line=133]

The last line is `VERDICT soak PASS ...` or `VERDICT soak FAIL ...`; with
--progress one line per device says where the count is now, and nothing is
judged.
"""
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

BEAT_MAX_S = 45
OPEN_MAX_MS = 2000


def when(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def journal(path):
    rows = []
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            row["_at"] = when(row.get("at"))
            if row["_at"] is not None:
                rows.append(row)
    return rows


def side(name, rows, since, hours, line, progress):
    """Returns (passed, summary text)."""
    starts = [r for r in rows if r.get("event") == "start" and r["_at"] >= since]
    if not starts:
        return False, f"{name}: no start line since {since.isoformat()} — not seen"
    start = starts[0]
    pid, began = start.get("pid"), start["_at"]
    later = [r for r in rows if r["_at"] >= began]
    restarts = len(starts) - 1
    beats = [r for r in later if r.get("event") == "alive" and r.get("pid") == pid]
    if not beats:
        return False, f"{name}: started {began.isoformat()} pid {pid}, no alive line yet"
    end = began + timedelta(hours=hours)
    last = beats[-1]
    if progress:
        gaps = [(b["_at"] - a["_at"]).total_seconds() for a, b in zip([start] + beats, beats)]
        return True, (f"{name}: up {last.get('up_s')} s, {last.get('req_start')} requests since start "
                      f"({last.get('looks_fast')} fast looks, {last.get('looks_slow')} slow), "
                      f"longest open {last.get('longest_ms')} ms, every {last.get('every_s')} s, "
                      f"{len(beats)} beats, widest gap {max(gaps):.0f} s, relay {last.get('relay')}")

    # On: a beat at least every BEAT_MAX_S from the start line to H hours.
    inside = [b for b in beats if b["_at"] <= end + timedelta(seconds=BEAT_MAX_S)]
    marks = [began] + [b["_at"] for b in inside]
    gaps = [(b - a).total_seconds() for a, b in zip(marks, marks[1:])]
    widest = max(gaps) if gaps else float("inf")
    covered = bool(inside) and inside[-1]["_at"] >= end - timedelta(seconds=BEAT_MAX_S)
    on = covered and widest <= BEAT_MAX_S

    at_end = next((b for b in beats if (b.get("up_s") or 0) >= hours * 3600), None)
    requests = at_end.get("req_start") if at_end else None
    longest = at_end.get("longest_ms") if at_end else None
    window = [r for r in later if r["_at"] <= end]
    busy = [r.get("event") for r in window if r.get("event") in ("warm", "tx", "rx", "receipt_tx", "receipt_rx")]
    slow = [r for r in window if r.get("event") == "slow_request"]
    peers = start.get("peers")

    ok = (on and not busy and peers == 1 and restarts == 0
          and requests is not None and requests <= line
          and longest is not None and longest <= OPEN_MAX_MS)
    lines = [
        f"{name}: pid {pid}, started {began.isoformat()}, peers pinned {peers}, "
        f"requests already used that day at start {start.get('req_day')} of {start.get('cap')}",
        f"{name}: on for {hours} h: {'yes' if on else 'NO'} — {len(inside)} alive lines, "
        f"widest gap {widest:.0f} s (limit {BEAT_MAX_S}), restarts {restarts}",
        f"{name}: idle: {'yes' if not busy else 'NO ' + str(sorted(set(busy)))} — "
        f"requests cut or slower than 1 s: {len(slow)}",
    ]
    if at_end is None:
        lines.append(f"{name}: no alive line at or after {hours} h — the count for {hours} h was NOT seen "
                     f"(last: up {last.get('up_s')} s, {last.get('req_start')} requests)")
    else:
        lines.append(
            f"{name}: requests in {hours} h: {requests} (line {line}) -> x{24 // hours if 24 % hours == 0 else 24 / hours} "
            f"= {requests * 24 / hours:.0f} a day; looks {at_end.get('looks_fast')} fast, "
            f"{at_end.get('looks_slow')} slow; longest open {longest} ms (limit {OPEN_MAX_MS}); "
            f"read at up {at_end.get('up_s')} s")
    lines.append(f"{name}: {'PASS' if ok else 'FAIL'}")
    return ok, "\n".join(lines)


def main():
    args = [a for a in sys.argv[1:] if a != "--progress"]
    progress = "--progress" in sys.argv[1:]
    out = Path(args[0])
    hours = int(args[1]) if len(args) > 1 else 8
    line = int(args[2]) if len(args) > 2 else 133
    meta = (out / "soak_since.txt").read_text().strip() if (out / "soak_since.txt").exists() else ""
    since = when(meta + "+00:00") if meta else None
    if since is None:
        print("VERDICT soak FAIL no soak_since.txt — the run's beginning is not known")
        return 1
    results = []
    for name, file in (("mac", "mac_events_soak.jsonl"), ("phone", "phone_events_soak.jsonl")):
        ok, text = side(name, journal(out / file), since, hours, line, progress)
        print(text)
        results.append(ok)
    if progress:
        return 0
    print(f"VERDICT soak {'PASS' if all(results) else 'FAIL'} hours={hours} line={line} "
          f"mac={'ok' if results[0] else 'no'} phone={'ok' if results[1] else 'no'}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
