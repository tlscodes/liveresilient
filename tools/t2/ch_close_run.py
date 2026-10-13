#!/usr/bin/env python3
"""Close the ch plan by hand after the driver halted on its deadline.

Marks ch-w3-run and ch-commit-w3 passed ONLY if their declared verify_cmds
exit 0 right now; otherwise changes nothing and exits 1.
"""
import datetime
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / ".autorun" / "run.json"
STEPS = ("ch-w3-run", "ch-commit-w3")

d = json.loads(RUN.read_text())
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
for s in d["steps"]:
    if s["id"] not in STEPS:
        continue
    rc = subprocess.run(s["verify_cmd"], shell=True, cwd=ROOT).returncode
    if rc != 0:
        print(f"{s['id']}: verify_cmd rc={rc} — not closed")
        sys.exit(1)
    s["status"] = "passed"
    s["note"] = (f"verify_cmd rc=0 re-run {now} by tools/t2/ch_close_run.py "
                 "(driver halted on its deadline after the owner-gated window); "
                 "evidence push_w4, commit 209a566")
d["armed"] = False
d["result"] = "done: push_w4 VERDICT ch PASS rc=0, committed 209a566 (not pushed)"
RUN.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
print([(s["id"], s.get("status")) for s in d["steps"]])
print(d["result"])
