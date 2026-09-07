#!/usr/bin/env python3
"""UDP/53 encoder + UP/DOWN state machine. Design §2, §4, §5.

Does not keep hammering a dead resolver. On DOWN emits one structured line
and notifies subscribers so the caller can hand off.
"""

from __future__ import annotations

import logging
import queue
import socket
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from enum import Enum

from txt_query_wire import (
    EDNS0_UDP_SIZE,
    RCODE_NOERROR,
    WireError,
    build_dns_query_packet,
    encode_queries,
    parse_dns_answer_packet,
    unframe_down,
)

log = logging.getLogger("txt_query.client")


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
        self._qid = 0
        self._state = ValveState.UP
        self._callbacks: list[StatusCallback] = [on_status] if on_status else []
        self._events: queue.Queue[StatusEvent] = queue.Queue()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.settimeout(self.timeout_s)
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
        self._sock.close()

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

    def _next_qid(self) -> int:
        self._qid = (self._qid + 1) & 0xFFFF
        if self._qid == 0:
            self._qid = 1
        return self._qid

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
        qid = self._next_qid()
        pkt = build_dns_query_packet(qid, qname)
        self.attempts += 1
        try:
            self._sock.sendto(pkt, self.server)
            while True:
                data, _addr = self._sock.recvfrom(2048)
                try:
                    ans = parse_dns_answer_packet(data)
                except WireError:
                    continue
                if ans.txid != qid:
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

    def send(self, payload: bytes, session: str | None = None) -> tuple[str, bytes]:
        session, names = encode_queries(payload, self.domain, session)
        last = b""
        for qname in names:
            last = self.query_name(qname)
        return session, last

    def poll(self, session: str) -> bytes:
        _, names = encode_queries(b"", self.domain, session)
        return self.query_name(names[0])
