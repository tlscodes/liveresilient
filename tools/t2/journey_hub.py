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

Everything is a file in the run directory, which lives inside the Mac app's
sandbox container so the app-journey driver can read the phone's events
directly (see journey_run.sh). No auth, no TLS: bridge100 is a cable.

USAGE  journey_hub.py --bind <addr> --port 8765 --dir <run dir>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

BLOB_MAX_BYTES = 16 * 1024 * 1024
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


class BodyTooLarge(Exception):
    """The request body exceeds the limit given to _read_body."""


class Hub(BaseHTTPRequestHandler):
    run_dir: Path = Path(".")

    def log_message(self, fmt, *args):  # quiet by default; the runner logs
        sys.stderr.write("hub %s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: bytes = b"", ctype: str = "text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
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

    def do_POST(self):  # noqa: N802
        path, _, query = self.path.partition("?")
        if path == "/blob":
            self._blob(query)
            return
        if path != "/report":
            self._send(404, b"no such path\n")
            return
        raw = self._read_body()
        try:
            event = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send(400, b"bad json\n")
            return
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

    def _refuse(self, code: int, body: bytes):
        # Drain the body first (bounded) so the peer sees the status instead
        # of a reset socket while it is still writing; then close.
        try:
            self._read_body(BLOB_MAX_BYTES)
        except (BodyTooLarge, ValueError, OSError):
            pass
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

    def _job(self):
        job = self.run_dir / "job.json"
        if not job.exists():
            return None
        try:
            return json.loads(job.read_text())
        except ValueError:
            return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--bind", required=True)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--dir", required=True)
    args = ap.parse_args()
    Hub.run_dir = Path(args.dir)
    Hub.run_dir.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((args.bind, args.port), Hub)
    sys.stderr.write("hub serving %s on %s:%d\n" % (Hub.run_dir, args.bind, args.port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
