#!/usr/bin/env python3
"""journey_hub.py — the rig's plain-HTTP meeting point for the phone peer.

The phone-side peer (integration_test/journey_peer_app.dart) is a persistent
install with nothing attached to it, so its job and its evidence travel over
this tiny server on the Mac's bridge address:

  GET  /job          the current job (job.json in the run dir) → 200 JSON,
                     or 204 when there is none / it is already done
  GET  /go/<run>     200 once the orchestrator raised GO for that run
                     (file go_phone exists), else 404
  POST /report       one JSON event; appended verbatim as one line to
                     phone_events.jsonl; an `ended`/`failed` event also
                     marks the job done (job.done)
  POST /blob?run=<run>&kind=<photo|voice|video|file>&id=<item>&sha256=<hex>
                     the raw bytes the phone RECEIVED for one media item,
                     returned so the runner can prove them against the
                     fixture it sent: stored as blobs/<kind>-<id>.bin (a tmp
                     file, then a rename) and logged as one `blob` event
                     line {"event":"blob","run","at","kind","id","bytes",
                     "sha256"} in phone_events.jsonl → 200 `ok`.
                     409 `wrong run` when run is not the job's run;
                     400 when kind or id is not [A-Za-z0-9._-]{1,80} or
                     sha256 is not 64 hex; 413 over 16 MB; 409 `sha
                     mismatch` when the body's sha256 differs from the query
                     (the peer retries); a blob already stored with a
                     DIFFERENT sha is refused 409, the same sha is an
                     idempotent 200 (no second event line).
  GET  /have?id=<id> the pieces already stored for a bundle sent in chunks
                     → 200 JSON {"id","have":[idx...],"n":<n|null>,
                     "complete":bool}; n is null until the first chunk
                     names it; complete is true once the bundle was
                     joined, verified and logged.
  POST /chunk?id=<id>&idx=<i>&n=<n>&sha256=<hex of the WHOLE envelope>
                     one raw piece (≤ 64 KB, Content-Length set) of a
                     signed bundle envelope too large for one /bundle post,
                     stored as chunks/<id>/<idx>.bin → 200 `ok`; the same
                     piece again is an idempotent 200. id is
                     [A-Za-z0-9._-]{1,80}, n in [1,4096], idx in [0,n);
                     a piece naming a different sha or n for a known id →
                     409; over 64 KB → 413. When all n pieces are present
                     they are joined in index order, the sha256 of the
                     joined bytes is checked against the query BEFORE
                     anything is parsed (409 `sha mismatch`, the pieces
                     stay so a re-post can fix them), then the envelope is
                     verified exactly as /bundle does, written to
                     blobs/bundle-<id>.bin and logged as ONE
                     `bundle_received` event carrying "chunks": n → 200
                     `complete sig_ok=.. pubkey_match=..`. A completed id
                     answers every later piece with that same line and
                     never a second event.

Everything is a file in the run directory, which lives inside the Mac app's
sandbox container so the app-journey driver can read the phone's events
directly (see journey_run.sh). No auth, no TLS: bridge100 is a cable.

Stream lane (blackout v3): a second port in this process, default --port + 1,
--stream-port 0 turns it off. Framed TCP: newline-delimited JSON lines plus
raw payload bytes, one writer per bundle. The wire, in order:

  phone→hub  {"v":3,"run":"<run>","pubkey":"<b64>","ids":["<id>",...]}
             ids in delivery order, ≤ 4096, each [A-Za-z0-9._-]{1,80}
  hub→phone  {"state":{"<id>":{"have":<int>,"complete":<bool>},...},
              "piece_bytes","ack_bytes","ack_interval_s","inflight_bytes",
              "inflight_max","stall_s"}   only ids the hub knows (absent = 0);
             the lane parameters are the hub's (STREAM_DEFAULTS, overridden by
             argv). inflight_bytes is the phone's STARTING cap (STREAM_W0, a
             tenth of a second of link); every ack/done line then advertises
             the cap in force, never above inflight_max, growing by at most
             STREAM_RAMP_S seconds of link per ack so the sender's retransmit
             timer can follow it (see the derivation above STREAM_DEFAULTS)
  phone→hub  {"id":"<id>","off":<have>,"len":<total-have>,"total":<int>,
              "created_ms":<int>,"sig":"<b64 64 B>"} then exactly len raw
             payload bytes; len 0 only when off == total (asks again for a
             lost done)
  hub→phone  {"ack":"<id>","have":<int>,"inflight":<int>}   every
             ack_bytes_eff (= inflight // 4, at least STREAM_ACK_MIN, at most
             ack_bytes), every ack_interval_s with new bytes, and at record
             end; inflight is the phone's cap from here on
  hub→phone  {"done":"<id>","sig_ok":<bool>,"pubkey_match":<bool>,
              "bytes":<total>,"inflight":<int>}   implies have = total
  hub→phone  {"error":"<code>","id":<id|null>,"have":<int|null>} then
             close; codes bad_hello wrong_run bad_id bad_sig bad_offset
             meta_mismatch too_large line_too_long preempted

Storage: stream/<id>.part (appended as bytes arrive), <id>.meta.json
{total,sig,created_ms,run} claimed by the first header (a later header for
the id must match it), <id>.complete.json {sig_ok,pubkey_match,bytes} once
verified; the payload lands in blobs/bundle-<id>.bin with ONE
`bundle_received` event carrying "stream": true. A new hello preempts any
live session (one writer per .part); a session silent for 2 × stall_s is
closed. stream_stats.json {bytes_carried,records,connections,updated_ms} is
rewritten atomically on every ack, record end and session close.

USAGE  journey_hub.py --bind <addr> --port 8765 --dir <run dir>
         [--stream-port N] [--stream-stall-s S] [--stream-ack-bytes B]
         [--stream-inflight-bytes B] [--stream-piece-bytes B]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import time
import os
import re
import socket
import socketserver
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

BLOB_MAX_BYTES = 16 * 1024 * 1024
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
CHUNK_MAX_BYTES = 64 * 1024  # one /chunk body
CHUNK_MAX_N = 4096  # pieces per bundle

# Stream lane parameters. The hub is their single source: argv overrides
# these and the values in force are echoed to the phone in the hello reply.
#
# THE INFLIGHT WINDOW IS ADVERTISED, NOT FIXED, AND THE QUEUE IT TARGETS IS
# SHORTER THAN THE SENDER'S RETRANSMIT TIMER (2026-09-06, two measured passes).
#
# Pass 1. A fixed 32 KiB application window on a 2000 B/s pipe is a 16 s
# standing queue. Measured with nettop on this socket over three photo-only
# windows: rx_dupe 47-50 % of bytes_in, rtt_avg 21-26 s, 54-282 pipe drops per
# window, util_carried 39-42 % against a 93.6 % ceiling. The phone's TCP cannot
# track a 1 ms -> 16 s RTT jump, so it retransmits segments that are still
# queued and the retransmits push the 50-slot droptail queue past its cliff.
# The RECEIVER is the only side that sees the true in-order drain rate, so it
# measures that rate over STREAM_T_MEAS_S and advertises the phone's cap in
# every ack and done line:
#     W = clamp(rate * STREAM_T_QUEUE_S, STREAM_W_MIN, inflight_max),  W <= 2 * W_prev
#
# Pass 2 measured a 1 s target queue with a one-segment start and the storm
# survived: rx_dupe 81 % of bytes_in on a photo-only window, with the shaper
# reporting ZERO drops in that window and a queue 7 slots deep out of 50. No
# loss, no full queue, and still four bytes on the wire per byte delivered.
# That falsifies "the queue is too deep" and names the real quantity.
#
# Pass 3 — the ramp, and why the START is what matters. What the sender cannot
# tolerate is an acknowledgement that arrives after its retransmit timer fires,
# and that timer is not derived from this link: a connection takes its first
# round-trip sample from the handshake, which crosses an EMPTY pipe in about a
# millisecond, so the timer sits at its platform floor — a fifth of a second —
# while one full segment needs 0.72 s just to serialize at 2000 B/s. The first
# window therefore times out before its first ack whatever its size, the copy
# is queued behind the original, and Karn's rule then refuses a round-trip
# sample from any retransmitted segment, so the estimate cannot grow to catch
# up. That is the whole storm, and it explains the one thing queue depth never
# could: the same run's small-record window sat at 4 % duplicates and carried
# 91 % of the link, because a 200-byte record serializes in 0.1 s and its ack
# beats the floor.
#
# So the window starts at a FRACTION of a second of link — STREAM_W0, 0.1 s at
# the floor rate — and each ack may add at most STREAM_RAMP_S seconds of link
# to it. The limit is a TIME, not a ratio, because what must stay bounded is
# how much LATER each acknowledgement arrives than the one before: a step of
# rate * 0.1 s pushes the next ack 0.1 s further out, and the sender's smoothed
# estimate moves about an eighth of the way toward each sample while its
# variance term moves a quarter, so a fixed 0.1 s increment is one the estimate
# always outruns (samples 0.2, 0.3, 0.4 s against timers of 0.30, 0.41, 0.53 s,
# the margin widening every step). A RATIO fails at both ends: 2x doubles the
# ack time each step and overtakes the timer by the fourth (0.8 s against
# 0.79 s), while on a fast link any ratio is far too slow — measured here, 1.5x
# per read left the window at 1.5 kB after 200 kB had already been carried,
# because the hub reads 64 kB at a time and therefore acks once per 64 kB. The
# time rule scales itself: on a 10 MB/s link 0.1 s is a megabyte, so the window
# reaches its ceiling on the first ack.
# The steady target is T_QUEUE = 2 s of link: throughput is W / RTT =
# rate * T / (T + return), and the return path is a 50-byte line on its own
# pipe, so a 2 s queue fills ~97 % of the link once the estimate has followed
# it there.
#
# The hello reply's inflight_bytes is the phone's STARTING cap, STREAM_W0;
# inflight_max is the ceiling argv sets (--stream-inflight-bytes). The ack byte
# threshold is a quarter of the window in force (never below STREAM_ACK_MIN), so
# ramp is clocked by the window itself rather than by a fixed 8 KiB that a
# 200-byte window would never reach. Idle time inside the measurement window
# biases the rate DOWN, the safe error; every session starts again at
# STREAM_W0, because the sender's timer starts again with it.
#
# stall_s is derived from the queue this design creates, not from the ceiling:
# the phone's own TCP ACKs, its FIN and the next hello's SYN wait behind at
# most T_QUEUE seconds of payload now, not inflight_max / rate_floor (16.4 s,
# which is what forced stall_s 25 while the window was fixed). A stall timeout
# below the queue latency fires on a healthy window (measured 2026-09-05: with
# stall_s 15 against a 16 s queue every window lost one session to a false
# stall, ~35 s each).
# stall_s = T_QUEUE + 2 * ack_interval_s + margin = 2 + 4 + 4 -> 10 s; the hub
# closes after 2 * stall_s = 20 s of silence, which must stay below the
# shortest cut (MIN_M * 60 = 60 s), and a session that does go quiet costs the
# window 10 s instead of 25.
STREAM_RATE_FLOOR_BPS = 2000  # the 16 kbit/s gate the lane is sized for
STREAM_DEFAULTS = {"piece_bytes": 8192, "ack_bytes": 8192, "ack_interval_s": 2,
                   "inflight_bytes": 32768, "stall_s": 10}
STREAM_T_QUEUE_S = 2.0  # steady-state standing queue, seconds of link
STREAM_T_MEAS_S = 4.0  # rate window: long enough to smooth, short enough to react
STREAM_W_MIN = 1448  # one segment: the floor the steady-state target never goes below
STREAM_W0 = 200  # 0.1 s at the floor rate: the first ack beats the sender's RTO floor
STREAM_RAMP_S = 0.1  # seconds of link a single ack may add to the window
STREAM_ACK_MIN = 64  # smallest ack step, so even the first 200-byte window is clocked
STREAM_LINE_MAX = 262144  # longest JSON line accepted on the stream lane
STREAM_V = 3  # the hello's "v"
STREAM_IDS_MAX = 4096  # ids per hello


class BodyTooLarge(Exception):
    """The request body exceeds the limit given to _read_body."""


class BadBundle(Exception):
    """The bytes are not the JSON envelope the peer signs; str() is the reply."""


def _verify_sig(pubkey_b64: str, sig: bytes, payload: bytes) -> bool:
    """True when sig is pubkey's Ed25519 signature over payload. The one
    verifier for the envelope routes (/bundle, /chunk) and the stream lane."""
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        Ed25519PublicKey.from_public_bytes(base64.b64decode(pubkey_b64)).verify(sig, payload)
        return True
    except Exception:  # noqa: BLE001 — any failure is a bad signature
        return False


class Hub(BaseHTTPRequestHandler):
    run_dir: Path = Path(".")
    # Keep-alive: the phone reuses one socket for a window's posts instead of
    # paying a TCP handshake per bundle. A connection idle for `timeout`
    # seconds is dropped so it does not hold a thread across a cut.
    protocol_version = "HTTP/1.1"
    timeout = 60

    def log_message(self, fmt, *args):  # quiet by default; the runner logs
        sys.stderr.write("hub %s - %s\n" % (self.address_string(), fmt % args))

    def handle(self):
        # One line at open and one at close per connection, on the same
        # channel as the request lines, so the hub log shows how many
        # requests each socket carried.
        self._requests = 0
        peer = "%s:%d" % self.client_address[:2]
        sys.stderr.write("hub conn %s open\n" % peer)
        try:
            super().handle()
        finally:
            sys.stderr.write("hub conn %s closed after %d requests\n" % (peer, self._requests))

    def handle_one_request(self):
        self.raw_requestline = b""
        super().handle_one_request()
        if self.raw_requestline:  # empty at EOF or after a read timeout
            self._requests += 1

    def _send(self, code: int, body: bytes = b"", ctype: str = "text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if self.close_connection:
            # Set by _refuse and the 413 paths: say so, so the client opens a
            # fresh socket for its next request instead of writing into one
            # the hub is about to close.
            self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path, _, query = self.path.partition("?")
        if path == "/job":
            job = self.run_dir / "job.json"
            done = self.run_dir / "job.done"
            if not job.exists() or done.exists():
                self._send(204)
                return
            self._send(200, job.read_bytes(), "application/json")
            return
        if path.startswith("/go/"):
            run = path[len("/go/"):]
            job = self._job()
            if job and job.get("run") == run and (self.run_dir / "go_phone").exists():
                self._send(200, b"go\n")
            else:
                self._send(404, b"not yet\n")
            return
        if path == "/health":
            self._send(200, b"ok\n")
            return
        if path == "/have":
            self._have(query)
            return
        self._send(404, b"no such path\n")

    def _read_body(self, limit: int | None = None) -> bytes:
        # dart:io's HttpClient streams a written body as Transfer-Encoding:
        # chunked (no Content-Length) unless the caller sets contentLength;
        # BaseHTTPRequestHandler does not decode chunks — the first rig run
        # logged two reports as 400 "bad json" from an empty read.
        # With a limit, a body that would exceed it raises BodyTooLarge: a
        # declared Content-Length over the limit is refused before any read,
        # a chunked body the moment its running total passes it.
        encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in encoding:
            chunks = []
            total = 0
            while True:
                size_line = self.rfile.readline().strip()
                if not size_line:
                    break
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    while self.rfile.readline().strip():
                        pass  # trailers
                    break
                total += size
                if limit is not None and total > limit:
                    raise BodyTooLarge()
                chunks.append(self.rfile.read(size))
                self.rfile.readline()  # the CRLF after each chunk
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length") or 0)
        if limit is not None and length > limit:
            raise BodyTooLarge()
        return self.rfile.read(length) if length > 0 else b""

    def _verify_envelope(self, raw: bytes):
        """Parse the peer's JSON envelope {run,id,created_ms,payload,sig,pubkey}
        and verify the Ed25519 signature against the boot event's public key.
        Returns (env, payload, sig_ok, pubkey_match); raises BadBundle when the
        bytes are not an envelope. Shared by /bundle and the /chunk completion."""
        try:
            env = json.loads(raw.decode("utf-8"))
            payload = base64.b64decode(env["payload"])
            sig = base64.b64decode(env["sig"])
            pubkey_b64 = str(env["pubkey"])
            bundle_id = str(env["id"])
            int(env["created_ms"])
        except (ValueError, KeyError, TypeError):
            raise BadBundle("bad bundle")
        if not SAFE_NAME.fullmatch(bundle_id):
            raise BadBundle("bad id")
        return env, payload, _verify_sig(pubkey_b64, sig, payload), self._pubkey_match(pubkey_b64)

    @classmethod
    def _pubkey_match(cls, pubkey_b64: str) -> bool:
        """True when pubkey_b64 is the key the peer's boot event registered."""
        stored = cls.run_dir / "peer_pubkey.b64"
        return stored.exists() and stored.read_text().strip() == pubkey_b64

    @classmethod
    def _bundle_event(cls, env: dict, payload: bytes, sig_ok: bool, pubkey_match: bool,
                      chunks: int | None = None) -> dict:
        """Write blobs/bundle-<id>.bin and build the `bundle_received` event
        with the latency since the bundle was created (the peer's clock) — the
        number the blackout row reports in hours. The caller appends it."""
        bundle_id = str(env["id"])
        created_ms = int(env["created_ms"])
        received_ms = int(time.time() * 1000)
        blobs = cls.run_dir / "blobs"
        blobs.mkdir(exist_ok=True)
        (blobs / f"bundle-{bundle_id}.bin").write_bytes(payload)
        event = {
            "event": "bundle_received",
            "run": env.get("run"),
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "id": bundle_id,
            "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "sig_ok": sig_ok,
            "pubkey_match": pubkey_match,
            "created_ms": created_ms,
            "received_ms": received_ms,
            "latency_s": round((received_ms - created_ms) / 1000, 1),
        }
        if chunks is not None:
            event["chunks"] = chunks
        return event

    @classmethod
    def _append_event(cls, event: dict) -> None:
        # Call with _lock held.
        with (cls.run_dir / "phone_events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")

    @staticmethod
    def _verdict(prefix: str, sig_ok: bool, pubkey_match: bool) -> bytes:
        return f"{prefix} sig_ok={str(sig_ok).lower()} pubkey_match={str(pubkey_match).lower()}\n".encode()

    def _bundle(self, raw: bytes) -> None:
        """A signed store-and-forward bundle from the peer in one post: verify,
        keep the bytes, append one `bundle_received` event."""
        try:
            env, payload, sig_ok, pubkey_match = self._verify_envelope(raw)
        except BadBundle as e:
            self._send(400, f"{e}\n".encode())
            return
        event = self._bundle_event(env, payload, sig_ok, pubkey_match)
        with self._lock:
            self._append_event(event)
        self._send(200, self._verdict("ok", sig_ok, pubkey_match))

    def do_POST(self):  # noqa: N802
        path, _, query = self.path.partition("?")
        if path == "/blob":
            self._blob(query)
            return
        if path == "/chunk":
            self._chunk(query)
            return
        if path == "/bundle":
            try:
                raw = self._read_body(BLOB_MAX_BYTES)
            except BodyTooLarge:
                self._refuse(413, b"too large\n")
                return
            self._bundle(raw)
            return
        if path != "/report":
            # Drain the body and close: an unread body would be parsed
            # as the next request on a kept-alive socket.
            self._refuse(404, b"no such path\n")
            return
        raw = self._read_body()
        try:
            event = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send(400, b"bad json\n")
            return
        if event.get("event") == "boot" and isinstance(event.get("pubkey"), str):
            (self.run_dir / "peer_pubkey.b64").write_text(event["pubkey"] + "\n")
        line = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
        with self._lock:
            with (self.run_dir / "phone_events.jsonl").open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        if event.get("event") in ("ended", "failed"):
            (self.run_dir / "job.done").write_text(event.get("event", "") + "\n")
        self._send(200, b"ok\n")

    # One lock for the blob directory and the events file: the peer may post
    # two blobs at once, and a retry of the same blob may overlap the first.
    _lock = threading.Lock()

    def _drain(self):
        # Read and discard the body (bounded) so the peer sees the status
        # instead of a reset socket while it is still writing.
        try:
            self._read_body(BLOB_MAX_BYTES)
        except (BodyTooLarge, ValueError, OSError):
            pass

    def _refuse(self, code: int, body: bytes):
        self._drain()
        self.close_connection = True
        self._send(code, body)

    def _blob(self, query: str):
        q = {k: v[0] for k, v in parse_qs(query, keep_blank_values=True).items()}
        run = q.get("run", "")
        kind = q.get("kind", "")
        item = q.get("id", "")
        sha = q.get("sha256", "").lower()
        job = self._job()
        if not job or job.get("run") != run:
            self._refuse(409, b"wrong run\n")
            return
        if not SAFE_NAME.match(kind) or not SAFE_NAME.match(item):
            self._refuse(400, b"bad kind or id\n")
            return
        if not SHA256_HEX.match(sha):
            self._refuse(400, b"bad sha256\n")
            return
        try:
            body = self._read_body(BLOB_MAX_BYTES)
        except BodyTooLarge:
            self.close_connection = True
            self._send(413, b"too large\n")
            return
        except ValueError:
            self.close_connection = True
            self._send(400, b"bad chunked body\n")
            return
        if hashlib.sha256(body).hexdigest() != sha:
            self._send(409, b"sha mismatch\n")
            return
        blobs = self.run_dir / "blobs"
        blobs.mkdir(parents=True, exist_ok=True)
        dest = blobs / ("%s-%s.bin" % (kind, item))
        with self._lock:
            if dest.exists():
                if hashlib.sha256(dest.read_bytes()).hexdigest() != sha:
                    self._send(409, b"blob exists with a different sha\n")
                    return
                self._send(200, b"ok\n")  # the same bytes again: idempotent
                return
            tmp = blobs / (".%s-%s.%d.%d.tmp" % (kind, item, os.getpid(), threading.get_ident()))
            tmp.write_bytes(body)
            os.replace(tmp, dest)
            event = {
                "event": "blob",
                "run": run,
                "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
                "kind": kind,
                "id": item,
                "bytes": len(body),
                "sha256": sha,
            }
            line = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
            with (self.run_dir / "phone_events.jsonl").open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        self._send(200, b"ok\n")

    # ---- bundles sent in pieces: chunks/<id>/{meta.json, <idx>.bin, complete.json}
    # meta.json {n, sha256} is claimed by the first piece under the lock, so a
    # later piece naming a different sha or n is refused before its body is
    # read. complete.json {sig_ok, pubkey_match} exists once the joined
    # envelope was verified and logged; it makes completion idempotent.

    def _chunk_dir(self, bundle_id: str) -> Path:
        return self.run_dir / "chunks" / bundle_id

    @staticmethod
    def _read_json(path: Path):
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return None

    def _chunk_state(self, cdir: Path):
        """(sorted stored indexes, meta or None, completion or None). Call with
        _lock held: a stat, a directory listing and two small reads."""
        have = sorted(int(p.stem) for p in cdir.glob("*.bin") if p.stem.isdigit()) if cdir.is_dir() else []
        return have, self._read_json(cdir / "meta.json"), self._read_json(cdir / "complete.json")

    def _have(self, query: str):
        q = {k: v[0] for k, v in parse_qs(query, keep_blank_values=True).items()}
        bundle_id = q.get("id", "")
        if not SAFE_NAME.fullmatch(bundle_id):
            self._send(400, b"bad id\n")
            return
        with self._lock:
            have, meta, done = self._chunk_state(self._chunk_dir(bundle_id))
        body = {"id": bundle_id, "have": have, "n": meta["n"] if meta else None,
                "complete": done is not None}
        self._send(200, json.dumps(body, separators=(",", ":")).encode(), "application/json")

    def _chunk(self, query: str):
        q = {k: v[0] for k, v in parse_qs(query, keep_blank_values=True).items()}
        bundle_id = q.get("id", "")
        sha = q.get("sha256", "").lower()
        try:
            idx = int(q.get("idx", ""))
            n = int(q.get("n", ""))
        except ValueError:
            self._refuse(400, b"bad idx or n\n")
            return
        if not SAFE_NAME.fullmatch(bundle_id):
            self._refuse(400, b"bad id\n")
            return
        if not SHA256_HEX.fullmatch(sha):
            self._refuse(400, b"bad sha256\n")
            return
        if not 1 <= n <= CHUNK_MAX_N or not 0 <= idx < n:
            self._refuse(400, b"idx or n out of range\n")
            return
        cdir = self._chunk_dir(bundle_id)
        with self._lock:
            have, meta, done = self._chunk_state(cdir)
            if meta is None:
                cdir.mkdir(parents=True, exist_ok=True)
                meta = {"n": n, "sha256": sha}
                (cdir / "meta.json").write_text(json.dumps(meta))
        if meta.get("sha256") != sha or meta.get("n") != n:
            self._refuse(409, b"chunk names a different sha or n for this id\n")
            return
        if done is not None:
            self._drain()  # already joined and logged: repeat the verdict, no second event
            self._send(200, self._verdict("complete", done["sig_ok"], done["pubkey_match"]))
            return
        try:
            body = self._read_body(CHUNK_MAX_BYTES)
        except BodyTooLarge:
            self.close_connection = True
            self._send(413, b"too large\n")
            return
        except ValueError:
            self.close_connection = True
            self._send(400, b"bad chunked body\n")
            return
        if not body:
            self._send(400, b"empty chunk\n")
            return
        # The piece lands outside the lock: a tmp file, then an atomic rename,
        # so a duplicate in flight at the same time ends with the same bytes
        # and no other request waits on this disk write.
        tmp = cdir / (".%d.%d.%d.tmp" % (idx, os.getpid(), threading.get_ident()))
        tmp.write_bytes(body)
        os.replace(tmp, cdir / f"{idx}.bin")
        with self._lock:
            have, meta, done = self._chunk_state(cdir)
            if done is not None:
                self._send(200, self._verdict("complete", done["sig_ok"], done["pubkey_match"]))
                return
            if not set(range(n)).issubset(have):
                self._send(200, b"ok\n")
                return
            # All pieces present. Join, check the WHOLE against the query sha
            # before parsing anything, then verify exactly as /bundle does.
            raw = b"".join((cdir / f"{i}.bin").read_bytes() for i in range(n))
            if hashlib.sha256(raw).hexdigest() != sha:
                self._send(409, b"sha mismatch\n")
                return
            try:
                env, payload, sig_ok, pubkey_match = self._verify_envelope(raw)
            except BadBundle as e:
                self._send(400, f"{e}\n".encode())
                return
            if str(env["id"]) != bundle_id:
                self._send(400, b"envelope id differs from the query id\n")
                return
            self._append_event(self._bundle_event(env, payload, sig_ok, pubkey_match, chunks=n))
            done = {"sig_ok": sig_ok, "pubkey_match": pubkey_match}
            (cdir / "complete.json").write_text(json.dumps(done))
        self._send(200, self._verdict("complete", sig_ok, pubkey_match))

    @classmethod
    def _job(cls):
        job = cls.run_dir / "job.json"
        if not job.exists():
            return None
        try:
            return json.loads(job.read_text())
        except ValueError:
            return None
    # ---- stream lane storage: stream/<id>.part, <id>.meta.json, <id>.complete.json
    # meta.json {total, sig, created_ms, run} is claimed by the first header
    # under the lock; a later header for the id must match it. complete.json
    # {sig_ok, pubkey_match, bytes} exists once the .part was verified and
    # logged; it makes completion idempotent (a re-asked done, no second
    # event). _stream_gen is bumped by every accepted hello: a session whose
    # gen is older is preempted before its next append, so one writer owns
    # a .part at a time.
    _stream_gen = 0
    _stream_stats = {"bytes_carried": 0, "records": 0, "connections": 0}

    @classmethod
    def _stream_dir(cls) -> Path:
        return cls.run_dir / "stream"

    @classmethod
    def _stream_state(cls, bundle_id: str):
        """(have, meta or None, complete or None) for one bundle id: have is
        the .part size, or the recorded total once complete. Call with _lock
        held."""
        sdir = cls._stream_dir()
        meta = cls._read_json(sdir / f"{bundle_id}.meta.json")
        complete = cls._read_json(sdir / f"{bundle_id}.complete.json")
        if complete is not None:
            return int(complete.get("bytes", 0)), meta, complete
        part = sdir / f"{bundle_id}.part"
        return (part.stat().st_size if part.exists() else 0), meta, None

    @classmethod
    def _stream_complete(cls, bundle_id: str, meta: dict, pubkey_b64: str) -> dict:
        """Verify the finished .part with the hello's key, write the blob,
        append ONE bundle_received event with "stream": true and record
        complete.json. A second call returns the recorded verdict. Call with
        _lock held."""
        sdir = cls._stream_dir()
        done_path = sdir / f"{bundle_id}.complete.json"
        done = cls._read_json(done_path)
        if done is not None:
            return done
        part = sdir / f"{bundle_id}.part"
        payload = part.read_bytes() if part.exists() else b""
        sig_ok = _verify_sig(pubkey_b64, base64.b64decode(meta["sig"]), payload)
        pubkey_match = cls._pubkey_match(pubkey_b64)
        env = {"run": meta.get("run"), "id": bundle_id, "created_ms": meta["created_ms"]}
        event = cls._bundle_event(env, payload, sig_ok, pubkey_match)
        event["stream"] = True
        cls._append_event(event)
        done = {"sig_ok": sig_ok, "pubkey_match": pubkey_match, "bytes": len(payload)}
        done_path.write_text(json.dumps(done))
        cls._stream_stats["records"] += 1
        return done

    @classmethod
    def _stream_stats_write(cls) -> None:
        """Rewrite stream_stats.json atomically (a tmp file, then a rename).
        Call with _lock held."""
        stats = dict(cls._stream_stats, updated_ms=int(time.time() * 1000))
        path = cls.run_dir / "stream_stats.json"
        tmp = path.with_name(".stream_stats.%d.%d.tmp" % (os.getpid(), threading.get_ident()))
        tmp.write_text(json.dumps(stats, separators=(",", ":")))
        os.replace(tmp, path)

    @classmethod
    def _stream_stats_load(cls) -> None:
        """Continue the counters of a stream_stats.json left by an earlier
        hub process on the same run dir."""
        stats = cls._read_json(cls.run_dir / "stream_stats.json")
        if isinstance(stats, dict):
            for key in cls._stream_stats:
                cls._stream_stats[key] = int(stats.get(key, 0))



class StreamError(Exception):
    """A protocol violation on the stream lane; args = (code, id or None,
    have or None) — the error line the session sends before it closes."""


class _StreamEof(Exception):
    """The phone closed its side."""


class _StreamSilent(Exception):
    """Nothing arrived for 2 × stall_s."""


class StreamServer(socketserver.ThreadingTCPServer):
    """The stream lane's listener; one StreamSession thread per connection.
    `params` are the lane parameters in force (STREAM_DEFAULTS + argv)."""
    allow_reuse_address = True
    daemon_threads = True
    params: dict = dict(STREAM_DEFAULTS)


class StreamSession(socketserver.StreamRequestHandler):
    """One phone connection on the stream lane (wire in the module
    docstring). Bytes are read into the session's own buffer with a short
    socket timeout, so a timeout is a tick rather than a broken reader: every
    tick checks preemption, silence and a time-based ack. Writes go through
    wfile (unbuffered sendall)."""

    def setup(self):
        super().setup()
        # Every hub line (state, ack, done, error) is a small write. With Nagle
        # it would wait for the phone's ACK of the previous line, and that ACK
        # travels behind the phone's queued data on the shaped pipe — measured
        # 2026-09-05: the phone saw no line for 15 s while this side wrote 14.
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = bytearray()
        self.peer = "%s:%d" % self.client_address[:2]
        self.params = self.server.params
        self.stall_s = float(self.params["stall_s"])
        self.ack_interval_s = float(self.params["ack_interval_s"])
        self.ack_bytes = int(self.params["ack_bytes"])
        self.tick_s = max(0.1, min(1.0, self.stall_s / 2))
        self.gen = None  # set by an accepted hello
        self.run = None
        self.pubkey_b64 = None
        self.last_rx = time.monotonic()
        # the record being written
        self.rec_id = None
        self.have = 0
        self.counted = 0  # bytes of this record already added to the stats
        self.acked = 0  # have at the last ack line
        self.last_ack_t = time.monotonic()
        # the advertised window: rate samples (t_mono, n) per received payload
        # slice, the first-byte time, the cap in force and its range this session
        self.inflight_max = int(self.params["inflight_bytes"])
        self.samples: list[tuple[float, int]] = []
        self.first_rx_t = None
        self.w = min(STREAM_W0, self.inflight_max)
        self.w_min_seen = self.w
        self.w_max_seen = self.w
        self.request.settimeout(self.tick_s)

    def handle(self):
        sys.stderr.write("hub stream %s open\n" % self.peer)
        reason = "eof"
        try:
            if self._hello():
                while True:
                    line = self._read_line()
                    if line is None:
                        break
                    if line.strip():
                        self._record(line)
        except StreamError as e:
            code, bundle_id, have = e.args
            reason = "error %s id=%s have=%s" % (code, bundle_id, have)
            self._send_line({"error": code, "id": bundle_id, "have": have}, best_effort=True)
        except _StreamEof:
            reason = "eof" if self.rec_id is None else "eof mid-record %s have=%d" % (self.rec_id, self.have)
        except _StreamSilent:
            reason = "silent %.0fs" % (2 * self.stall_s)
        except OSError as e:
            reason = "io %s" % e
        finally:
            with Hub._lock:
                self._account()
                if self.gen is not None:
                    Hub._stream_stats_write()
            sys.stderr.write("hub stream %s closed %s w=%d..%d last=%d\n"
                             % (self.peer, reason, self.w_min_seen, self.w_max_seen, self.w))

    # -- reading

    def _recv(self) -> None:
        """Wait for more bytes into buf. A timeout is a tick."""
        while True:
            try:
                data = self.request.recv(65536)
            except TimeoutError:
                self._tick()
                continue
            if not data:
                raise _StreamEof()
            self.buf += data
            self.last_rx = time.monotonic()
            return

    def _tick(self) -> None:
        now = time.monotonic()
        with Hub._lock:
            self._check_gen()
        if now - self.last_rx > 2 * self.stall_s:
            raise _StreamSilent()
        if self.rec_id is not None and self.have > self.acked and now - self.last_ack_t >= self.ack_interval_s:
            self._ack()

    def _check_gen(self) -> None:
        # Call with _lock held.
        if self.gen is not None and Hub._stream_gen != self.gen:
            raise StreamError("preempted", self.rec_id, self.have if self.rec_id else None)

    def _read_line(self) -> bytes | None:
        """One line without its newline; None when the phone closed before a
        full line. More than STREAM_LINE_MAX bytes without a newline →
        line_too_long."""
        while True:
            idx = self.buf.find(b"\n")
            if idx >= 0:
                line = bytes(self.buf[:idx])
                del self.buf[:idx + 1]
                return line
            if len(self.buf) >= STREAM_LINE_MAX:
                raise StreamError("line_too_long", self.rec_id, None)
            try:
                self._recv()
            except _StreamEof:
                return None

    def _take(self, n: int) -> bytes:
        """Up to n payload bytes, waiting for at least one."""
        if not self.buf:
            self._recv()
        k = min(n, len(self.buf))
        out = bytes(self.buf[:k])
        del self.buf[:k]
        return out

    # -- writing

    def _send_line(self, obj: dict, best_effort: bool = False) -> None:
        # A line is small; give it more than one tick so a slow peer window
        # does not turn a send into a timeout.
        self.request.settimeout(max(5.0, 2 * self.stall_s))
        try:
            self.wfile.write(json.dumps(obj, separators=(",", ":")).encode() + b"\n")
        except OSError:
            if not best_effort:
                raise
        finally:
            self.request.settimeout(self.tick_s)

    def _account(self) -> None:
        # Call with _lock held.
        if self.have > self.counted:
            Hub._stream_stats["bytes_carried"] += self.have - self.counted
            self.counted = self.have

    def _ack(self) -> None:
        with Hub._lock:
            self._account()
            Hub._stream_stats_write()
        self.acked = self.have
        self.last_ack_t = time.monotonic()
        self._send_line({"ack": self.rec_id, "have": self.have, "inflight": self._window()})

    def _sample(self, n: int) -> None:
        """One received payload slice of n bytes, for the rate estimate."""
        now = time.monotonic()
        if self.first_rx_t is None:
            self.first_rx_t = now
        self.samples.append((now, n))

    def _window(self) -> int:
        """The phone's inflight cap: a TARGET of rate * STREAM_T_QUEUE_S (never
        below STREAM_W_MIN, never above inflight_max), approached by at most
        STREAM_RAMP_S seconds of link per ack. The ramp limit is the
        load-bearing half — it bounds how much later each acknowledgement can
        arrive than the one before, which is what keeps every one of them
        inside the retransmit timer the previous steps built, so the sender's
        estimate climbs with the window. The rate is a windowed mean over the
        last STREAM_T_MEAS_S (or since the first byte, if less): deterministic,
        and idle time inside the window biases it DOWN, the safe direction."""
        now = time.monotonic()
        cutoff = now - STREAM_T_MEAS_S
        self.samples = [s for s in self.samples if s[0] >= cutoff]
        if self.first_rx_t is None:
            return self.w
        span = min(STREAM_T_MEAS_S, now - self.first_rx_t)
        rate = sum(n for _, n in self.samples) / max(span, 0.05)
        target = max(STREAM_W_MIN, int(rate * STREAM_T_QUEUE_S))
        # STREAM_ACK_MIN keeps the ramp moving when the measured rate is so
        # low that a whole ramp interval of it rounds to nothing.
        step = self.w + max(STREAM_ACK_MIN, int(rate * STREAM_RAMP_S))
        w = min(self.inflight_max, step, target)
        self.w = w
        self.w_min_seen = min(self.w_min_seen, w)
        self.w_max_seen = max(self.w_max_seen, w)
        return w

    @property
    def ack_bytes_eff(self) -> int:
        """Ack every quarter of the window in force (never below
        STREAM_ACK_MIN), so the ramp is clocked by the window itself: a fixed
        8 KiB threshold is forty windows of payload while the window is still
        200 bytes, and the ramp would run at one step per time-based ack
        instead of one per fraction of a window.

        A quarter, not a half, because the sender cannot write again until an
        ack reaches it, and that ack crosses a queue as deep as the window
        itself: acking at a half meant the sender refilled the pipe exactly as
        fast as the pipe drained, so any jitter left it idle — measured at a
        half, the standing queue averaged 1.7 kB against a 4 kB window and the
        window carried 86.5 % of the link instead of the ~97 % the queue model
        predicts."""
        return max(STREAM_ACK_MIN, min(self.ack_bytes, self.w // 4))

    # -- the protocol

    def _hello(self) -> bool:
        line = self._read_line()
        if line is None:
            return False
        try:
            hello = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise StreamError("bad_hello", None, None)
        if not isinstance(hello, dict) or hello.get("v") != STREAM_V:
            raise StreamError("bad_hello", None, None)
        run, pubkey_b64, ids = hello.get("run"), hello.get("pubkey"), hello.get("ids")
        if not (isinstance(run, str) and isinstance(pubkey_b64, str) and isinstance(ids, list)
                and len(ids) <= STREAM_IDS_MAX
                and all(isinstance(i, str) and SAFE_NAME.fullmatch(i) for i in ids)):
            raise StreamError("bad_hello", None, None)
        try:
            if len(base64.b64decode(pubkey_b64, validate=True)) != 32:
                raise ValueError("key length")
        except ValueError:
            raise StreamError("bad_hello", None, None)
        job = Hub._job()
        if not job or job.get("run") != run:
            raise StreamError("wrong_run", None, None)
        self.run, self.pubkey_b64 = run, pubkey_b64
        state = {}
        with Hub._lock:
            Hub._stream_gen += 1
            self.gen = Hub._stream_gen
            Hub._stream_stats["connections"] += 1
            for bundle_id in ids:
                have, _meta, complete = Hub._stream_state(bundle_id)
                if have > 0 or complete is not None:
                    state[bundle_id] = {"have": have, "complete": complete is not None}
            Hub._stream_stats_write()
        reply = {"state": state}
        reply.update({k: self.params[k] for k in STREAM_DEFAULTS})
        # The phone STARTS at the floor link's window and follows the value
        # advertised in every ack/done line, never above inflight_max.
        reply["inflight_max"] = self.inflight_max
        reply["inflight_bytes"] = self.w
        self._send_line(reply)
        sys.stderr.write("hub stream %s hello run=%s ids=%d known=%d gen=%d\n"
                         % (self.peer, run, len(ids), len(state), self.gen))
        return True

    def _record(self, line: bytes) -> None:
        try:
            hdr = json.loads(line.decode("utf-8"))
            bundle_id = hdr["id"]
            off, length, total = int(hdr["off"]), int(hdr["len"]), int(hdr["total"])
            created_ms, sig_b64 = int(hdr["created_ms"]), str(hdr["sig"])
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            raise StreamError("bad_id", None, None)
        if not isinstance(bundle_id, str) or not SAFE_NAME.fullmatch(bundle_id):
            raise StreamError("bad_id", None, None)
        try:
            sig = base64.b64decode(sig_b64, validate=True)
        except ValueError:
            sig = b""
        if len(sig) != 64:
            raise StreamError("bad_sig", bundle_id, None)
        if total < 0 or total > BLOB_MAX_BYTES:
            raise StreamError("too_large", bundle_id, None)
        sdir = Hub._stream_dir()
        with Hub._lock:
            self._check_gen()
            have, meta, _complete = Hub._stream_state(bundle_id)
            if meta is None:
                sdir.mkdir(parents=True, exist_ok=True)
                meta = {"total": total, "sig": sig_b64, "created_ms": created_ms, "run": self.run}
                (sdir / f"{bundle_id}.meta.json").write_text(json.dumps(meta))
        if (meta.get("total") != total or meta.get("created_ms") != created_ms
                or base64.b64decode(str(meta.get("sig", ""))) != sig):
            raise StreamError("meta_mismatch", bundle_id, have)
        if off != have or length < 0 or off + length != total:
            raise StreamError("bad_offset", bundle_id, have)
        self.rec_id, self.have, self.counted, self.acked = bundle_id, have, have, have
        self.last_ack_t = time.monotonic()
        part = sdir / f"{bundle_id}.part"
        remaining = length
        while remaining > 0:
            data = self._take(remaining)
            self._sample(len(data))
            with Hub._lock:
                self._check_gen()
                with part.open("ab") as fh:
                    fh.write(data)
                self.have += len(data)
                # Account every append, not only at ack time: the runner reads
                # stream_stats.json while a record is still open, and a
                # bytes_carried that trails the .part by an ack interval
                # (~2 s of payload) would move those bytes into the next
                # window's baseline and drop them from every window's delta.
                self._account()
                Hub._stream_stats_write()
            remaining -= len(data)
            if (self.have - self.acked >= self.ack_bytes_eff
                    or time.monotonic() - self.last_ack_t >= self.ack_interval_s):
                self._ack()
        if self.have > self.acked:
            self._ack()  # record end
        with Hub._lock:
            self._check_gen()
            self._account()
            done = Hub._stream_complete(bundle_id, meta, self.pubkey_b64)
            Hub._stream_stats_write()
        self._send_line({"done": bundle_id, "sig_ok": done["sig_ok"],
                         "pubkey_match": done["pubkey_match"], "bytes": done["bytes"],
                         "inflight": self._window()})
        sys.stderr.write("hub stream %s done %s bytes=%d sig_ok=%s\n"
                         % (self.peer, bundle_id, done["bytes"], str(done["sig_ok"]).lower()))
        self.rec_id = None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--bind", required=True)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--stream-port", type=int, default=None,
                    help="stream lane port (default --port + 1; 0 = off)")
    ap.add_argument("--stream-stall-s", type=int, default=STREAM_DEFAULTS["stall_s"])
    ap.add_argument("--stream-ack-bytes", type=int, default=STREAM_DEFAULTS["ack_bytes"])
    ap.add_argument("--stream-inflight-bytes", type=int, default=STREAM_DEFAULTS["inflight_bytes"])
    ap.add_argument("--stream-piece-bytes", type=int, default=STREAM_DEFAULTS["piece_bytes"])
    args = ap.parse_args()
    Hub.run_dir = Path(args.dir)
    Hub.run_dir.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((args.bind, args.port), Hub)
    sys.stderr.write("hub serving %s on %s:%d\n" % (Hub.run_dir, args.bind, args.port))
    stream_port = args.port + 1 if args.stream_port is None else args.stream_port
    if stream_port:
        params = dict(STREAM_DEFAULTS)
        params.update(piece_bytes=args.stream_piece_bytes, ack_bytes=args.stream_ack_bytes,
                      inflight_bytes=args.stream_inflight_bytes, stall_s=args.stream_stall_s)
        StreamServer.params = params
        Hub._stream_stats_load()
        stream = StreamServer((args.bind, stream_port), StreamSession)
        threading.Thread(target=stream.serve_forever, daemon=True, name="stream-lane").start()
        sys.stderr.write("hub stream lane on %s:%d %s\n"
                         % (args.bind, stream_port, json.dumps(params, separators=(",", ":"))))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
