#!/usr/bin/env python3
"""txt_query_sidecar.py — the local UDP face of TxtQueryClient.

The valve client is Python and stays Python; the Dart lane
(packages/adaptive_transport/lib/src/resilient/txt_query_lane.dart) talks to
this service on the loopback interface instead of re-implementing the DNS wire
format.

Protocol, one datagram each way:
  request   the payload bytes to carry (empty = liveness poll only)
  reply     0x01 + the bytes that came back, or 0x00 when the valve is DOWN

A DOWN reply is terminal for the valve: the client refuses further queries, so
the sidecar keeps answering 0x00 and the Dart side falls to the next lane.

USAGE  python3 txt_query_sidecar.py <domain> [--valve host:port]
                                    [--bind 127.0.0.1:5355]
"""

from __future__ import annotations

import argparse
import socket
import sys

from txt_query_client import TxtQueryClient, ValveDown

UP = b"\x01"
DOWN = b"\x00"


def _host_port(value: str, default_port: int) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host:
        return value, default_port
    return host, int(port)


def serve(domain: str, valve: tuple[str, int], bind: tuple[str, int]) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(bind)
    print(f"txt_query_sidecar bind={bind[0]}:{bind[1]} valve={valve[0]}:{valve[1]}", flush=True)
    with TxtQueryClient(domain, server=valve) as cli:
        while True:
            payload, peer = sock.recvfrom(4096)
            try:
                if payload:
                    _session, echoed = cli.send(payload)
                    sock.sendto(UP + echoed, peer)
                else:
                    sock.sendto(UP, peer)
            except ValveDown:
                sock.sendto(DOWN, peer)
            except OSError:
                sock.sendto(DOWN, peer)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("domain")
    ap.add_argument("--valve", default="127.0.0.1:53")
    ap.add_argument("--bind", default="127.0.0.1:5355")
    args = ap.parse_args(argv)
    return serve(
        args.domain,
        _host_port(args.valve, 53),
        _host_port(args.bind, 5355),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
