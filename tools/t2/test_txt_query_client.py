#!/usr/bin/env python3
"""Answer-acceptance rules of txt_query_client.py, from the 2026-09-13 review.

Stands up a UDP responder in-process and drives the real client against it:
what it accepts, what it must ignore, and how long it is allowed to wait
while ignoring things. No DNS server, no network beyond loopback.

USAGE  python3 tools/t2/test_txt_query_client.py   -> exit 0 on PASS
"""

from __future__ import annotations

import os
import socket
import statistics
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from txt_query_client import TxtQueryClient  # noqa: E402
from txt_query_wire import (  # noqa: E402
    POLL_SEQ,
    WireError,
    build_dns_answer_packet,
    build_query_name,
    frame_down,
    parse_dns_query_packet,
    parse_query_name,
)

DOMAIN = "example.test"
SESSION = "AAAAAA"
OTHER_NAME = "q.AA.ZZZZZZ.ZZZZ.0.tunnel.example.test"
# qdcount 0xffff and a name that points past the buffer: refused by the
# parser, so it exercises the ignore path rather than the txid check.
GARBAGE = b"\xff" * 20
failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    extra = f" {detail}" if detail else ""
    print(f"  {'PASS' if ok else 'FAIL'} {name}{extra}")
    if not ok:
        failures += 1


class Responder(threading.Thread):
    """A one-socket UDP responder whose reply is chosen by `mode`."""

    def __init__(self, mode: str, trickle_s: float = 0.4, trickle_count: int = 6) -> None:
        super().__init__(daemon=True)
        self.mode = mode
        self.trickle_s = trickle_s
        self.trickle_count = trickle_count
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        # A second source address, for the datagram that is correct in every
        # respect except who sent it.
        self.other = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.other.bind(("127.0.0.1", 0))
        self.txids: list[int] = []
        self.src_ports: list[int] = []
        self.names: list[str] = []
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()
        self.join(timeout=2.0)
        self.sock.close()
        self.other.close()

    def _send(self, sock: socket.socket, data: bytes, addr) -> None:
        try:
            sock.sendto(data, addr)
        except OSError:
            pass

    def run(self) -> None:
        while not self._stop.is_set():
            try:
                data, addr = self.sock.recvfrom(2048)
            except (TimeoutError, socket.timeout):
                continue
            except OSError:
                return
            try:
                q = parse_dns_query_packet(data)
            except WireError:
                continue
            self.txids.append(q.txid)
            self.src_ports.append(addr[1])
            self.names.append(q.name)

            if self.mode == "echo":
                self._send(self.sock, build_dns_answer_packet(q.txid, q.name, frame_down(b"ok")), addr)
            elif self.mode == "wrong_name":
                self._send(
                    self.sock,
                    build_dns_answer_packet(q.txid, OTHER_NAME, frame_down(b"spoof")),
                    addr,
                )
            elif self.mode == "other_peer":
                self._send(
                    self.other,
                    build_dns_answer_packet(q.txid, q.name, frame_down(b"spoof")),
                    addr,
                )
            elif self.mode == "trickle":
                for _ in range(self.trickle_count):
                    if self._stop.is_set():
                        break
                    self._send(self.sock, GARBAGE, addr)
                    time.sleep(self.trickle_s)


def client_for(responder: Responder, timeout_s: float = 1.0) -> TxtQueryClient:
    return TxtQueryClient(
        DOMAIN,
        server=("127.0.0.1", responder.port),
        timeout_s=timeout_s,
        fail_threshold=1000,
        fail_window_s=600.0,
    )


def timed_out(cli: TxtQueryClient, qname: str) -> tuple[bool, float, str]:
    t0 = time.monotonic()
    try:
        payload = cli.query_name(qname)
    except TimeoutError:
        return True, time.monotonic() - t0, ""
    except Exception as exc:  # noqa: BLE001 - reported as a failure below
        return False, time.monotonic() - t0, f"{type(exc).__name__}: {exc}"
    return False, time.monotonic() - t0, f"returned {payload!r}"


def case_accepts_a_real_answer() -> None:
    srv = Responder("echo")
    srv.start()
    try:
        with client_for(srv) as cli:
            name = build_query_name(b"", 0, SESSION, "AAAA", DOMAIN)
            check("a real answer is accepted", cli.query_name(name) == b"ok")
    finally:
        srv.stop()


def case_transaction_id_entropy() -> None:
    srv = Responder("echo")
    srv.start()
    try:
        with client_for(srv) as cli:
            for i in range(64):
                cli.query_name(build_query_name(b"", i % 4, SESSION, "AAAA", DOMAIN))
    finally:
        srv.stop()

    ids = srv.txids
    check("64 queries seen by the responder", len(ids) == 64, str(len(ids)))
    runs = sum(1 for a, b in zip(ids, ids[1:]) if b == (a + 1) & 0xFFFF)
    check("txids are not a consecutive run", runs <= 2, f"consecutive pairs={runs}")
    check("txids are distinct", len(set(ids)) >= 60, f"distinct={len(set(ids))}")
    check("txids spread over the space", max(ids) - min(ids) > 10000, f"span={max(ids) - min(ids)}")
    check(
        "txid spread is not clustered",
        statistics.pstdev(ids) > 8000,
        f"stdev={statistics.pstdev(ids):.0f}",
    )
    ports = srv.src_ports
    check("source port drawn per exchange", len(set(ports)) >= 60, f"distinct={len(set(ports))}")


def case_wrong_question_name_is_ignored() -> None:
    srv = Responder("wrong_name")
    srv.start()
    try:
        with client_for(srv) as cli:
            name = build_query_name(b"", 0, SESSION, "AAAA", DOMAIN)
            ok, elapsed, detail = timed_out(cli, name)
            check("right txid, wrong question name is ignored", ok, detail or f"{elapsed:.2f}s")
    finally:
        srv.stop()


def case_other_peer_is_ignored() -> None:
    srv = Responder("other_peer")
    srv.start()
    try:
        with client_for(srv) as cli:
            name = build_query_name(b"", 0, SESSION, "AAAA", DOMAIN)
            ok, elapsed, detail = timed_out(cli, name)
            check("a correct answer from another peer is ignored", ok, detail or f"{elapsed:.2f}s")
    finally:
        srv.stop()


def case_trickle_still_times_out() -> None:
    timeout_s = 1.0
    srv = Responder("trickle", trickle_s=timeout_s / 2, trickle_count=6)
    srv.start()
    try:
        with client_for(srv, timeout_s=timeout_s) as cli:
            name = build_query_name(b"", 0, SESSION, "AAAA", DOMAIN)
            ok, elapsed, detail = timed_out(cli, name)
            check("a trickle of garbage still times out", ok, detail or f"{elapsed:.2f}s")
            # The defect was an unbounded wait: the per-datagram timeout was
            # renewed by every arriving datagram, so the call lasted as long as
            # the trickle did (here 3.0 s) instead of the 1.0 s asked for.
            check(
                "timed out inside its own deadline",
                ok and elapsed < timeout_s * 2,
                f"{elapsed:.2f}s vs timeout_s={timeout_s}",
            )
    finally:
        srv.stop()


def case_poll_carries_poll_seq() -> None:
    srv = Responder("echo")
    srv.start()
    try:
        with client_for(srv) as cli:
            check("poll returns the answer", cli.poll(SESSION) == b"ok")
    finally:
        srv.stop()

    check("poll sent one query", len(srv.names) == 1, str(len(srv.names)))
    if srv.names:
        parsed = parse_query_name(srv.names[0], DOMAIN)
        check("poll query carries POLL_SEQ", parsed.seq == POLL_SEQ, f"seq={parsed.seq}")
        check("poll query keeps the session", parsed.session_id == SESSION.lower(), parsed.session_id)
        check("poll query carries no chunk", parsed.chunk == b"", repr(parsed.chunk))


def main() -> int:
    print("gate_client_answer_acceptance")
    case_accepts_a_real_answer()
    case_transaction_id_entropy()
    case_wrong_question_name_is_ignored()
    case_other_peer_is_ignored()
    case_trickle_still_times_out()
    case_poll_carries_poll_seq()
    print("journey_txt_query_client " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
