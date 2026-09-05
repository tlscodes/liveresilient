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

USAGE  journey_hub.py --bind <addr> --port 8765 --dir <run dir>
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import time
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
CHUNK_MAX_BYTES = 64 * 1024  # one /chunk body
CHUNK_MAX_N = 4096  # pieces per bundle


class BodyTooLarge(Exception):
    """The request body exceeds the limit given to _read_body."""


class BadBundle(Exception):
    """The bytes are not the JSON envelope the peer signs; str() is the reply."""


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
        stored = self.run_dir / "peer_pubkey.b64"
        pubkey_match = stored.exists() and stored.read_text().strip() == pubkey_b64
        sig_ok = False
        try:
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
            Ed25519PublicKey.from_public_bytes(base64.b64decode(pubkey_b64)).verify(sig, payload)
            sig_ok = True
        except Exception:  # noqa: BLE001 — any failure is a bad signature
            sig_ok = False
        return env, payload, sig_ok, pubkey_match

    def _bundle_event(self, env: dict, payload: bytes, sig_ok: bool, pubkey_match: bool,
                      chunks: int | None = None) -> dict:
        """Write blobs/bundle-<id>.bin and build the `bundle_received` event
        with the latency since the bundle was created (the peer's clock) — the
        number the blackout row reports in hours. The caller appends it."""
        bundle_id = str(env["id"])
        created_ms = int(env["created_ms"])
        received_ms = int(time.time() * 1000)
        blobs = self.run_dir / "blobs"
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

    def _append_event(self, event: dict) -> None:
        # Call with _lock held.
        with (self.run_dir / "phone_events.jsonl").open("a", encoding="utf-8") as fh:
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
            self._send(404, b"no such path\n")
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
