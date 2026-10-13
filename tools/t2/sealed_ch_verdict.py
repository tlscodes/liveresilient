#!/usr/bin/env python3
"""Phase چ verdict: was one text letter seen with the phone locked and the app
not opened, inside one window, with the receipt back on the Mac?

Reads a run directory written by sealed_ch_rig.sh:
  meta.json            {"letter_id", "tx_at" (UTC ISO, Mac tx), "window_end",
                        "give_utc_offset_s" (offset of give.log's local clock)}
  phone_journal.jsonl  the phone's sealed_events.jsonl, copied (never launched)
  mac_journal.jsonl    the Mac's sealed_events.jsonl
  give.log             txt_give.py log ("YYYY-mm-dd HH:MM:SS,mmm give GET ...")
  lock.tsv             "<UTC ISO>\t<lockState>" every 60 s

Exit codes (docs/ch-background-design.md):
  0 PASS · 10 iOS did not grant · 11 owner setting · 12 network · 13 code
  2 the run directory itself is unusable (no meta / no journals)
Times are reported raw; x = none when no bg_turn came. Never an estimate.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

PASS, NOT_GRANTED, SETTING, NETWORK, CODE, UNUSABLE = 0, 10, 11, 12, 13, 2
SLACK = timedelta(seconds=5)
GIVE_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3}) give (GET|PUT) ")


def when(text):
    if not text:
        return None
    t = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def rows(path):
    out = []
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and when(r.get("at")):
            r["_at"] = when(r["at"])
            out.append(r)
    return out


def give_hits(path, offset_s):
    hits = []
    if not path.exists():
        return hits
    tz = timezone(timedelta(seconds=offset_s))
    for line in path.read_text(errors="replace").splitlines():
        m = GIVE_RE.match(line)
        if m:
            t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=tz)
            hits.append((t + timedelta(milliseconds=int(m.group(2))), m.group(3)))
    return hits


def locks(path):
    out = []
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and when(parts[0]):
            out.append((when(parts[0]), parts[1].strip().lower()))
    return out


def first(rs, event, **match):
    for r in rs:
        if r.get("event") == event and all(r.get(k) == v for k, v in match.items()):
            return r
    return None


def judge(run):
    """Returns (rc, lines). Pure: reads only the run directory."""
    meta_p = run / "meta.json"
    if not meta_p.exists():
        return UNUSABLE, ["no meta.json"]
    meta = json.loads(meta_p.read_text())
    wake = meta.get("wake", "refresh")
    lid, tx_at = meta.get("letter_id"), when(meta.get("tx_at"))
    end = when(meta.get("window_end")) or (tx_at and tx_at + timedelta(hours=8))
    phone, mac = rows(run / "phone_journal.jsonl"), rows(run / "mac_journal.jsonl")
    if not lid or not tx_at or not phone:
        return UNUSABLE, [f"letter_id={lid} tx_at={tx_at} phone_rows={len(phone)}"]
    win = [r for r in phone if tx_at <= r["_at"] <= end]
    lines = [f"letter_id={lid}", f"tx_at={tx_at.isoformat()}", f"window_end={end.isoformat()}"]

    reg = None
    for r in phone:
        if r.get("event") == "bg_registered" and r["_at"] <= tx_at:
            reg = r
    sub = [r for r in phone if r.get("event") == "bg_submitted" and r["_at"] <= end]
    earliest = sub[-1].get("earliest") if sub else None
    lines.append(f"earliest_floor={earliest}")
    if reg is None:
        lines += ["x=none", "cause: no bg_registered before T — the flag build never registered"]
        return CODE, lines
    bad = []
    if wake == "push":
        # Silent push is gated by the token reaching APNs, not by background
        # refresh / notification authorization (it needs neither).
        if not first([r for r in phone if r["_at"] <= tx_at], "push_registered"):
            lines += ["x=none",
                      "cause: no push_registered before T — the device token never reached APNs"]
            return CODE, lines
    else:
        if reg.get("refresh_status") != "available":
            bad.append(f"refresh_status={reg.get('refresh_status')}")
        if reg.get("low_power") is not False:
            bad.append(f"low_power={reg.get('low_power')}")
        if reg.get("notif_auth") != "authorized":
            bad.append(f"notif_auth={reg.get('notif_auth')}")
    # lock2.tsv (ch_lock_probe.sh) reads passcodeRequired; lock.tsv matched "unlockedSinceBoot"
    lk = locks(run / "lock2.tsv") if (run / "lock2.tsv").exists() else locks(run / "lock.tsv")
    if lk and not any("lock" in s and "unlock" not in s for _, s in lk):
        bad.append("never locked in lock.tsv (passcode or auto-lock off)")
    if bad:
        lines += ["x=none" if not first(win, "bg_turn") else "x=see turn",
                  "cause: owner setting — " + ", ".join(bad)]
        return SETTING, lines

    opened = [r for r in win if r.get("event") == "rig_screen"
              or (r.get("event") == "warm" and r.get("why") == "screen")
              or r.get("app_state") == "foreground"]
    turns = [r for r in win if r.get("event") == "bg_turn" and not r.get("forced")]
    if wake == "push":
        turns = [t for t in turns if t.get("launch_reason") == "push"]
    if not turns:
        lines.append("x=none")
        if wake == "push":
            lines.append(
                "cause: iOS did not deliver the push — no bg_turn(launch_reason=push) in the window")
            return NOT_GRANTED, lines
        if not sub:
            lines.append("cause: code — no bg_submitted, nothing asked iOS for a wake")
            return CODE, lines
        lines.append(f"cause: iOS did not grant — bg_submitted x{len(sub)}, no bg_turn in the window, settings ok")
        return NOT_GRANTED, lines

    gives = give_hits(run / "give.log", int(meta.get("give_utc_offset_s", 0)))
    last_cause = None
    for t in turns:
        b, e = when(t.get("begin")), when(t.get("end"))
        if not b or not e:
            last_cause = (CODE, "bg_turn without begin/end")
            continue
        lines.append(f"bg_turn begin={b.isoformat()} end={e.isoformat()} "
                     f"x={(b - tx_at).total_seconds():.0f}s lane={t.get('lane')} "
                     f"protected_data={t.get('protected_data')} expired={t.get('expired')} "
                     f"launch_reason={t.get('launch_reason')}")
        inside = [r for r in win if b - SLACK <= r["_at"] <= e + SLACK]
        rx = first(inside, "rx", id=lid)
        rtx = first(inside, "receipt_tx", id=lid)
        note = first(inside, "notify_local", letter_id=lid)
        if not [g for g in gives if b - SLACK <= g[0] <= e + SLACK and g[1] == "GET"]:
            last_cause = (NETWORK, "no give GET inside the turn — phone off the bridge or TXT path down")
            continue
        if t.get("expired"):
            last_cause = (CODE, "bg_turn expired before finishing")
            continue
        missing = [n for n, r in (("rx", rx), ("receipt_tx", rtx), ("notify_local", note)) if r is None]
        if missing:
            last_cause = (CODE, "bg_turn without " + " / ".join(missing))
            continue
        order = [tx_at, b, rx["_at"], rtx["_at"], note["_at"], e]
        if any(order[i] > order[i + 1] + SLACK for i in range(len(order) - 1)):
            last_cause = (CODE, "chain out of order: " + " ".join(o.isoformat() for o in order))
            continue
        if rtx.get("deposited") is not True:
            last_cause = (NETWORK, "receipt_tx deposited=false")
            continue
        if note.get("auth") != "authorized" or note.get("add_err") not in (None, ""):
            last_cause = (CODE, f"notify_local auth={note.get('auth')} add_err={note.get('add_err')}")
            continue
        if t.get("protected_data") is not False:
            last_cause = (SETTING, f"protected_data={t.get('protected_data')} — phone was not locked")
            continue
        if t.get("lane") != "txt":
            last_cause = (CODE, f"lane={t.get('lane')} — HTTPS arrival never counts")
            continue
        if opened:
            last_cause = (CODE, f"app opened in the window: {opened[0].get('event')} at {opened[0]['at']}")
            continue
        if not first([r for r in mac if r["_at"] >= tx_at], "receipt_rx", id=lid):
            last_cause = (NETWORK, "no Mac receipt_rx for the letter")
            continue
        around = [s for at, s in lk if abs((at - b).total_seconds()) <= 90]
        if lk and not (around and all("lock" in s and "unlock" not in s for s in around)):
            last_cause = (SETTING, f"lock.tsv around bg_turn.begin: {around}")
            continue
        lines += [f"rx={rx['at']}", f"receipt_tx={rtx['at']}", f"notify_local={note['at']}",
                  "VERDICT ch PASS"]
        return PASS, lines
    rc, why = last_cause or (CODE, "no usable bg_turn")
    lines.append("cause: " + why)
    return rc, lines


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    a = ap.parse_args(argv)
    rc, lines = judge(Path(a.run))
    print("\n".join(lines))
    print(f"rc={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
