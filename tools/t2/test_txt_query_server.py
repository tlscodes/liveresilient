#!/usr/bin/env python3
"""The authoritative responder's own gate: every table it keeps is bounded.

Nine checks drive `TxtQueryServer._handle` directly with packets built by the
wire module, plus one real socket round trip on 127.0.0.1 and an ephemeral
port. Nothing here binds 53 or any routable address — a responder may be
serving a phone on the rig while this runs.

The clock is replaced through `txt_query_server._now`, the module's single
reading, so the age tests are deterministic instead of sleeping.

Usage: python3 test_txt_query_server.py    (exit 0 = every check passed)
"""

from __future__ import annotations

import hashlib
import logging
import os
import socket
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import txt_query_server as mod  # noqa: E402
from txt_query_server import RCODE_REFUSED, TxtQueryServer  # noqa: E402
from txt_query_wire import (  # noqa: E402
    DOWNSTREAM_BUDGET,
    POLL_SEQ,
    RCODE_NOERROR,
    build_dns_query_packet,
    build_query_name,
    encode_int,
    encode_queries,
    frame_up,
    parse_dns_answer_packet,
    split_chunks,
    unframe_down,
)

DOMAIN = "example.test"
NONCE = "AAAA"
failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    extra = f" {detail}" if detail else ""
    print(f"  {'PASS' if ok else 'FAIL'} {name}{extra}")
    if not ok:
        failures += 1


class FakeClock:
    """A monotonic reading the test moves by hand."""

    def __init__(self, t: float = 1000.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t


class Recorder(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)

    def errors(self) -> list[logging.LogRecord]:
        return [r for r in self.records if r.levelno >= logging.ERROR]


def sid(n: int) -> str:
    return encode_int(n, 6).lower()


def qpacket(chunk: bytes, seq: int, session: str, txid: int = 0x1234) -> bytes:
    return build_dns_query_packet(txid, build_query_name(chunk, seq, session, NONCE, DOMAIN))


def head_of(payload: bytes) -> bytes:
    """Chunk 0 of a payload whose later chunks are never sent."""
    return split_chunks(frame_up(payload))[0]


def answer_payload(reply: bytes | None) -> bytes | None:
    if reply is None:
        return None
    ans = parse_dns_answer_packet(reply)
    if ans.payload is None:
        return None
    return unframe_down(ans.payload)


def with_clock(fn):
    def wrapped() -> None:
        clock = FakeClock()
        real, mod._now = mod._now, clock
        try:
            fn(clock)
        finally:
            mod._now = real

    return wrapped


# ---------------------------------------------------------------- finding 1


@with_clock
def test_session_table_is_capped(clock: FakeClock) -> None:
    srv = TxtQueryServer(
        DOMAIN,
        port=0,
        max_sessions=8,
        max_sessions_per_source=10_000,
        session_ttl=10_000.0,
        max_session_age=100_000.0,
    )
    partial = head_of(b"x" * 100)
    ids = [sid(i) for i in range(108)]
    for i, s in enumerate(ids):
        clock.t += 1.0
        srv._handle(qpacket(partial, 0, s), ("10.0.0.1", 1000 + i))
    live = set(srv.live_sessions())
    check("table capped at max_sessions", len(srv._sessions) <= 8, f"{len(srv._sessions)}")
    check("oldest id evicted", ids[0] not in live, ids[0])
    check("newest ids kept", live == set(ids[-8:]), f"{sorted(live)}")
    check("per-source count tracks evictions", srv._per_source.get("10.0.0.1") == 8,
          str(srv._per_source))


@with_clock
def test_per_source_cap_refuses(clock: FakeClock) -> None:
    srv = TxtQueryServer(DOMAIN, port=0, max_sessions_per_source=3, session_ttl=10_000.0)
    partial = head_of(b"x" * 100)
    for i in range(3):
        clock.t += 1.0
        srv._handle(qpacket(partial, 0, sid(i)), ("9.9.9.9", 5000 + i))
    before = len(srv._sessions)
    reply = srv._handle(qpacket(partial, 0, sid(99)), ("9.9.9.9", 6000))
    rcode = parse_dns_answer_packet(reply).rcode if reply else None
    check("fourth session from one source is REFUSED", rcode == RCODE_REFUSED, str(rcode))
    check("refusal allocates nothing", len(srv._sessions) == before == 3, str(len(srv._sessions)))
    check("refusal counted", srv.queries_refused == 1, str(srv.queries_refused))
    other_port = srv._handle(qpacket(partial, 0, sid(98)), ("9.9.9.9", 7777))
    check(
        "cap keys on address, not port",
        parse_dns_answer_packet(other_port).rcode == RCODE_REFUSED,
        str(parse_dns_answer_packet(other_port).rcode),
    )
    fresh = srv._handle(qpacket(partial, 0, sid(97)), ("9.9.9.8", 5000))
    check(
        "a different source is unaffected",
        parse_dns_answer_packet(fresh).rcode == RCODE_NOERROR,
        str(parse_dns_answer_packet(fresh).rcode),
    )


@with_clock
def test_touched_session_still_ages_out(clock: FakeClock) -> None:
    # Idle eviction can never fire here: session_ttl is 1000 and the session
    # is touched every tick. Only max_session_age can drop it.
    srv = TxtQueryServer(DOMAIN, port=0, session_ttl=1000.0, max_session_age=10.0)
    s = sid(7)
    partial = head_of(b"x" * 100)
    for _ in range(11):
        clock.t += 1.0
        srv._handle(qpacket(partial, 0, s), ("10.0.0.2", 1))
    check("session held while under max_session_age", s in srv._sessions, str(srv.live_sessions()))
    clock.t += 1.0
    srv._handle(qpacket(b"tail", 1, s), ("10.0.0.2", 1))
    held = set(srv._sessions[s].chunks) if s in srv._sessions else set()
    check("aged-out buffer was dropped, not extended", held == {1}, str(sorted(held)))
    check("per-source count did not leak", srv._per_source.get("10.0.0.2") == 1,
          str(srv._per_source))


# ---------------------------------------------------------------- finding 2


def test_prefix_assembly_ignores_a_spoofed_high_chunk() -> None:
    # 1023 is POLL_SEQ now and stores nothing, so the junk chunk rides a high
    # seq that is still storable; the defect is the same either way.
    srv = TxtQueryServer(DOMAIN, port=0, echo=False)
    payload = bytes(range(50))
    chunks = split_chunks(frame_up(payload))
    s = sid(11)
    srv._handle(qpacket(b"junkjunk", 1000, s), ("10.0.0.3", 1))
    srv._handle(qpacket(chunks[0], 0, s), ("10.0.0.3", 1))
    check("still incomplete after chunk 0", srv.take_complete() == [])
    srv._handle(qpacket(chunks[1], 1, s), ("10.0.0.3", 1))
    done = srv.take_complete()
    check("prefix assembles despite the high chunk", done == [(s, payload)], str(done))
    check("completed session is freed", s not in srv._sessions, str(srv.live_sessions()))


# ---------------------------------------------------------------- finding 3


@with_clock
def test_downstream_and_complete_are_bounded(clock: FakeClock) -> None:
    srv = TxtQueryServer(DOMAIN, port=0, session_ttl=30.0, max_session_age=100.0)
    srv.queue_down(sid(21), b"pending")
    check("queued downstream is held", sid(21) in srv._down)
    clock.t += 31.0
    srv.live_sessions()  # runs the collector
    check("downstream entry gone after ttl", sid(21) not in srv._down, str(list(srv._down)))

    small = TxtQueryServer(DOMAIN, port=0, max_complete=4, echo=False)
    for i in range(6):
        payload = bytes([i]) * 20
        small._handle(qpacket(head_of(payload), 0, sid(30 + i)), ("10.0.0.4", 1))
    check("complete list capped", len(small._complete) == 4, str(len(small._complete)))
    taken = small.take_complete()
    check("newest completions kept", [t[0] for t in taken] == [sid(32 + i) for i in range(4)],
          str([t[0] for t in taken]))
    check("take_complete still drains", small.take_complete() == [])


# ---------------------------------------------------------------- finding 4


def test_poll_reads_without_storing() -> None:
    srv = TxtQueryServer(DOMAIN, port=0, echo=False)
    s = sid(41)
    srv.queue_down(s, b"downstream bytes")
    reply = srv._handle(qpacket(b"", POLL_SEQ, s), ("10.0.0.5", 1))
    check("poll returns the queued bytes", answer_payload(reply) == b"downstream bytes",
          repr(answer_payload(reply)))
    check("poll stored no session", srv._sessions == {}, str(srv.live_sessions()))
    check("poll allocated no source slot", srv._per_source == {}, str(srv._per_source))
    again = srv._handle(qpacket(b"", POLL_SEQ, s), ("10.0.0.5", 1))
    check("a drained poll answers empty", answer_payload(again) == b"", repr(answer_payload(again)))

    big = TxtQueryServer(DOMAIN, port=0, echo=False)
    s2 = sid(42)
    big.queue_down(s2, b"A" * (DOWNSTREAM_BUDGET + 10))
    first = answer_payload(big._handle(qpacket(b"", POLL_SEQ, s2), ("10.0.0.5", 1)))
    second = answer_payload(big._handle(qpacket(b"", POLL_SEQ, s2), ("10.0.0.5", 1)))
    check("over-budget answer is cut at the budget", first == b"A" * DOWNSTREAM_BUDGET,
          str(len(first or b"")))
    check("the leftover is kept for the next poll", second == b"A" * 10, str(len(second or b"")))


# ---------------------------------------------------------------- finding 5


def non_ascii_packet() -> bytes:
    header = struct.pack(">HHHHHH", 0x4321, 0x0100, 1, 0, 0, 0)
    labels = [b"\xff\xfe", b"tunnel"] + [p.encode("ascii") for p in DOMAIN.split(".")]
    name = b"".join(bytes([len(lab)]) + lab for lab in labels) + b"\x00"
    return header + name + struct.pack(">HH", 16, 1)


def test_non_ascii_label_is_not_a_traceback(rec: Recorder) -> None:
    srv = TxtQueryServer(DOMAIN, port=0)
    before = len(rec.errors())
    reply = srv._handle(non_ascii_packet(), ("10.0.0.6", 1))
    check("a non-ASCII label is answered with silence", reply is None, repr(reply))
    check("nothing was logged at error level", len(rec.errors()) == before,
          str([r.getMessage() for r in rec.errors()[before:]]))
    check("no session was opened for it", srv._sessions == {})


def test_stop_joins_the_thread(rec: Recorder) -> None:
    before = len(rec.errors())
    srv = TxtQueryServer(DOMAIN, host="127.0.0.1", port=0)
    srv.start()
    thread = srv._thread
    check("bound to an ephemeral port, never 53", srv.port not in (0, 53), str(srv.port))
    srv.stop()
    check("receive thread is gone", thread is not None and not thread.is_alive())
    check("socket handle cleared", srv._sock is None and srv._thread is None)
    check("closing under the loop logged no error", len(rec.errors()) == before,
          str([r.getMessage() for r in rec.errors()[before:]]))


def test_echo_round_trip_over_udp() -> None:
    payload = bytes(range(96))
    with TxtQueryServer(DOMAIN, host="127.0.0.1", port=0, echo=True) as srv:
        session, names = encode_queries(payload, DOMAIN)
        got: bytes | None = None
        cli = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cli.settimeout(3.0)
        try:
            for i, name in enumerate(names):
                cli.sendto(build_dns_query_packet(0x7000 + i, name), ("127.0.0.1", srv.port))
                got = unframe_down(parse_dns_answer_packet(cli.recvfrom(4096)[0]).payload)
        finally:
            cli.close()
        check("multi-chunk payload", len(names) > 1, str(len(names)))
        check("echo answers the payload bytes", got == payload, str(len(got or b"")))
        check("session freed after completion", srv.live_sessions() == [], str(srv.live_sessions()))
        check("completion recorded once",
              srv.take_complete() == [(session.lower(), payload)])


# ------------------------------------------------- the carriage evidence line


def test_completion_line_is_written_by_the_idle_loop(rec: Recorder) -> None:
    """The Mac-side half of the carriage proof: the text, and who writes it.

    The literal string is spelled out here rather than derived from the
    function under test, because tools/t2/journey_dnsvalve_rows.py parses these
    three fields by name. A reworded line would still look correct in a log and
    would silently turn every dnsvalve row into `no_responder_line`.
    """
    srv = TxtQueryServer(DOMAIN, port=0, echo=False)
    payload = bytes(range(50))
    chunks = split_chunks(frame_up(payload))
    s = sid(12)
    for seq, chunk in enumerate(chunks):
        srv._handle(qpacket(chunk, seq, s), ("10.0.0.6", 1))
    expected = "complete session=%s bytes=%d sha256=%s" % (
        s,
        len(payload),
        hashlib.sha256(payload).hexdigest(),
    )
    rendered = mod.complete_line(s, payload)
    check("complete_line renders what the row-builder parses",
          rendered == expected, rendered)

    before = len(rec.records)
    drained = mod.drain_complete(srv)
    logged = [r.getMessage() for r in rec.records[before:]]
    check("the idle loop's drain logs the assembled payload",
          drained == 1 and logged == [expected], f"{drained} {logged}")
    # Twice-logged is twice-counted downstream: one message must never look
    # like two carriages, so the drain has to leave the mailbox empty.
    check("the drain emptied the mailbox", srv.take_complete() == [])
    before = len(rec.records)
    check("a second drain logs nothing",
          mod.drain_complete(srv) == 0 and rec.records[before:] == [])


def test_letter_is_written_where_asked(rec: Recorder) -> None:
    """The reader's half: the assembled bytes land in --letter-dir as sent."""
    import tempfile

    srv = TxtQueryServer(DOMAIN, port=0, echo=False)
    payload = "قرار تماس ۱۸:۳۰ به وقت تهران — session UL7V62".encode("utf-8")
    s = sid(12)
    for seq, chunk in enumerate(split_chunks(frame_up(payload))):
        srv._handle(qpacket(chunk, seq, s), ("10.0.0.6", 1))
    # The probe the fabric sends before every ranking: an empty session the
    # responder completes like any other. On the rig it appeared beside the
    # letter as `complete session=dp4xrl bytes=0` — a log line, not a letter.
    probe = sid(12)
    for seq, chunk in enumerate(split_chunks(frame_up(b""))):
        srv._handle(qpacket(chunk, seq, probe), ("10.0.0.6", 1))
    with tempfile.TemporaryDirectory() as d:
        check("the drain logs the letter and the probe", mod.drain_complete(srv, d) == 2)
        files = [f for f in os.listdir(d) if f.endswith(".letter")]
        check("one file, named by the letter's session, none for the probe",
              len(files) == 1, str(files))
        with open(os.path.join(d, files[0]), "rb") as fh:
            got = fh.read()
        check("the letter is the payload, byte for byte", got == payload, repr(got[:40]))
        crooked = mod.letter_path(d, "../../etc/x")
        check("a wire-chosen session id cannot name a path outside the directory",
              os.path.dirname(crooked) == d and ".." not in os.path.basename(crooked),
              crooked)
    # The default path is unchanged: no directory, no file, no "written=" line —
    # the row builder's `complete` line stays the only thing this drain logs.
    plain = TxtQueryServer(DOMAIN, port=0, echo=False)
    t = sid(12)
    for seq, chunk in enumerate(split_chunks(frame_up(payload))):
        plain._handle(qpacket(chunk, seq, t), ("10.0.0.7", 1))
    before = len(rec.records)
    drained = mod.drain_complete(plain)
    logged = [r.getMessage() for r in rec.records[before:]]
    check("without a directory the drain logs the complete line and nothing about a file",
          drained == 1 and len(logged) == 1 and logged[0].startswith("complete session=")
          and "written=" not in logged[0], str(logged))


def main() -> int:
    print("gate_txt_query_server")
    rec = Recorder()
    mod.log.addHandler(rec)
    mod.log.setLevel(logging.DEBUG)
    try:
        test_session_table_is_capped()
        test_per_source_cap_refuses()
        test_touched_session_still_ages_out()
        test_prefix_assembly_ignores_a_spoofed_high_chunk()
        test_downstream_and_complete_are_bounded()
        test_poll_reads_without_storing()
        test_non_ascii_label_is_not_a_traceback(rec)
        test_stop_joins_the_thread(rec)
        test_echo_round_trip_over_udp()
        test_completion_line_is_written_by_the_idle_loop(rec)
        test_letter_is_written_where_asked(rec)
    finally:
        mod.log.removeHandler(rec)
    check("no traceback was logged by any check", rec.errors() == [],
          str([r.getMessage() for r in rec.errors()]))
    print("journey_txt_query_server " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
