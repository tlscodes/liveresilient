"""Responder side of the letter path probe (Dart: TxtLetterProbe).

Payload "PRB1" + group(8) + nonce(8). The server logs nonces per group in
arrival order and answers each probe with the FIRST logged nonce + rank.
A probe must never surface as a completed letter. Run: python3 test_txt_probe.py
"""
from __future__ import annotations

import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from txt_query_server import TxtQueryServer  # noqa: E402
from txt_query_wire import build_dns_query_packet, encode_queries, parse_dns_answer_packet, unframe_down  # noqa: E402

DOMAIN = "example.test"
failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    print(("  PASS " if ok else "  FAIL ") + name + (f" {detail}" if detail else ""))
    if not ok:
        failures += 1


def send(srv: TxtQueryServer, payload: bytes, source: str) -> bytes | None:
    _, names = encode_queries(payload, DOMAIN)
    reply = None
    for i, name in enumerate(names):
        reply = srv._handle(build_dns_query_packet(0x2000 + i, name), (source, 5353))
    ans = parse_dns_answer_packet(reply)
    return unframe_down(ans.payload) if ans.payload is not None else None


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    srv = TxtQueryServer(DOMAIN, echo=True)
    group = bytes(range(8))
    n1, n2, n3 = b"\x11" * 8, b"\x22" * 8, b"\x33" * 8

    r2 = send(srv, b"PRB1" + group + n2, "10.0.0.2")  # arrives first
    r1 = send(srv, b"PRB1" + group + n1, "10.0.0.1")
    r3 = send(srv, b"PRB1" + group + n3, "10.0.0.3")
    check("first arrival is the winner in every reply",
          all(r is not None and r[12:20] == n2 for r in (r1, r2, r3)), repr((r1, r2, r3)))
    check("ranks follow arrival order", [r[20] for r in (r2, r1, r3)] == [1, 2, 3])
    check("reply echoes the group", all(r[:12] == b"PRB1" + group for r in (r1, r2, r3)))
    check("a probe is never a completed letter", srv.take_complete() == [])

    again = send(srv, b"PRB1" + group + n1, "10.0.0.9")
    check("a repeated nonce keeps its first rank", again[20] == 2 and again[12:20] == n2)

    other = bytes([9] * 8)
    r = send(srv, b"PRB1" + other + n3, "10.0.0.3")
    check("a new group starts its own log", r[12:20] == n3 and r[20] == 1)

    letter = b"a real letter " * 40
    back = send(srv, letter, "10.0.0.1")
    done = srv.take_complete()
    check("a letter still completes and echoes", len(done) == 1 and done[0][1] == letter and back is not None)
    near = b"PRB1" + group + n1 + b"x"  # 21 bytes: not a probe
    send(srv, near, "10.0.0.1")
    check("a payload that only starts with PRB1 is a letter", [p for _, p in srv.take_complete()] == [near])

    for i in range(TxtQueryServer.MAX_PROBE_GROUPS + 5):
        srv._probe_reply_locked(b"PRB1" + i.to_bytes(8, "big") + n1, "x")
    check("probe groups are bounded", len(srv._probes) <= TxtQueryServer.MAX_PROBE_GROUPS, str(len(srv._probes)))

    print("txt_probe " + ("PASS" if not failures else f"FAIL ({failures})"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
