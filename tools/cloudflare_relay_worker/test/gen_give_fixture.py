#!/usr/bin/env python3
"""Emit a give/DoH wire fixture from the PROVEN Python responder codec.

The Dart client is already proven byte-for-byte against txt_query_server.py.
This writes the exact query packets that codec would send and the exact give
response it would expect, so the JS worker port (txt_give_doh.js) can be driven
with the proven bytes and its answers parsed back by the same codec.

Run from the worker dir; writes test/give_fixture.json.
"""
import base64
import json
import os
import sys

T2 = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "t2"))
sys.path.insert(0, T2)

from txt_give import encode_request, encode_response, GET, PUT  # noqa: E402
from txt_query_wire import (  # noqa: E402
    build_dns_query_packet,
    build_query_name,
    encode_queries,
    frame_up,
    split_chunks,
    POLL_SEQ,
)

DOMAIN = "relay.example"
TXID = 0x1234


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def queries_for(session_id: str, payload: bytes):
    """DNS query packets (hex) for every uplink chunk of one give payload."""
    _sid, names = encode_queries(payload, DOMAIN, session_id=session_id)
    return [build_dns_query_packet(TXID, n).hex() for n in names]


def poll_for(session_id: str):
    name = build_query_name(b"", POLL_SEQ, session_id, "aaaa", DOMAIN)
    return build_dns_query_packet(TXID, name).hex()


def make_case(name, session_id, method, path, headers, body, relay_status, relay_body):
    payload = encode_request(method, path, headers, body)
    give_response = encode_response(relay_status, relay_body)
    return {
        "name": name,
        "session": session_id,
        "queries": queries_for(session_id, payload),
        "poll": poll_for(session_id),
        "expect": {
            "method": "GET" if method == GET else "PUT",
            "path": path,
            "headers": headers,
            "body_b64": b64(body),
        },
        "relay_status": relay_status,
        "relay_body_b64": b64(relay_body),
        "give_response_b64": b64(give_response),
        # how many framed uplink chunks this payload split into
        "uplink_chunks": len(split_chunks(frame_up(payload))),
    }


def main():
    cases = [
        make_case(
            "get_small",
            "aaaaaa",
            GET,
            "/o/abcdef0123456789",
            {},
            b"",
            200,
            bytes(range(256)) * 1 + b"-the-sealed-box",  # 271 bytes, one downstream frame
        ),
        make_case(
            "put_multi_up_and_down",
            "bbbbbb",
            PUT,
            "/a/authorabc/0",
            {"x-broadcast-auth": "A" * 40},
            bytes((i * 7) & 0xFF for i in range(500)),  # 500-byte body -> multi-chunk uplink
            201,
            bytes((i * 13) & 0xFF for i in range(1500)),  # 1500 bytes -> spans >1 downstream poll
        ),
    ]
    out = {"domain": DOMAIN, "txid": TXID, "poll_seq": POLL_SEQ, "cases": cases}
    dest = os.path.join(os.path.dirname(__file__), "give_fixture.json")
    with open(dest, "w") as fh:
        json.dump(out, fh, indent=2)
    print(f"wrote {dest}: {len(cases)} cases")
    for c in cases:
        print(f"  {c['name']}: uplink_chunks={c['uplink_chunks']} queries={len(c['queries'])}")


if __name__ == "__main__":
    main()
