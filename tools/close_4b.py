#!/usr/bin/env python3
"""Moves 4b out of the blocked list, recording what actually met it.

Written as a script rather than a hand edit so the move is one reviewable
operation on the file that owns the data, and so re-running it is a no-op
instead of a second entry.
"""

import json
import sys

PATH = "docs/gate_backlog.json"

CLOSED = (
    "CLOSED 2026-08-18. The blocker was a missing privilege rule, and the "
    "maintainer wrote it: one line in /etc/sudoers.d granting the exact "
    "absolute path of tools/t2/step7_trace.sh, never ALL. With it the capture "
    "ran unattended (sudo -n, 900 seconds, rvictl+tcpdump on the attached "
    "device) while the on-device probe connected to the local helper inside the "
    "window. What closed the gate is not the capture alone but what the capture "
    "supports: the name that must not travel in the clear is absent from every "
    "one of 68,511,532 bytes in three encodings, scanned by a scanner that "
    "first had to find those encodings planted in a scratch file including "
    "across a read seam; and the name that must appear is not merely present "
    "but located -- packet 4, offset 191 inside that packet's data region, "
    "parsed as the server_name of a handshake record whose offered extension "
    "list contains 65037, the extension under test. The full recording is not "
    "committed: 65 MB, fifteen minutes of everything the device sent, most of "
    "it unrelated personal traffic. Committed instead are the excerpt holding "
    "the witness, the provenance, and the analysis carrying the full file's "
    "sha256, size and scan coverage -- which is what the acceptance predicate "
    "reads. Evidence: docs/evidence/step7_trace.pcap, "
    "docs/evidence/step7_trace_provenance.txt, "
    "docs/evidence/step7_trace_analysis.txt. Verified by: python3 "
    "tools/step7_analyze.py --recheck ... -> STEP7 RECHECK PASSED."
)


def main() -> int:
    with open(PATH) as handle:
        data = json.load(handle)

    if "4b" not in data.get("blocked", {}):
        print("4b is already out of the blocked list; nothing to do")
        return 0

    data["blocked"].pop("4b")
    data.setdefault("blocked_history", {})["4b"] = CLOSED
    data["recorded"] = "2026-08-18"

    with open(PATH, "w") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(f"4b moved to blocked_history; blocked now holds: {sorted(data['blocked']) or 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
