#!/usr/bin/env python3
"""Unit test for the accounting script embedded in journey_blackout.sh.

Extracts ACCT_PY between the `# acct-begin` / `# acct-end` markers, runs it
the way the runner does (`python3 -c "$ACCT_PY" <events file> <mode> ...`) on
a fixture events file in a temp dir, and checks every mode:
window / final / delivered / armed (the existing v2 semantics), stats (absent
file -> 0, fixture -> the number), util and ceiling (the formulas of the
adopted design, section A.4-5). Prints PASS/FAIL per case; exit 0 only on
0 failures. Run from the repo root:
    python3 tools/t2/test_journey_blackout_acct.py
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNNER = Path(os.environ.get("JOURNEY_BLACKOUT_RUNNER", HERE / "journey_blackout.sh"))


def extract_acct_py(text: str) -> str:
    lines = text.splitlines()
    begin = lines.index("# acct-begin")
    end = lines.index("# acct-end")
    body = lines[begin + 1:end]
    assert body[0].startswith("ACCT_PY='"), body[0]
    assert body[-1] == "'", body[-1]
    body[0] = body[0][len("ACCT_PY='"):]
    return "\n".join(body[:-1]) + "\n"


EVENTS = [
    {"event": "boot", "blackout": True},
    {"event": "blackout_armed", "v": 3, "bundles": 3, "bytes_total": 1400, "created_ms": 1000},
    {"event": "bundle_received", "id": "a", "bytes": 200, "received_ms": 5000,
     "sig_ok": True, "pubkey_match": True},
    {"event": "bundle_received", "id": "b", "bytes": 500, "received_ms": 6000,
     "sig_ok": True, "pubkey_match": True},
    # a repeat of b (idempotent redelivery): counted once in final/delivered
    {"event": "bundle_received", "id": "b", "bytes": 500, "received_ms": 6500,
     "sig_ok": True, "pubkey_match": True},
    {"event": "bundle_received", "id": "c", "bytes": 700, "received_ms": 9000,
     "sig_ok": True, "pubkey_match": True},
]


def main() -> int:
    acct_py = extract_acct_py(RUNNER.read_text())
    failures = 0

    def run(events_path: Path, *args: str) -> str:
        out = subprocess.run([sys.executable, "-c", acct_py, str(events_path), *args],
                             capture_output=True, text=True)
        if out.returncode != 0:
            return "ERR " + out.stderr.strip()
        return out.stdout.strip()

    def case(name: str, got: str, want: str) -> None:
        nonlocal failures
        ok = got == want
        failures += 0 if ok else 1
        print("%s %s: got %r want %r" % ("PASS" if ok else "FAIL", name, got, want))

    def case_close(name: str, got: str, want: float, tol: float) -> None:
        nonlocal failures
        try:
            ok = abs(float(got) - want) <= tol
        except ValueError:
            ok = False
        failures += 0 if ok else 1
        print("%s %s: got %r want %s ±%s" % ("PASS" if ok else "FAIL", name, got, want, tol))

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        ev = d / "phone_events.jsonl"
        ev.write_text("".join(json.dumps(e) + "\n" for e in EVENTS))

        case("armed", run(ev, "armed"), "3 3 1400 1000")
        case("delivered (distinct ids)", run(ev, "delivered"), "3")
        case("window 4000..6200 (a and first b)", run(ev, "window", "4000", "6200"), "2 700")
        case("window 8000..9999 (c)", run(ev, "window", "8000", "9999"), "1 700")
        case("window empty range", run(ev, "window", "0", "10"), "0 0")
        case("final (first-seen per id, all sig ok)", run(ev, "final"), "3 1400 true 9000")

        bad = d / "bad_events.jsonl"
        bad.write_text(ev.read_text() + json.dumps({
            "event": "bundle_received", "id": "d", "bytes": 1, "received_ms": 9500,
            "sig_ok": False, "pubkey_match": True}) + "\n")
        case("final with one bad signature", run(bad, "final"), "4 1401 false 9500")

        empty = d / "empty.jsonl"
        empty.write_text("")
        case("armed on empty file", run(empty, "armed"), "1 0 0 0")
        case("final on empty file", run(empty, "final"), "0 0 false 0")

        case("stats absent -> 0", run(ev, "stats"), "0")
        (d / "stream_stats.json").write_text(json.dumps(
            {"bytes_carried": 123456, "records": 7, "connections": 2, "updated_ms": 1}))
        case("stats fixture -> bytes_carried", run(ev, "stats"), "123456")

        case("util 100000 0 50000 2000 -> 100.0", run(ev, "util", "100000", "0", "50000", "2000"), "100.0")
        case("util 45000 1000 51000 2000 -> 45.0", run(ev, "util", "45000", "1000", "51000", "2000"), "45.0")
        case("util zero-length window does not divide by zero",
             run(ev, "util", "0", "5", "5", "2000"), "0.0")

        # Ceiling model with HEADER_B = 180 (record header line) + 19 (hello share
        # per id); the design's 160 understated it, so 60/1234800/2/112 is 93.1,
        # not the 93.3 of design section A.5.
        def ceiling(n, payload, probe_s, open_s):
            return 100 * (1 - 52 / 1500) * (1 - HEADER_B * n / payload) * (1 - (probe_s / 2 + 1.2 + 0.75) / open_s)
        case_close("ceiling 60 1234800 2 112 (Gate-2 queue, mean measured open) -> 93.1",
                   run(ev, "ceiling", "60", "1234800", "2", "112"), ceiling(60, 1234800, 2, 112), 0.1)
        case_close("ceiling 20 411600 2 90 (v2 default plan)", run(ev, "ceiling", "20", "411600", "2", "90"),
                   ceiling(20, 411600, 2, 90), 0.1)
        # Per-window: the text/voice window of Gate 2 (45 records in 224 KB) has a
        # ceiling ~3 points under the run-level number; a video window ~1 above it.
        case_close("ceiling per window 45 224000 2 112 (text/voice window) -> ~90.2",
                   run(ev, "ceiling", "45", "224000", "2", "112"), ceiling(45, 224000, 2, 112), 0.1)
        case_close("ceiling per window 2 200000 2 112 (video window) -> ~93.9",
                   run(ev, "ceiling", "2", "200000", "2", "112"), ceiling(2, 200000, 2, 112), 0.1)
        case_close("ceiling per window 0 0 2 5.0 (early-ended final window, no division by zero)",
                   run(ev, "ceiling", "0", "0", "2", "5.0"), ceiling(0, 1, 2, 5.0), 0.1)
        # The nominal WINDOW_S=90 would print 0.7 pt lower than the measured open;
        # the runner must never pass it (pinned by the structural checks below).
        case_close("ceiling 60 1234800 2 90 (nominal, NOT what the runner prints)",
                   run(ev, "ceiling", "60", "1234800", "2", "90"), ceiling(60, 1234800, 2, 90), 0.1)

    failures += structural_checks(RUNNER.read_text())
    print("%d failure(s)" % failures)
    return 1 if failures else 0


HEADER_B = 180 + 19


def structural_checks(text: str) -> int:
    """Pin the ORDER of the v3 window close in the runner's source: the values
    the gate reads must be sampled at the close, not a second earlier, and the
    shaper's cumulative counters must be logged at the open as well as the close.
    Each check names the refuter scenario it guards (2026-09-05)."""
    failures = 0
    lines = text.splitlines()

    def first(pattern: str, start: int = 0) -> int:
        for i in range(start, len(lines)):
            if pattern in lines[i]:
                return i
        return -1

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += 0 if ok else 1
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (" (" + detail + ")") if detail and not ok else ""))

    loop = first('for w in $(seq 1 "$WINDOWS"); do')
    # The outer loop's `done` is indented exactly two spaces; the inner per-second
    # loop's `done` is deeper and must not end the range early.
    loop_end = next((i for i in range(loop + 1, len(lines)) if lines[i] == "  done"), -1)
    close = first("close_ms=$(now_ms)", loop)
    c1 = first("c1=$(acct stats)", loop)
    redelivered = first("delivered=$(acct delivered)", close)
    gate = first('if [ "$delivered" -lt "$N_BUNDLES" ]', loop)
    brk = first('[ "$delivered" -ge "$N_BUNDLES" ] && break', loop)
    cut = first('cut_link || die "could not close the window"', loop)
    check("v3 loop found", loop > 0 and loop_end > loop and close > loop)
    # Scenario: bundle 60 lands during the loop's last sleep; a stale `delivered`
    # gates a finished window and spends another cut.
    check("delivered re-read after close_ms and before the gate test and the break",
          close < redelivered < gate < brk, "close=%d reread=%d gate=%d break=%d" % (close, redelivered, gate, brk))
    # Numerator (c1) and denominator (close_ms) end at the same instant, before the cut.
    check("c1 read right after close_ms, before the cut", close < c1 < cut and c1 - close <= 4,
          "close=%d c1=%d cut=%d" % (close, c1, cut))
    # Scenario: Drp is cumulative across `dnctl pipe config` and counts plr-1.0
    # drops of every previous cut; a single close-time reading cannot be 0.
    status_lines = [i for i in range(loop, loop_end) if '"$SHAPE" status' in lines[i]]
    open_ms = first("open_ms=$(now_ms)", loop)
    check("shaper status logged twice per window: a baseline after the open and one at the close",
          len(status_lines) == 2 and open_ms < status_lines[0] < close < status_lines[1],
          "status at %s open_ms=%d close=%d" % (status_lines, open_ms, close))
    check("open baseline is logged after c0 so its bytes stay in the window's numerator",
          len(status_lines) == 2 and first("c0=$(acct stats)", loop) < status_lines[0])
    check("both shape.log headers say the window's drops are the difference",
          all("Drp" in lines[i - 1] or "Drp" in lines[i] for i in status_lines))
    # Scenario: a video window at 93.0 % over a 112 s open is called a measurement
    # bug against a 92.6 ceiling computed with the nominal 90 s.
    check("per-window ceiling uses the window's records, payload and measured open seconds",
          first('acct ceiling "$w_count" "$w_bytes" "$PROBE_S" "$w_open_s"', loop) > close)
    check("run-level ceiling uses the mean measured open seconds, not WINDOW_S",
          first('acct ceiling "$N_BUNDLES" "$BYTES_TOTAL" "$PROBE_S" "$mean_open_s"') > 0
          and first('acct ceiling "$N_BUNDLES" "$BYTES_TOTAL" "$PROBE_S" "$WINDOW_S"') < 0)
    check("note and row carry the per-window ceiling list", text.count("ceiling=${ceiling_list:--}") == 2)
    check("HEADER_B single-sourced in ACCT_PY as 180+19", "HEADER_B=180+19" in text and "160*n" not in text)
    return failures


if __name__ == "__main__":
    sys.exit(main())
