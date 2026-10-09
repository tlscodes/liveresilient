#!/usr/bin/env python3
"""The `give` gateway: the only new verb section ب adds.

A phone whose direct TCP to the relay is cut carries the SAME relay GET / PUT
over the existing TXT lane (RFC 1035, test port 5300). This responder is the
far end of that lane: it reassembles one request (method, path, headers, body),
replays it against our own relay over ordinary HTTP, and queues the relay's
answer back down the same lane.

It holds no key and models nothing about letters. The body it forwards is the
sealed box — opaque bytes — and the only host it ever reaches is the one relay
base it was started with (so it is not an open proxy). It never opens port 53,
never deploys a relay, never invents a public domain: it rides the TXT lane the
emergency letter already uses, with the 4096 answer cap untouched.

Wire carried on the lane (payloads only; TxtQueryServer does the DNS framing,
chunking, ordering and the 4096 cap):

    request  (uplink, one session)
        'G1' | method(1) | path_len(2) | path | hdr_count(1) |
        [ name_len(1) name val_len(2) val ]* | body(rest)
    response (downlink, queued once, drained over polls)
        'g1' | status(2) | body_len(4) | body
"""

from __future__ import annotations

import argparse
import logging
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

from txt_query_server import TxtQueryServer

log = logging.getLogger("txt_give")

REQ_MAGIC = b"G1"   # give request envelope, version 1 (uplink)
RESP_MAGIC = b"g1"  # give response envelope, version 1 (downlink)

GET = 1
PUT = 2
METHOD_NAME = {GET: "GET", PUT: "PUT"}
METHOD_CODE = {"GET": GET, "PUT": PUT}

# The lane is narrow, so only the headers the sealed-letter protocol actually
# needs ride along; anything else is dropped before the wire rather than paid
# for in DNS labels. The shelf address is the authorisation for a box; the auth
# header is here for descriptor writes that reuse the same transport.
FORWARD_HEADERS = ("x-broadcast-auth",)

# The gateway reached the lane but not the relay. A real status (404 miss, 409
# conflict) is an answer and is carried through unchanged; this one is minted
# only when the relay itself did not respond, so the shelf can tell a dead
# relay from a dead lane.
RELAY_UNREACHABLE = 502


class EnvelopeError(ValueError):
    """The assembled payload is not a well-formed give envelope."""


@dataclass(frozen=True)
class GiveRequest:
    method: int
    path: str                   # path + optional ?query, relative to the relay base
    headers: dict[str, str]     # lowercased name -> value
    body: bytes


def _u16(n: int) -> bytes:
    if not 0 <= n <= 0xFFFF:
        raise EnvelopeError(f"{n} does not fit u16")
    return n.to_bytes(2, "big")


def _u32(n: int) -> bytes:
    if not 0 <= n <= 0xFFFFFFFF:
        raise EnvelopeError(f"{n} does not fit u32")
    return n.to_bytes(4, "big")


def encode_request(method: int, path: str, headers: dict[str, str], body: bytes) -> bytes:
    if method not in METHOD_NAME:
        raise EnvelopeError(f"unknown method {method}")
    path_b = path.encode("utf-8")
    out = bytearray()
    out += REQ_MAGIC
    out += bytes([method])
    out += _u16(len(path_b))
    out += path_b
    items = [(k.lower(), v) for k, v in headers.items() if k.lower() in FORWARD_HEADERS]
    if len(items) > 0xFF:
        raise EnvelopeError("too many headers")
    out += bytes([len(items)])
    for name, value in items:
        nb = name.encode("ascii")
        vb = value.encode("utf-8")
        if len(nb) > 0xFF:
            raise EnvelopeError("header name too long")
        out += bytes([len(nb)])
        out += nb
        out += _u16(len(vb))
        out += vb
    out += body
    return bytes(out)


def decode_request(payload: bytes) -> GiveRequest:
    mv = memoryview(payload)
    if len(mv) < 5 or bytes(mv[:2]) != REQ_MAGIC:
        raise EnvelopeError("not a give request")
    method = mv[2]
    if method not in METHOD_NAME:
        raise EnvelopeError(f"unknown method {method}")
    path_len = int.from_bytes(mv[3:5], "big")
    pos = 5
    if len(mv) < pos + path_len + 1:
        raise EnvelopeError("truncated path")
    path = bytes(mv[pos:pos + path_len]).decode("utf-8")
    pos += path_len
    hdr_count = mv[pos]
    pos += 1
    headers: dict[str, str] = {}
    for _ in range(hdr_count):
        if len(mv) < pos + 1:
            raise EnvelopeError("truncated header name length")
        nl = mv[pos]
        pos += 1
        if len(mv) < pos + nl + 2:
            raise EnvelopeError("truncated header name")
        name = bytes(mv[pos:pos + nl]).decode("ascii")
        pos += nl
        vl = int.from_bytes(mv[pos:pos + 2], "big")
        pos += 2
        if len(mv) < pos + vl:
            raise EnvelopeError("truncated header value")
        value = bytes(mv[pos:pos + vl]).decode("utf-8")
        pos += vl
        headers[name.lower()] = value
    body = bytes(mv[pos:])
    return GiveRequest(method=method, path=path, headers=headers, body=body)


def encode_response(status: int, body: bytes) -> bytes:
    return RESP_MAGIC + _u16(status) + _u32(len(body)) + body


def decode_response(payload: bytes) -> tuple[int, bytes]:
    if len(payload) < 8 or payload[:2] != RESP_MAGIC:
        raise EnvelopeError("not a give response")
    status = int.from_bytes(payload[2:4], "big")
    body_len = int.from_bytes(payload[4:8], "big")
    body = payload[8:8 + body_len]
    if len(body) < body_len:
        raise EnvelopeError(f"incomplete body have={len(body)} want={body_len}")
    return status, body


def forward(relay_base: str, req: GiveRequest, timeout: float = 15.0) -> tuple[int, bytes]:
    """Replay one request against the relay base this gateway was given.

    Only the path and query from the envelope are used; a scheme or host in the
    envelope is refused, so a sender can never aim the gateway at anything but
    our own relay.
    """
    base = urlsplit(relay_base)
    if not base.scheme or not base.netloc:
        raise EnvelopeError(f"relay base {relay_base!r} needs scheme and host")
    want = urlsplit(req.path)
    if want.scheme or want.netloc:
        raise EnvelopeError("path must be relative to the relay base")
    path = want.path or "/"
    target = urlunsplit((base.scheme, base.netloc, path, want.query, ""))
    method = METHOD_NAME[req.method]
    data = req.body if req.method == PUT else None
    http_req = urllib.request.Request(target, data=data, method=method)
    for name in FORWARD_HEADERS:
        if name in req.headers:
            http_req.add_header(name, req.headers[name])
    # Cloudflare refuses urllib's default "Python-urllib/x.y" agent with a 403
    # (error 1010) before the worker sees the request.
    http_req.add_header("User-Agent", "voice-call-kit-give/1")
    try:
        with urllib.request.urlopen(http_req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read() or b""
    except (urllib.error.URLError, OSError) as exc:
        log.warning("relay unreachable: %s", exc)
        return RELAY_UNREACHABLE, b""


def handle_payload(relay_base: str, payload: bytes) -> bytes:
    """Turn one assembled uplink payload into the downlink to queue.

    A payload that is not a give request gets no downlink (b""), so a stray
    letter session on the same lane is simply ignored rather than answered.
    """
    try:
        req = decode_request(payload)
    except EnvelopeError as exc:
        log.debug("ignoring non-give payload (%d B): %s", len(payload), exc)
        return b""
    status, body = forward(relay_base, req)
    log.info("give %s %s -> %d (%d B)", METHOD_NAME[req.method], req.path, status, len(body))
    return encode_response(status, body)


def serve(srv: TxtQueryServer, relay_base: str, stop: threading.Event,
          idle: float = 0.01) -> None:
    """Drain completed sessions and queue each one's relay answer back down.

    The loop is tight on purpose: the phone has already sent its request and is
    polling for the answer, so a half-second drain (the letter responder's
    cadence) would add a half-second to every round trip.
    """
    while not stop.is_set():
        got = srv.take_complete()
        if not got:
            time.sleep(idle)
            continue
        for session, payload in got:
            resp = handle_payload(relay_base, payload)
            if resp:
                srv.queue_down(session, resp)


def main() -> None:
    p = argparse.ArgumentParser(description="give gateway over the TXT lane")
    p.add_argument("--domain", required=True)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5300,
                   help="TXT lane test port; never 53")
    p.add_argument("--relay", required=True,
                   help="base URL of our own relay, e.g. http://127.0.0.1:8080")
    args = p.parse_args()
    if args.port == 53:
        p.error("the give gateway runs on the TXT lane test port, never 53")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    srv = TxtQueryServer(args.domain, host=args.host, port=args.port, echo=False)
    srv.start()
    log.info("give gateway up: udp/%s:%s tunnel.%s -> %s",
             args.host, srv.port, args.domain, args.relay)
    stop = threading.Event()
    try:
        serve(srv, args.relay, stop)
    except KeyboardInterrupt:
        stop.set()
    finally:
        srv.stop()


if __name__ == "__main__":
    main()
