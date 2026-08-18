#!/usr/bin/env python3
"""Harvest volatile /tmp/h2run.* rig captures into a durable committed corpus.

Reads each /tmp/h2run.<suffix>/ directory that contains a test.log, parses:
  - summary lines:  (SLA|MSG|VID|PROBE)_SUMMARY {json}
  - event lines:    'e2e <role> pcStatus: PeerConnectionStatus.<name> @<N>s'
                    'e2e <role> phase: <N>s <name> <optional detail>'
                    'e2e <role> localCand: ... typ <type> ... @<N>s'
                    'e2e <role> in: <kind> ... @<N>s'
  - traffic.txt (tcpdump text): per-second {packets, bytes} series
and joins each run against tools/t2/h2_results.tsv by nearest row date to the
test.log mtime. Output: one JSON per run + index.json under
tools/t2/replay_corpus/. Deterministic, python3 stdlib only, idempotent.
"""

import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

# Directory this script lives in (tools/t2) — corpus and TSV are siblings.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CORPUS_DIR = os.path.join(SCRIPT_DIR, "replay_corpus")
TSV_PATH = os.path.join(SCRIPT_DIR, "h2_results.tsv")
RUN_DIR_GLOB = "/tmp/h2run.*"

# 64 MiB traffic.txt size cap — from the task spec ("skip if >64MB").
TRAFFIC_MAX_BYTES = 64 * 1024 * 1024
# 900 s TSV-join window — from the task spec ("nearest within 900s").
TSV_JOIN_MAX_GAP_S = 900
# 200-char cap on phase detail text — from the task spec ("cap detail at 200 chars").
PHASE_DETAIL_MAX_CHARS = 200
# 86400 = 24*60*60 seconds per day — for tcpdump timestamp midnight wrap.
SECONDS_PER_DAY = 86400

SUMMARY_RE = re.compile(r"(SLA|MSG|VID|PROBE)_SUMMARY (\{.*\})")
# One line per second from the in-call sentinel probe (v4 pillar 6): the
# per-second trend signal that makes the predictor component trainable.
TREND_RE = re.compile(r"TREND (\{.*\})")
PC_STATUS_RE = re.compile(
    r"e2e (\S+) pcStatus: PeerConnectionStatus\.(\w+) @(\d+)s"
)
PHASE_RE = re.compile(r"e2e (\S+) phase: (\d+)s (\S+)(?: (.+))?$")
LOCAL_CAND_RE = re.compile(r"e2e (\S+) localCand: .*?\btyp (\S+)\b.* @(\d+)s")
IN_RE = re.compile(r"e2e (\S+) in: (\S+).* @(\d+)s")
# tcpdump default text line: 'HH:MM:SS.ffffff IP ... length N'
TRAFFIC_TIME_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})\.\d+ ")
TRAFFIC_LENGTH_RE = re.compile(r"\blength (\d+)")

# 15-column current h2_results.tsv layout — from the task spec.
TSV_COLS_CURRENT = [
    "date", "profile", "test", "verdict", "rtt_ms", "loss_pct", "packets",
    "elapsed_ms", "connect_ms", "ack_p50", "ack_p95", "ack_loss",
    "recovery_ms", "alive", "note",
]
# 9-column legacy layout: current layout minus the six ack/recovery columns.
TSV_COLS_LEGACY = [
    "date", "profile", "test", "verdict", "rtt_ms", "loss_pct", "packets",
    "elapsed_ms", "note",
]


def parse_test_log(path):
    """Return (events sorted by t_s, summaries dict, trend sample list)."""
    events = []
    summaries = {}
    trend = []
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = SUMMARY_RE.search(line)
            if m:
                try:
                    parsed = json.loads(m.group(2))
                except ValueError:
                    continue
                summaries.setdefault(m.group(1), []).append(parsed)
                continue
            m = TREND_RE.search(line)
            if m:
                try:
                    trend.append(json.loads(m.group(1)))
                except ValueError:
                    pass
                continue
            m = PC_STATUS_RE.search(line)
            if m:
                events.append({"t_s": int(m.group(3)), "kind": "pcStatus",
                               "role": m.group(1), "name": m.group(2)})
                continue
            m = PHASE_RE.search(line)
            if m:
                ev = {"t_s": int(m.group(2)), "kind": "phase",
                      "role": m.group(1), "name": m.group(3)}
                if m.group(4):
                    ev["detail"] = m.group(4)[:PHASE_DETAIL_MAX_CHARS]
                events.append(ev)
                continue
            m = LOCAL_CAND_RE.search(line)
            if m:
                events.append({"t_s": int(m.group(3)), "kind": "localCand",
                               "role": m.group(1), "name": m.group(2)})
                continue
            m = IN_RE.search(line)
            if m:
                events.append({"t_s": int(m.group(3)), "kind": "in",
                               "role": m.group(1), "name": m.group(2)})
                continue
    events.sort(key=lambda e: e["t_s"])  # stable: log order kept within a second
    return events, summaries, trend


def parse_traffic(path):
    """Per-second {packets, bytes} keyed by seconds since first packet.

    Returns None when the file is missing or larger than TRAFFIC_MAX_BYTES.
    Handles a midnight wrap in the HH:MM:SS timestamps.
    """
    if not os.path.isfile(path):
        return None
    if os.path.getsize(path) > TRAFFIC_MAX_BYTES:
        return None
    series = {}
    first_abs = None
    prev_sod = None
    day_offset = 0
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = TRAFFIC_TIME_RE.match(line)
            if not m:
                continue
            sod = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            if prev_sod is not None and sod < prev_sod:
                day_offset += SECONDS_PER_DAY  # timestamps crossed midnight
            prev_sod = sod
            abs_s = sod + day_offset
            if first_abs is None:
                first_abs = abs_s
            key = str(abs_s - first_abs)
            lm = TRAFFIC_LENGTH_RE.search(line)
            nbytes = int(lm.group(1)) if lm else 0
            slot = series.setdefault(key, {"packets": 0, "bytes": 0})
            slot["packets"] += 1
            slot["bytes"] += nbytes
    return series


def load_tsv_rows(path):
    """Rows as (epoch_s, dict) — 'date' header lines and odd widths skipped."""
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, "r", errors="replace") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if not fields or fields[0] == "date":
                continue
            if len(fields) == len(TSV_COLS_CURRENT):
                cols = TSV_COLS_CURRENT
            elif len(fields) == len(TSV_COLS_LEGACY):
                cols = TSV_COLS_LEGACY
            else:
                continue
            row = dict(zip(cols, fields))
            try:
                dt = datetime.strptime(row["date"], "%Y-%m-%dT%H:%M:%SZ")
            except ValueError:
                continue
            epoch = dt.replace(tzinfo=timezone.utc).timestamp()
            rows.append((epoch, row))
    return rows


def nearest_tsv_row(mtime_epoch, tsv_rows):
    """(row, gap_s) of the row whose date is nearest the mtime, within window."""
    best = None
    best_gap = None
    for epoch, row in tsv_rows:
        gap = abs(mtime_epoch - epoch)
        if best_gap is None or gap < best_gap:
            best_gap = gap
            best = row
    if best is not None and best_gap <= TSV_JOIN_MAX_GAP_S:
        return best, int(round(best_gap))
    return None, None


def main():
    os.makedirs(CORPUS_DIR, exist_ok=True)
    tsv_rows = load_tsv_rows(TSV_PATH)

    # --one <run_dir>: harvest exactly one run (the federated per-run mode
    # h2_run.sh invokes at the end of EVERY run — v4 pillar 6: the corpus
    # is a permanent recorder, not a rescue tool). No flag: the original
    # sweep over /tmp/h2run.*.
    if len(sys.argv) >= 3 and sys.argv[1] == "--one":
        run_dirs = [sys.argv[2]]
    else:
        run_dirs = sorted(glob.glob(RUN_DIR_GLOB))

    wrote = 0
    skipped = 0
    filenames = []
    joined = 0
    summary_type_counts = {}
    event_counts = []
    trend_counts = []

    for run_dir in run_dirs:
        if not os.path.isdir(run_dir):
            continue
        test_log = os.path.join(run_dir, "test.log")
        if not os.path.isfile(test_log):
            skipped += 1
            continue
        mtime = os.path.getmtime(test_log)
        stamp = datetime.fromtimestamp(mtime, tz=timezone.utc)
        events, summaries, trend = parse_test_log(test_log)
        packet_series = parse_traffic(os.path.join(run_dir, "traffic.txt"))
        tsv_row, gap_s = nearest_tsv_row(mtime, tsv_rows)

        suffix = os.path.basename(run_dir).split("h2run.", 1)[-1]
        fname = "run_%s_%s.json" % (stamp.strftime("%Y%m%dT%H%M%SZ"), suffix)
        record = {
            "runDir": run_dir,
            "capturedUtc": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tsvRow": tsv_row,
            "tsvJoinGapS": gap_s,
            "events": events,
            "summaries": summaries,
            "packetSeries": packet_series,
        }
        if trend:
            record["trendSeries"] = trend
        with open(os.path.join(CORPUS_DIR, fname), "w") as f:
            json.dump(record, f, indent=1, sort_keys=True)
            f.write("\n")
        wrote += 1
        filenames.append(fname)
        if tsv_row is not None:
            joined += 1
        for stype in summaries:
            summary_type_counts[stype] = summary_type_counts.get(stype, 0) + 1
        event_counts.append(len(events))
        trend_counts.append(len(trend))

    # The index always lists the WHOLE corpus directory (not just this
    # invocation's files) so the per-run federated mode keeps it complete.
    index = {
        "runs": sorted(
            n for n in os.listdir(CORPUS_DIR)
            if n.startswith("run_") and n.endswith(".json")
        ),
        "builtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(CORPUS_DIR, "index.json"), "w") as f:
        json.dump(index, f, indent=1, sort_keys=True)
        f.write("\n")

    total_files = len([n for n in os.listdir(CORPUS_DIR)
                       if os.path.isfile(os.path.join(CORPUS_DIR, n))])
    print("corpus: wrote %d, skipped %d, total files %d"
          % (wrote, skipped, total_files))
    print("runs with non-null tsvRow: %d/%d" % (joined, wrote))
    for stype in sorted(summary_type_counts):
        print("runs with %s_SUMMARY: %d" % (stype, summary_type_counts[stype]))
    if event_counts:
        print("event counts: min %d, max %d"
              % (min(event_counts), max(event_counts)))
    if any(trend_counts):
        print("runs with TREND series: %d (samples min %d, max %d)"
              % (sum(1 for t in trend_counts if t),
                 min(t for t in trend_counts if t),
                 max(t for t in trend_counts if t)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
