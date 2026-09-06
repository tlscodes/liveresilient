#!/usr/bin/env python3
from __future__ import annotations
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from txt_query_wire import encode_queries, parse_query_name
DOMAIN = "example.test"
failures = 0
def check(name, ok, detail=""):
    global failures
    print(f"  {'PASS' if ok else 'FAIL'} {name}" + (f" {detail}" if detail else ""))
    if not ok: failures += 1
def main():
    print("gate_cache_names")
    payload = bytes(range(29))
    _, a = encode_queries(payload, DOMAIN)
    _, b = encode_queries(payload, DOMAIN)
    check("two encodes differ", a != b)
    pa = [parse_query_name(n, DOMAIN) for n in a]
    pb = [parse_query_name(n, DOMAIN) for n in b]
    nonces = [p.nonce for p in pa + pb]
    check("all nonces unique", len(set(nonces)) == len(nonces))
    check("seq0 present both", pa[0].seq == 0 and pb[0].seq == 0)
    print("journey_txt_query_cache " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0
if __name__ == "__main__":
    raise SystemExit(main())
