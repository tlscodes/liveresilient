#!/usr/bin/env python3
"""Verdict of the TXT-lane smoke (tools/t2/sealed_txt_hour_rig.sh <out> smoke).

The Mac writes one text to the rig peer, unfiltered; then the phone, cut off
from everything but this Mac, opens it over the give lane and answers with
its echo (`rig-echo=1 opened_ms=<ms>`). The Mac then reads that echo.

PASS needs, counted only from the phone's journal lines after the run began:
  - the lane carried at least one GET and one PUT (event relay_request via=txt,
    2xx status);
  - mac -> phone: the phone opened the Mac's text with the same byte count;
  - phone -> mac: the sha the Mac printed for the echo equals the sha of the
    echo text rebuilt from the phone's own open time (within +-20 ms, the
    journal stamps the open a moment after the letter's receivedAt).

Usage: sealed_txt_smoke_verdict.py <out> <run start ISO-8601>
"""
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path


def when(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s and s != "-" else None


def fields(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


def main():
    out, start = Path(sys.argv[1]), when(sys.argv[2])
    phone = []
    for f in sorted(out.glob("phone_events_*.jsonl")):
        for l in f.read_text(errors="replace").splitlines():
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if when(r.get("at")) and when(r["at"]) >= start:
                phone.append(r)
    uniq = {json.dumps(r, sort_keys=True): r for r in phone}.values()
    lane = [r for r in uniq if r.get("event") == "relay_request" and r.get("via") == "txt"]
    ok = lambda r: 200 <= int(r.get("status", 0)) < 300
    puts = [r for r in lane if r.get("method") == "PUT"]
    gets = [r for r in lane if r.get("method") == "GET"]
    print(f"lane since {sys.argv[2]}: PUT {len(puts)} ({sum(map(ok, puts))} 2xx), "
          f"GET {len(gets)} ({sum(map(ok, gets))} 2xx)")

    wlines = (out / "mac_write.log").read_text(errors="replace").splitlines() \
        if (out / "mac_write.log").exists() else []
    wrote = next((fields(l) for l in wlines if "SEALED_RIG fixture kind=text" in l), {})
    written = next((fields(l) for l in wlines if "SEALED_RIG written" in l and "kind=text" in l), {})
    rx = next((r for r in uniq if r.get("event") == "rx" and r.get("kind") == "text"
               and r.get("from") == written.get("from")), None)
    m2p = bool(wrote and rx and str(rx.get("bytes")) == wrote.get("bytes"))
    print(f"mac -> phone text: mac bytes={wrote.get('bytes', '-')} sha={wrote.get('sha', '-')} "
          f"on_relay={written.get('on_relay', '-')}; phone opened="
          f"{rx.get('opened_at') if rx else '-'} bytes={rx.get('bytes') if rx else '-'} -> "
          f"{'MATCH' if m2p else 'NO'}")

    rlines = (out / "mac_receive.log").read_text(errors="replace").splitlines() \
        if (out / "mac_receive.log").exists() else []
    echo_row = next((fields(l) for l in rlines
                     if "SEALED_RIG row dir=phone_to_mac kind=text" in l), {})
    p2m = False
    rebuilt = "-"
    if echo_row and rx:
        base = int(when(rx["opened_at"]).timestamp() * 1000)
        for d in range(-20, 21):
            text = f"rig-echo=1 opened_ms={base + d}".encode()
            if hashlib.sha256(text).hexdigest()[:8] == echo_row.get("sha"):
                p2m, rebuilt = True, f"{base + d} (journal {d:+d} ms)"
                break
    print(f"phone -> mac echo: mac opened={echo_row.get('opened_at', '-')} bytes="
          f"{echo_row.get('bytes', '-')} sha={echo_row.get('sha', '-')}; rebuilt from phone "
          f"opened_ms={rebuilt} -> {'MATCH' if p2m else 'NO'}")

    passed = sum(map(ok, puts)) > 0 and sum(map(ok, gets)) > 0 and m2p and p2m
    print(f"SMOKE {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
