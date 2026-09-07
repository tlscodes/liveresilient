#!/usr/bin/env python3
from __future__ import annotations
import os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from txt_query_client import TxtQueryClient
from txt_query_server import TxtQueryServer
from txt_query_wire import encode_queries
DOMAIN = "example.test"
failures = 0
def check(name, ok, detail=""):
    global failures
    print(f"  {'PASS' if ok else 'FAIL'} {name}" + (f" {detail}" if detail else ""))
    if not ok: failures += 1
def main():
    print("gate_session_ttl")
    ttl = 0.4
    payload = bytes(range(54))
    session, names = encode_queries(payload, DOMAIN)
    check("two fragments", len(names) == 2, str(len(names)))
    with TxtQueryServer(DOMAIN, host="127.0.0.1", port=0, echo=True, session_ttl=ttl) as srv:
        with TxtQueryClient(DOMAIN, server=("127.0.0.1", srv.port), timeout_s=3.0) as cli:
            cli.query_name(names[0])
            live = srv.live_sessions()
            check("session live after first piece", session.lower() in [s.lower() for s in live], str(live))
            time.sleep(ttl + 0.25)
            live_after = srv.live_sessions()
            check("session gone after ttl", session.lower() not in [s.lower() for s in live_after], str(live_after))
            reply = cli.query_name(names[1])
            complete = srv.take_complete()
            check("no assemble after expiry", complete == [], str(complete))
            check("late piece is not full payload", reply != payload)
    print("journey_txt_query_ttl " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0
if __name__ == "__main__":
    raise SystemExit(main())
