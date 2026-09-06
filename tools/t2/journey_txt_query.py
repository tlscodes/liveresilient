#!/usr/bin/env python3
from __future__ import annotations
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
GATES = [
    "test_txt_query_wire.py",
    "test_txt_query_loopback.py",
    "test_txt_query_failure.py",
    "test_txt_query_cache.py",
    "test_txt_query_ttl.py",
]
def main():
    rows, rc = [], 0
    for name in GATES:
        p = subprocess.run([sys.executable, os.path.join(HERE, name)], cwd=HERE)
        rows.append(f"{name}={'PASS' if p.returncode==0 else 'FAIL'}")
        if p.returncode: rc = 1
    print("journey_txt_query  " + " ".join(rows))
    return rc
if __name__ == "__main__":
    raise SystemExit(main())
