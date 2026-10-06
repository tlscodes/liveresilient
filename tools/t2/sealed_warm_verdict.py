#!/usr/bin/env python3
"""Reads the Mac half of the warm run (tools/t2/sealed_warm_rig.sh) and says
whether the line was seen: ten texts each way while the conversation is
warm, with the median time from "written" to "opened on the other side" at
most five seconds in each direction.

Each round trip gives four instants, two on each device's own clock:

  mac_sent -> phone_open     raw1 = d1 + T     (T = phone clock - Mac clock)
  phone_sent -> mac_open     raw2 = d2 - T

The two clocks are NOT assumed to agree. No letter is opened before it is
written, so d1 >= 0 and d2 >= 0 for every round trip, which bounds T from
the data alone:   -min(raw2) <= T <= min(raw1).   Therefore

  median(d1) <= median(raw1) + min(raw2)
  median(d2) <= median(raw2) + min(raw1)

and those two upper bounds are what is held against the line. The medians
"if the clocks agreed" and with T taken at the middle of its range are
printed beside them, as what they are.

  sealed_warm_verdict.py <output dir> [texts each way, default 10] [line ms, default 5000]

The last line is `VERDICT warm PASS ...` or `VERDICT warm FAIL ...`.
"""
import re
import statistics
import sys
from pathlib import Path


def main():
    out = Path(sys.argv[1])
    want = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    line_ms = int(sys.argv[3]) if len(sys.argv) > 3 else 5000
    log = out / "mac_warm.log"
    text = log.read_text(errors="replace") if log.exists() else ""
    pairs = []
    for row in text.splitlines():
        if "SEALED_WARM pair " not in row:
            continue
        f = dict(re.findall(r"(\w+)=(\S+)", row))
        if f.get("counted") != "true":
            continue
        try:
            pairs.append((int(f["i"]), int(f["mac_sent_ms"]), int(f["phone_open_ms"]),
                          int(f["phone_sent_ms"]), int(f["mac_open_ms"])))
        except (KeyError, ValueError):
            continue
    for row in text.splitlines():
        if "SEALED_WARM " in row and " pair " not in row:
            print(row[row.index("SEALED_WARM"):])
    if len(pairs) < want:
        print(f"VERDICT warm FAIL pairs={len(pairs)}/{want} (not every text came back)")
        return 1

    raw1 = [p[2] - p[1] for p in pairs]
    raw2 = [p[4] - p[3] for p in pairs]
    print("  i   mac->phone raw ms   phone->mac raw ms   round trip ms")
    for p, a, b in zip(pairs, raw1, raw2):
        print(f"{p[0]:>3}   {a:>16}   {b:>17}   {p[4] - p[1]:>13}")
    med1, med2 = statistics.median(raw1), statistics.median(raw2)
    lo, hi = -min(raw2), min(raw1)  # the range the clock difference can be in
    bound1 = med1 + min(raw2)
    bound2 = med2 + min(raw1)
    mid = (lo + hi) / 2
    print(f"clock difference (phone - Mac), from the data alone: between {lo} and {hi} ms")
    print(f"median written->opened, Mac->phone : at most {bound1:.0f} ms "
          f"(raw {med1:.0f}; {med1 - mid:.0f} with the difference at mid-range)")
    print(f"median written->opened, phone->Mac : at most {bound2:.0f} ms "
          f"(raw {med2:.0f}; {med2 + mid:.0f} with the difference at mid-range)")
    ok = bound1 <= line_ms and bound2 <= line_ms
    print(f"VERDICT warm {'PASS' if ok else 'FAIL'} pairs={len(pairs)}/{want} "
          f"mac_to_phone_median_ms<={bound1:.0f} phone_to_mac_median_ms<={bound2:.0f} line_ms={line_ms}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
