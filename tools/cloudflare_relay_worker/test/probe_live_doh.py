#!/usr/bin/env python3
"""Live end-to-end probe of the give/DoH endpoint on the deployed relay.

Carries a real `give GET /health` over DNS-over-HTTPS against the live worker:
the responder must forward it to the relay's own /health and return "ok" down
the lane. This proves the whole chain (DoH -> DO -> relay replay -> lane), not
just that the path stopped returning the decoy page.

HTTP is done via curl (normal TLS verification). Usage:
    python3 test/probe_live_doh.py [base_url]
"""
import base64
import os
import subprocess
import sys
import time

T2 = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "t2"))
sys.path.insert(0, T2)

from txt_give import encode_request, decode_response, GET  # noqa: E402
from txt_query_wire import (  # noqa: E402
    build_dns_query_packet,
    build_query_name,
    encode_queries,
    parse_dns_answer_packet,
    unframe_down,
    POLL_SEQ,
)

BASE = (sys.argv[1] if len(sys.argv) > 1 else
        "https://voice-call-relay.tlscodes-com.workers.dev").rstrip("/")
DOMAIN = "relay.example"
TXID = 0x7788
UA = "voice-call-kit-give-probe/1"


def doh(packet: bytes):
    """One DoH GET ?dns= via curl; returns (content_type, answer_bytes)."""
    dns = base64.urlsafe_b64encode(packet).decode("ascii").rstrip("=")
    url = f"{BASE}/dns-query?dns={dns}"
    # -w writes the content-type on a trailing line; body is binary before it.
    out = subprocess.run(
        ["curl", "-sS", "-A", UA, "-H", "accept: application/dns-message",
         "-w", "\\n__CT__%{content_type}", url],
        capture_output=True, timeout=25,
    )
    if out.returncode != 0:
        fail(f"curl failed rc={out.returncode}: {out.stderr.decode(errors='replace')[:200]}")
    blob = out.stdout
    marker = b"\n__CT__"
    i = blob.rfind(marker)
    if i < 0:
        return "", blob
    return blob[i + len(marker):].decode(errors="replace"), blob[:i]


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def main():
    payload = encode_request(GET, "/health", {}, b"")
    session, names = encode_queries(payload, DOMAIN)
    print(f"probe {BASE}/dns-query  session={session}  uplink_chunks={len(names)}")

    first_ct = None
    for name in names:
        ct, _ = doh(build_dns_query_packet(TXID, name))
        if first_ct is None:
            first_ct = ct
    print(f"content-type on /dns-query = {first_ct!r}")
    if "application/dns-message" not in (first_ct or ""):
        fail(f"GET /dns-query returned {first_ct!r}, not application/dns-message "
             "(route did not match or the deploy did not take)")

    poll_name = build_query_name(b"", POLL_SEQ, session, "aaaa", DOMAIN)
    poll_pkt = build_dns_query_packet(TXID, poll_name)
    acc = b""
    for _ in range(20):
        _, ans = doh(poll_pkt)
        parsed = parse_dns_answer_packet(ans)
        if parsed.rcode == 0 and parsed.payload is not None:
            acc += unframe_down(parsed.payload)
        if len(acc) >= 8 and len(acc) >= 8 + int.from_bytes(acc[4:8], "big"):
            break
        time.sleep(0.2)

    if len(acc) < 8:
        fail("no give response drained over the lane (responder reachable but silent)")
    status, body = decode_response(acc)
    print(f"give response: status={status} body={body!r}")
    if status == 200 and body.strip() == b"ok":
        print("LIVE PASS: give GET /health round-tripped over DoH against the real relay")
        return
    if status == 502:
        fail("responder answered but the relay replay failed (502) — self-subrequest to origin blocked")
    fail(f"unexpected give response status={status} body={body!r}")


if __name__ == "__main__":
    main()
