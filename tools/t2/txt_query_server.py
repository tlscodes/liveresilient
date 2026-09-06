#!/usr/bin/env python3
"""Authoritative-style UDP/53 responder. Design §3, §4.

Stateless per query except a 60 s reassembly buffer keyed by session id.
EDNS0 advertisement is 1232, never 4096. Incomplete sessions are dropped.
"""

from __future__ import annotations

import logging
import socket
import threading
import time
from collections import defaultdict

from txt_query_wire import (
    DOWNSTREAM_BUDGET,
    FRAME_HDR,
    RCODE_NXDOMAIN,
    WireError,
    build_dns_answer_packet,
    frame_down,
    parse_dns_query_packet,
    parse_query_name,
    unframe_up,
)

log = logging.getLogger("txt_query.server")


class _Buf:
    __slots__ = ("chunks", "created", "last_seen")

    def __init__(self) -> None:
        self.chunks: dict[int, bytes] = {}
        self.created = time.monotonic()
        self.last_seen = self.created


class TxtQueryServer:
    def __init__(
        self,
        domain: str,
        host: str = "127.0.0.1",
        port: int = 53,
        session_ttl: float = 60.0,
        echo: bool = True,
        rate_bps: int | None = None,
    ) -> None:
        self.domain = domain.strip(".").lower()
        self.host = host
        self.port = port
        self.session_ttl = session_ttl
        self.echo = echo
        self.rate_bps = rate_bps
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._sessions: dict[str, _Buf] = {}
        self._down: dict[str, bytes] = defaultdict(bytes)
        self._complete: list[tuple[str, bytes]] = []
        self.queries_ok = 0
        self.queries_nx = 0

    def queue_down(self, session: str, payload: bytes) -> None:
        with self._lock:
            self._down[session] += payload

    
    def live_sessions(self):
        with self._lock:
            self._gc()
            return list(self._sessions.keys())

    def take_complete(self) -> list[tuple[str, bytes]]:
        with self._lock:
            out = list(self._complete)
            self._complete.clear()
            return out

    def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.host, self.port))
        self.port = sock.getsockname()[1]
        sock.settimeout(0.2)
        self._sock = sock
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="dns-valve-auth", daemon=True)
        self._thread.start()
        log.info("udp/%s:%s tunnel.%s", self.host, self.port, self.domain)

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
        self._sock = None
        self._thread = None

    def __enter__(self) -> "TxtQueryServer":
        self.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop()

    def _gc(self) -> None:
        now = time.monotonic()
        dead = [k for k, s in self._sessions.items() if now - s.last_seen > self.session_ttl]
        for k in dead:
            del self._sessions[k]

    def _shape(self, nbytes: int) -> None:
        if not self.rate_bps:
            return
        time.sleep((nbytes * 8) / float(self.rate_bps))

    def _loop(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                if self._stop.is_set():
                    return
                continue
            self._shape(len(data))
            try:
                reply = self._handle(data)
            except Exception:
                log.exception("handle")
                continue
            if reply:
                self._shape(len(reply))
                try:
                    self._sock.sendto(reply, addr)
                except OSError:
                    continue

    def _handle(self, data: bytes) -> bytes | None:
        try:
            q = parse_dns_query_packet(data)
        except WireError:
            return None
        try:
            parsed = parse_query_name(q.name, self.domain)
        except WireError:
            self.queries_nx += 1
            return build_dns_answer_packet(q.txid, q.name, None, rcode=RCODE_NXDOMAIN)

        down = b""
        with self._lock:
            self._gc()
            buf = self._sessions.setdefault(parsed.session_id, _Buf())
            buf.chunks[parsed.seq] = parsed.chunk
            buf.last_seen = time.monotonic()
            assembled = self._try_assemble(buf)
            if assembled is not None:
                self._complete.append((parsed.session_id, assembled))
                if self.echo:
                    self._down[parsed.session_id] += assembled
                del self._sessions[parsed.session_id]
            down = self._down.get(parsed.session_id, b"")
            if down:
                self._down[parsed.session_id] = b""
            self.queries_ok += 1

        if len(down) > DOWNSTREAM_BUDGET:
            leftover = down[DOWNSTREAM_BUDGET:]
            down = down[:DOWNSTREAM_BUDGET]
            with self._lock:
                self._down[parsed.session_id] = leftover + self._down.get(parsed.session_id, b"")
        return build_dns_answer_packet(q.txid, q.name, frame_down(down))

    def _try_assemble(self, buf: _Buf) -> bytes | None:
        if 0 not in buf.chunks or len(buf.chunks[0]) < FRAME_HDR:
            return None
        expected = int.from_bytes(buf.chunks[0][:FRAME_HDR], "big")
        need = FRAME_HDR + expected
        max_seq = max(buf.chunks)
        parts = []
        for i in range(max_seq + 1):
            if i not in buf.chunks:
                return None
            parts.append(buf.chunks[i])
        framed = b"".join(parts)
        if len(framed) < need:
            return None
        try:
            return unframe_up(framed[:need])
        except WireError:
            return None


def main() -> None:
    import argparse

    p = argparse.ArgumentParser(description="DNS emergency valve authoritative responder")
    p.add_argument("--domain", required=True)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=53)
    args = p.parse_args()
    srv = TxtQueryServer(args.domain, host=args.host, port=args.port, echo=False)
    srv.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        srv.stop()


if __name__ == "__main__":
    main()
