#!/usr/bin/env python3
"""Authoritative-style UDP/53 responder. Design §3, §4.

Stateless per query except a bounded reassembly buffer keyed by session id.
EDNS0 advertisement is 1232, never 4096. Incomplete sessions are dropped.

Every table in here is filled by whoever can send a datagram, so every table
is bounded: the reassembly table by session count and by per-source count,
the downstream queue by the same ages a session carries, the completed list
by a fixed maximum. A session also has a maximum AGE, not only an idle
timeout, so a source that touches one every tick cannot hold it open forever.
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
import socket
import threading
import time
from collections import deque

from txt_query_wire import (
    DOWNSTREAM_BUDGET,
    FRAME_HDR,
    POLL_SEQ,
    RCODE_NXDOMAIN,
    SEQ_MAX,
    WireError,
    build_dns_answer_packet,
    frame_down,
    parse_dns_query_packet,
    parse_query_name,
    unframe_up,
)

log = logging.getLogger("txt_query.server")

# RFC 1035 section 4.1.1. The wire module does not define it because nothing
# it builds needed a refusal before the per-source cap below.
RCODE_REFUSED = 5


def _now() -> float:
    """The module's only clock reading, so a test can replace it in one place."""
    return time.monotonic()


class _Buf:
    __slots__ = ("chunks", "created", "last_seen", "source")

    def __init__(self, source: str = "") -> None:
        self.chunks: dict[int, bytes] = {}
        self.created = _now()
        self.last_seen = self.created
        self.source = source


class _Down:
    """Bytes queued for one session, carrying the same two ages a session does."""

    __slots__ = ("data", "created", "last_seen")

    def __init__(self, data: bytes = b"") -> None:
        self.data = data
        self.created = _now()
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
        max_sessions: int = 4096,
        max_sessions_per_source: int = 64,
        max_session_age: float = 300.0,
        max_complete: int = 1024,
    ) -> None:
        self.domain = domain.strip(".").lower()
        self.host = host
        self.port = port
        self.session_ttl = session_ttl
        self.echo = echo
        self.rate_bps = rate_bps
        self.max_sessions = max_sessions
        self.max_sessions_per_source = max_sessions_per_source
        self.max_session_age = max_session_age
        self.max_complete = max_complete
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._sessions: dict[str, _Buf] = {}
        self._per_source: dict[str, int] = {}
        self._down: dict[str, _Down] = {}
        self._complete: "deque[tuple[str, bytes]]" = deque(maxlen=max_complete)
        self._probes: dict[bytes, list[bytes]] = {}
        self.queries_ok = 0
        self.queries_nx = 0
        self.queries_refused = 0

    # Path probe (Dart: TxtLetterProbe). Payload "PRB1" + group(8) + nonce(8);
    # reply "PRB1" + group + FIRST logged nonce of that group + this probe's
    # 1-based rank. The winner is decided by arrival order HERE, in this log.
    PROBE_MAGIC = b"PRB1"
    PROBE_ID = 8
    MAX_PROBE_GROUPS = 4096

    def _probe_reply_locked(self, payload: bytes, source: str) -> bytes | None:
        n = self.PROBE_ID
        if len(payload) != 4 + 2 * n or not payload.startswith(self.PROBE_MAGIC):
            return None
        group, nonce = payload[4:4 + n], payload[4 + n:]
        seen = self._probes.get(group)
        if seen is None:
            if len(self._probes) >= self.MAX_PROBE_GROUPS:
                self._probes.pop(next(iter(self._probes)))
            seen = self._probes[group] = []
        if nonce not in seen:
            seen.append(nonce)
        rank = seen.index(nonce) + 1
        log.info("probe group=%s nonce=%s rank=%d winner=%s source=%s",
                 group.hex(), nonce.hex(), rank, seen[0].hex(), source)
        return self.PROBE_MAGIC + group + seen[0] + bytes([min(rank, 255)])

    def queue_down(self, session: str, payload: bytes) -> None:
        with self._lock:
            self._queue_down_locked(session, payload)

    def _queue_down_locked(self, session: str, payload: bytes) -> None:
        entry = self._down.get(session)
        if entry is None:
            entry = self._down[session] = _Down()
        entry.data += payload
        entry.last_seen = _now()

    def _take_down_locked(self, session: str) -> bytes:
        # Drained means gone: an emptied entry used to stay in the table for
        # the life of the process, one per session id anyone ever sent.
        entry = self._down.pop(session, None)
        return b"" if entry is None else entry.data

    
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
        sock, thread = self._sock, self._thread
        # Close first so a receive already blocked in the loop returns now
        # instead of after its timeout, then join, and only then clear the
        # attributes — clearing them first left the loop calling into None.
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
            if thread.is_alive():
                log.warning("receive thread still running 2 s after stop")
        self._sock = None
        self._thread = None

    def __enter__(self) -> "TxtQueryServer":
        self.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop()

    def _gc(self) -> None:
        now = _now()
        dead = [
            k
            for k, s in self._sessions.items()
            if now - s.last_seen > self.session_ttl
            or now - s.created > self.max_session_age
        ]
        for k in dead:
            self._drop_session(k)
        stale = [
            k
            for k, d in self._down.items()
            if now - d.last_seen > self.session_ttl
            or now - d.created > self.max_session_age
        ]
        for k in stale:
            del self._down[k]

    def _drop_session(self, session_id: str) -> None:
        buf = self._sessions.pop(session_id, None)
        if buf is None:
            return
        left = self._per_source.get(buf.source, 1) - 1
        if left > 0:
            self._per_source[buf.source] = left
        else:
            self._per_source.pop(buf.source, None)

    def _open_session(self, session_id: str, source: str) -> _Buf | None:
        """Allocate a buffer, or None when this source already holds its limit."""
        if self._per_source.get(source, 0) >= self.max_sessions_per_source:
            return None
        if self._sessions and len(self._sessions) >= self.max_sessions:
            oldest = min(self._sessions, key=lambda k: self._sessions[k].created)
            self._drop_session(oldest)
        buf = self._sessions[session_id] = _Buf(source)
        self._per_source[source] = self._per_source.get(source, 0) + 1
        return buf

    def _shape(self, nbytes: int) -> None:
        if not self.rate_bps:
            return
        time.sleep((nbytes * 8) / float(self.rate_bps))

    def _loop(self) -> None:
        sock = self._sock
        if sock is None:
            return
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                # stop() closes the socket under this thread on purpose.
                if self._stop.is_set():
                    return
                continue
            self._shape(len(data))
            try:
                reply = self._handle(data, addr)
            except Exception:
                log.exception("handle")
                continue
            if reply:
                self._shape(len(reply))
                try:
                    sock.sendto(reply, addr)
                except OSError:
                    continue

    def _handle(self, data: bytes, addr: tuple[str, int] | None = None) -> bytes | None:
        try:
            q = parse_dns_query_packet(data)
        except (WireError, ValueError) as exc:
            # A label that is not ASCII raises UnicodeDecodeError out of the
            # name decoder — a ValueError, but not a WireError, so it used to
            # escape this guard and print a traceback for every such datagram.
            log.debug("unparseable query from %s: %s", addr, exc)
            return None
        try:
            parsed = parse_query_name(q.name, self.domain)
        except (WireError, ValueError) as exc:
            log.debug("not a valve name from %s: %s", addr, exc)
            self.queries_nx += 1
            return build_dns_answer_packet(q.txid, q.name, None, rcode=RCODE_NXDOMAIN)

        source = addr[0] if addr else ""
        with self._lock:
            self._gc()
            if parsed.seq != POLL_SEQ:
                buf = self._sessions.get(parsed.session_id)
                if buf is None:
                    buf = self._open_session(parsed.session_id, source)
                    if buf is None:
                        self.queries_refused += 1
                        return build_dns_answer_packet(
                            q.txid, q.name, None, rcode=RCODE_REFUSED
                        )
                buf.chunks[parsed.seq] = parsed.chunk
                buf.last_seen = _now()
                assembled = self._try_assemble(buf)
                if assembled is not None:
                    reply = self._probe_reply_locked(assembled, source)
                    if reply is not None:
                        # A path probe, not a letter: never reaches take_complete.
                        self._queue_down_locked(parsed.session_id, reply)
                    else:
                        self._complete.append((parsed.session_id, assembled))
                        if self.echo:
                            self._queue_down_locked(parsed.session_id, assembled)
                    self._drop_session(parsed.session_id)
            # POLL_SEQ falls through: a poll reads the queue and stores
            # nothing, so it can neither overwrite chunk 0 nor open a session.
            self.queries_ok += 1
            down = self._take_down_locked(parsed.session_id)

        if len(down) > DOWNSTREAM_BUDGET:
            leftover = down[DOWNSTREAM_BUDGET:]
            down = down[:DOWNSTREAM_BUDGET]
            with self._lock:
                rest = self._take_down_locked(parsed.session_id)
                self._down[parsed.session_id] = _Down(leftover + rest)
        return build_dns_answer_packet(q.txid, q.name, frame_down(down))

    def _try_assemble(self, buf: _Buf) -> bytes | None:
        head = buf.chunks.get(0)
        if head is None or len(head) < FRAME_HDR:
            return None
        need = FRAME_HDR + int.from_bytes(head[:FRAME_HDR], "big")
        # Assemble from the PREFIX, and stop at `need`. Requiring every seq up
        # to max(chunks) let one spoofed high-seq chunk stall a session whose
        # own chunks had all arrived; chunks past `need` are not this payload.
        parts: list[bytes] = []
        have = 0
        for i in range(SEQ_MAX + 1):
            if have >= need:
                break
            chunk = buf.chunks.get(i)
            if chunk is None:
                return None
            parts.append(chunk)
            have += len(chunk)
        if have < need:
            return None
        try:
            return unframe_up(b"".join(parts)[:need])
        except WireError:
            return None


def complete_line(session: str, payload: bytes) -> str:
    """The one line that says THIS responder assembled THESE bytes.

    Both fields are printed because both are matched: the session id ties the
    line to one message from one sender, the digest ties it to the payload the
    sender says it sent. A digest on its own would be satisfied by a line from
    an earlier run of the same fixture, which is not evidence of this run.
    """
    return "complete session=%s bytes=%d sha256=%s" % (
        session,
        len(payload),
        hashlib.sha256(payload).hexdigest(),
    )


def letter_path(letter_dir: str, session: str) -> str:
    """Where the assembled payload is kept for a reader, named by session.

    The session id came off the wire, so it is reduced to [A-Za-z0-9_-] before
    it becomes a file name: nothing a sender chooses can name a path outside
    the directory.
    """
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session)[:64] or "session"
    return os.path.join(letter_dir, safe + ".letter")


def write_letter(letter_dir: str, session: str, payload: bytes) -> str:
    """Write the payload this responder assembled, byte for byte.

    The `complete` line proves the carriage to the row builder; this file is
    for the person at the Mac, who wants to read the letter, not its digest.
    Bytes, not text: the responder does not know the encoding, the reader does.
    """
    path = letter_path(letter_dir, session)
    os.makedirs(letter_dir, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(payload)
    return path


# One collector for the responder's life: the parts of up to ten letters in a
# row (letter_parts.py, mirrored by the app's letter_parts.dart). The cap per
# letter is untouched; each part is an ordinary letter under it.
_PARTS = None


def parts_collector():
    global _PARTS
    if _PARTS is None:
        from letter_parts import LetterPartsCollector
        _PARTS = LetterPartsCollector(deadline_s=600.0)
    return _PARTS


def drain_complete(srv: TxtQueryServer, letter_dir: str | None = None) -> int:
    """Log every payload assembled since the last call; return how many.

    With `letter_dir` each payload is also written there (see write_letter).

    `take_complete()` empties the mailbox as it reads it, so one payload can
    never be logged twice — two lines for one message would read downstream as
    two carriages. Until this loop existed nothing drained that mailbox, so an
    assembled payload left no trace anywhere.
    """
    from letter_parts import id_hex, parse_part
    drained = 0
    col = parts_collector()
    for session, payload in srv.take_complete():
        log.info("%s", complete_line(session, payload))
        # A probe is an empty session the responder completes like any other
        # (the fabric's refresh() sends one before every ranking); it is not
        # a letter, so it leaves the log line and no file.
        if letter_dir and payload:
            log.info("letter session=%s written=%s", session,
                     write_letter(letter_dir, session, payload))
        drained += 1
        # A part of a larger letter (letter_parts.py): keep it; once the last
        # one lands, log the WHOLE exactly like a session — id = the letter's
        # 8-hex id, bytes and sha256 of the whole — and write <idhex>.letter,
        # so journey_run.sh and the row builder find it under the id the
        # phone reports with no change of their own. A group that never
        # completes is logged incomplete after its deadline, never raised.
        part = parse_part(payload) if payload else None
        if part is not None:
            log.info("part id=%s index=%d/%d bytes=%d session=%s",
                     id_hex(part.id), part.index + 1, part.total, len(payload), session)
            whole = col.observe(payload)
            if whole is not None:
                lid, data = whole
                log.info("%s", complete_line(id_hex(lid), data))
                if letter_dir:
                    log.info("letter session=%s written=%s parts=%d", id_hex(lid),
                             write_letter(letter_dir, id_hex(lid), data), part.total)
            elif col.failed and col.failed[-1] == part.id:
                log.info("parts id=%s digest mismatch: dropped", id_hex(part.id))
    for lid, got, total, missing in col.expired():
        log.info("parts id=%s incomplete after deadline: %d/%d, missing %s",
                 id_hex(lid), got, total, missing)
    return drained


def main() -> None:
    import argparse

    p = argparse.ArgumentParser(description="DNS emergency valve authoritative responder")
    p.add_argument("--domain", required=True)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=53)
    p.add_argument("--letter-dir", default=None,
                   help="also write each assembled payload to <dir>/<session>.letter")
    args = p.parse_args()
    # Without a handler every log.info in this module reaches nothing. That —
    # not a silent responder — is why the rig's valve log was empty, and it is
    # why neither the bind line nor a completion could be used as evidence.
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    srv = TxtQueryServer(args.domain, host=args.host, port=args.port, echo=False)
    srv.start()
    try:
        while True:
            drain_complete(srv, args.letter_dir)
            time.sleep(0.5)
    except KeyboardInterrupt:
        srv.stop()
        # A payload assembled in the last half second is still evidence.
        drain_complete(srv, args.letter_dir)


if __name__ == "__main__":
    main()
