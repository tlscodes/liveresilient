#!/usr/bin/env python3
"""Section ب, step ۳: a via=txt row per kind — written and opened, SHA equal.

The whole give round trip, end to end over the real TXT lane wire, with no
phone and no network: a throwaway HTTP relay stands in for our own relay, the
authoritative TxtQueryServer runs with echo off, the give loop bridges the two,
and TxtQueryClient is the phone's uplink/poll surface.

The "box" for each kind is opaque bytes. That is exactly what give sees — it
holds no key and never decodes a box — so byte-for-byte equality across the lane
is the property this test owns. That a 30 s voice box actually decodes is a
different property, proven by the media tests and on the rig.
"""

from __future__ import annotations

import hashlib
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from txt_give import GET, PUT, RESP_MAGIC, decode_response, encode_request, serve
from txt_query_client import TxtQueryClient
from txt_query_server import TxtQueryServer

DOMAIN = "valve.test"

# Opaque sealed-box stand-ins, one per kind, at representative sizes. Seeded so
# the digests are stable run to run; the content is irrelevant to give.
KINDS = {
    "text": 313,
    "photo": 5000,
    "voice30": 3007,
    "video": 12000,
}


def _box(seed: int, n: int) -> bytes:
    import random

    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(n))


class _RelayHandler(BaseHTTPRequestHandler):
    """A minimal write-once box store: PUT stores, GET returns or 404s."""

    store: dict[str, bytes] = {}

    def log_message(self, *_a):  # keep the test output quiet
        pass

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        existing = self.store.get(self.path)
        if existing is not None and existing != body:
            self.send_response(409)
            self.end_headers()
            return
        self.store[self.path] = body
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        body = self.store.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def give_round_trip(client: TxtQueryClient, req: bytes, deadline_s: float = 20.0):
    """Send one request up the lane and drain the give response back down."""
    session, last = client.send(req)
    buf = bytearray(last)
    total = None
    deadline = time.monotonic() + deadline_s
    while time.monotonic() < deadline:
        if total is None and len(buf) >= 8:
            if bytes(buf[:2]) != RESP_MAGIC:
                raise AssertionError("downlink is not a give response")
            total = 8 + int.from_bytes(buf[4:8], "big")
        if total is not None and len(buf) >= total:
            break
        chunk = client.poll(session)
        if chunk:
            buf += chunk
        else:
            time.sleep(0.02)
    if total is None or len(buf) < total:
        raise AssertionError(f"give response incomplete: have={len(buf)} total={total}")
    return decode_response(bytes(buf[:total]))


def run() -> list[tuple]:
    _RelayHandler.store = {}
    relay = ThreadingHTTPServer(("127.0.0.1", 0), _RelayHandler)
    relay_port = relay.server_address[1]
    relay_base = f"http://127.0.0.1:{relay_port}"
    relay_thread = threading.Thread(target=relay.serve_forever, daemon=True)
    relay_thread.start()

    srv = TxtQueryServer(DOMAIN, host="127.0.0.1", port=0, echo=False)
    srv.start()
    stop = threading.Event()
    give_thread = threading.Thread(target=serve, args=(srv, relay_base, stop), daemon=True)
    give_thread.start()

    rows: list[tuple] = []
    try:
        client = TxtQueryClient(DOMAIN, server=("127.0.0.1", srv.port), timeout_s=4.0)
        for seed, (kind, size) in enumerate(KINDS.items()):
            box = _box(seed + 1, size)
            addr = f"/box/{kind}-{hashlib.sha256(box).hexdigest()[:16]}"
            sha_box = hashlib.sha256(box).hexdigest()

            # written: PUT the box up the lane to the relay.
            status, _ = give_round_trip(client, encode_request(PUT, addr, {}, box))
            put_ok = status == 200
            rows.append((kind, "put", "txt", len(box), sha_box, put_ok))
            assert put_ok, f"{kind}: PUT returned {status}"

            # opened: GET the box back down the lane.
            status, body = give_round_trip(client, encode_request(GET, addr, {}, b""))
            sha_got = hashlib.sha256(body).hexdigest()
            get_ok = status == 200 and sha_got == sha_box and body == box
            rows.append((kind, "get", "txt", len(body), sha_got, get_ok))
            assert status == 200, f"{kind}: GET returned {status}"
            assert body == box, f"{kind}: GET body differs ({len(body)} vs {len(box)} B)"
            assert sha_got == sha_box, f"{kind}: SHA mismatch src={sha_box} dst={sha_got}"

        # A miss is a clean 404 carried through the lane, not a hang.
        status, _ = give_round_trip(client, encode_request(GET, "/box/absent", {}, b""))
        assert status == 404, f"absent box: GET returned {status}, want 404"
        rows.append(("absent", "get", "txt", 0, "-", status == 404))
    finally:
        stop.set()
        give_thread.join(timeout=2.0)
        srv.stop()
        relay.shutdown()
        relay.server_close()
    return rows


def write_rows(rows, path: str) -> None:
    with open(path, "w") as fh:
        fh.write("kind\tdir\tvia\tbytes\tsha\tok\n")
        for kind, direction, via, nbytes, sha, ok in rows:
            fh.write(f"{kind}\t{direction}\t{via}\t{nbytes}\t{sha}\t{'PASS' if ok else 'FAIL'}\n")


def test_give_rows_per_kind():
    rows = run()
    # Every kind written and opened, SHA equal both sides, all via=txt.
    assert all(ok for *_x, ok in rows), rows
    kinds_opened = {k for (k, d, *_r) in rows if d == "get" and k in KINDS}
    assert kinds_opened == set(KINDS), kinds_opened


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "give-rows.tsv")
    rows = run()
    write_rows(rows, out)
    for row in rows:
        print("\t".join(str(c) for c in row))
    ok = all(r[-1] for r in rows)
    print(f"\nrows written to {out}")
    print("ALL PASS" if ok else "SOME FAILED")
    sys.exit(0 if ok else 1)
