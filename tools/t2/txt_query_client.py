#!/usr/bin/env python3
"""UDP/53 encoder + UP/DOWN state machine. Design §2, §4, §5.

Does not keep hammering a dead resolver. On DOWN emits one structured line
and notifies subscribers so the caller can hand off.
"""

from __future__ import annotations

import logging
import queue
import secrets
import socket
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from enum import Enum

from txt_query_wire import (
    EDNS0_UDP_SIZE,
    POLL_SEQ,
    RCODE_NOERROR,
    WireError,
    build_dns_query_packet,
    build_query_name,
    encode_queries,
    new_nonce,
    parse_dns_answer_packet,
    unframe_down,
)

log = logging.getLogger("txt_query.client")


def _resolve(server: tuple[str, int]) -> tuple[int, tuple]:
    """Resolve the responder once, to one family and one socket address."""
    host, port = server
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
    except socket.gaierror as exc:
        raise ValueError(f"cannot resolve {host!r}") from exc
    if not infos:
        raise ValueError(f"cannot resolve {host!r}")
    family, _stype, _proto, _canon, sockaddr = infos[0]
    return family, sockaddr


def _peer_key(family: int, sockaddr) -> tuple[bytes, int]:
    """A peer's identity: address octets and port, never its spelling.

    A datagram's source address is always the canonical form, so comparing it
    as text would reject a healthy responder configured as
    2001:4860:4860:0:0:0:0:8888 answering from 2001:4860:4860::8888.
    """
    host = sockaddr[0]
    cut = host.find("%")
    if cut >= 0:
        host = host[:cut]
    try:
        packed = socket.inet_pton(family, host)
    except OSError:
        packed = host.encode("utf-8", "replace")
    return packed, sockaddr[1]


def _same_name(got: str | None, want: str) -> bool:
    """DNS names compare case-insensitively, and a trailing dot is not data."""
    if got is None:
        return False
    return got.rstrip(".").lower() == want.rstrip(".").lower()


class ValveState(str, Enum):
    UP = "UP"
    DOWN = "DOWN"


@dataclass(frozen=True)
class StatusEvent:
    state: ValveState
    attempts: int
    replies: int
    up_s: float

    def log_line(self) -> str:
        return (
            f"txt_query state={self.state.value} attempts={self.attempts} "
            f"replies={self.replies} up_s={self.up_s:.1f}"
        )


StatusCallback = Callable[[StatusEvent], None]


class ValveDown(RuntimeError):
    def __init__(self, event: StatusEvent) -> None:
        self.event = event
        self.attempts = event.attempts
        self.replies = event.replies
        self.up_s = event.up_s
        super().__init__(event.log_line())


class TxtQueryClient:
    def __init__(
        self,
        domain: str,
        server: tuple[str, int] = ("127.0.0.1", 53),
        timeout_s: float = 4.0,
        fail_threshold: int = 5,
        fail_window_s: float = 60.0,
        on_status: StatusCallback | None = None,
    ) -> None:
        if timeout_s < 1.0:
            raise ValueError("timeout_s too small")
        self.domain = domain.strip(".").lower()
        self.server = server
        self.timeout_s = timeout_s
        self.fail_threshold = fail_threshold
        self.fail_window_s = fail_window_s
        self.attempts = 0
        self.replies = 0
        self.started_at = time.time()
        self._fail_times: list[float] = []
        self._state = ValveState.UP
        self._callbacks: list[StatusCallback] = [on_status] if on_status else []
        self._events: queue.Queue[StatusEvent] = queue.Queue()
        # Resolved once: every exchange sends to this address and accepts a
        # datagram only from it. The socket itself is opened per exchange, so
        # the source port carries entropy instead of being fixed for the life
        # of the process (RFC 5452 section 9.2).
        self._family, self._server_sockaddr = _resolve(server)
        self._server_key = _peer_key(self._family, self._server_sockaddr)
        self._closed = False
        self._emit(ValveState.UP)

    @property
    def state(self) -> ValveState:
        return self._state

    def on_status(self, cb: StatusCallback) -> None:
        self._callbacks.append(cb)

    def status_stream(self, timeout: float | None = None) -> Iterator[StatusEvent]:
        while True:
            ev = self._events.get(timeout=timeout)
            yield ev
            if ev.state is ValveState.DOWN:
                return

    def close(self) -> None:
        self._closed = True

    def __enter__(self) -> "TxtQueryClient":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def uptime_s(self) -> float:
        return time.time() - self.started_at

    def _event(self, state: ValveState) -> StatusEvent:
        return StatusEvent(state, self.attempts, self.replies, self.uptime_s())

    def _emit(self, state: ValveState) -> StatusEvent:
        ev = self._event(state)
        self._state = state
        self._events.put(ev)
        for cb in self._callbacks:
            cb(ev)
        return ev

    def _record_fail(self) -> None:
        now = time.monotonic()
        self._fail_times.append(now)
        cutoff = now - self.fail_window_s
        self._fail_times = [t for t in self._fail_times if t >= cutoff]
        if len(self._fail_times) >= self.fail_threshold:
            self._declare_down()

    def _declare_down(self) -> None:
        ev = self._emit(ValveState.DOWN)
        print(ev.log_line(), flush=True)
        raise ValveDown(ev)

    def query_name(self, qname: str) -> bytes:
        if self._state is ValveState.DOWN:
            raise ValveDown(self._event(ValveState.DOWN))
        if self._closed:
            raise OSError("client closed")
        # A fresh transaction id from a cryptographic source, and a fresh
        # socket so the source port is drawn again too. A counter plus one
        # port for the life of the process made both fields guessable.
        qid = secrets.randbelow(0x10000)
        pkt = build_dns_query_packet(qid, qname)
        self.attempts += 1
        sock = socket.socket(self._family, socket.SOCK_DGRAM)
        try:
            # One deadline for the whole exchange. A per-datagram timeout is
            # renewed by every arriving datagram, so a trickle of non-matching
            # ones kept this call blocked for as long as the trickle lasted.
            deadline = time.monotonic() + self.timeout_s
            sock.sendto(pkt, self._server_sockaddr)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"no matching answer in {self.timeout_s:.1f}s"
                    )
                sock.settimeout(remaining)
                data, addr = sock.recvfrom(2048)
                if _peer_key(self._family, addr) != self._server_key:
                    continue
                try:
                    ans = parse_dns_answer_packet(data)
                except WireError:
                    continue
                if ans.txid != qid:
                    continue
                # The question name carries the session id and the nonce an
                # off-path sender cannot know. Binding on the 16-bit txid
                # alone accepted a flood, or a late answer to a timed-out
                # query whose id had been reused (RFC 5452 section 9.1).
                if not _same_name(ans.question_name, qname):
                    continue
                if ans.rcode != RCODE_NOERROR or ans.payload is None:
                    raise OSError(f"rcode={ans.rcode}")
                self.replies += 1
                self._fail_times.clear()
                try:
                    return unframe_down(ans.payload)
                except WireError:
                    return ans.payload
        except ValveDown:
            raise
        except (TimeoutError, OSError):
            self._record_fail()
            raise
        finally:
            sock.close()

    def send(self, payload: bytes, session: str | None = None) -> tuple[str, bytes]:
        session, names = encode_queries(payload, self.domain, session)
        last = b""
        for qname in names:
            last = self.query_name(qname)
        return session, last

    def poll(self, session: str) -> bytes:
        """Read the session's pending downstream bytes, storing nothing.

        The query carries seq == POLL_SEQ, which the responder answers
        read-only. The previous poll re-sent sequence 0 with an empty frame,
        which overwrote chunk 0 of a session whose upload was still in flight.
        """
        qname = build_query_name(b"", POLL_SEQ, session, new_nonce(), self.domain)
        return self.query_name(qname)
