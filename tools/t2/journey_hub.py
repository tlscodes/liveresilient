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

Everything is a file in the run directory, which lives inside the Mac app's
sandbox container so the app-journey driver can read the phone's events
directly (see journey_run.sh). No auth, no TLS: bridge100 is a cable.

USAGE  journey_hub.py --bind <addr> --port 8765 --dir <run dir>
"""
from __future__ import annotations

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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

    def _read_body(self) -> bytes:
        # dart:io's HttpClient streams a written body as Transfer-Encoding:
        # chunked (no Content-Length) unless the caller sets contentLength;
        # BaseHTTPRequestHandler does not decode chunks — the first rig run
        # logged two reports as 400 "bad json" from an empty read.
        encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in encoding:
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                if not size_line:
                    break
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    while self.rfile.readline().strip():
                        pass  # trailers
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()  # the CRLF after each chunk
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def do_POST(self):  # noqa: N802
        if self.path != "/report":
            self._send(404, b"no such path\n")
            return
        raw = self._read_body()
        try:
            event = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send(400, b"bad json\n")
            return
        line = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
        with (self.run_dir / "phone_events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        if event.get("event") in ("ended", "failed"):
            (self.run_dir / "job.done").write_text(event.get("event", "") + "\n")
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
