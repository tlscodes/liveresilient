#!/usr/bin/env python3
"""UDP reflector for the NAT-behavior probe (RFC 4787 / RFC 5780 style).

Runs on any host the probing devices can reach. It answers every datagram
with the source address it SAW (the reflexive address), from the socket the
sender asked for, and keeps a tiny mailbox so two devices behind the same
NAT can find each other's reflexive address for the hairpin test.

Sockets: primary address on two ports (P1, P2) and, when given, an
alternate address on P1 — three vantage points, enough to separate
endpoint-independent from address-dependent from address-and-port-dependent
behavior. Without an alternate address the filtering result can only say
"at least address-dependent", and the probe records that honestly.

Logs NOTHING about who probed: no addresses are written anywhere; the
mailbox holds a reflexive address in memory for 120 s, keyed by a random
room the two devices share, then forgets it.

USAGE  reflector.py --bind 0.0.0.0 --port 3479 [--alt-bind <second ip>]
"""
import argparse
import json
import socket
import threading
import time

ROOM_TTL_S = 120


class Reflector:
    def __init__(self, bind: str, port: int, alt_bind: str | None, alt_port: int | None):
        self.p1 = self._udp(bind, port)
        self.p2 = self._udp(bind, port + 1)
        # In the field the alternate vantage point is a second IP (alt_bind);
        # the simulator has one IP and stands "address B" on a third port.
        self.alt = None
        if alt_bind or alt_port:
            self.alt = self._udp(alt_bind or bind, alt_port or port)
        self.rooms: dict[str, tuple[list, float]] = {}
        self.lock = threading.Lock()
        self.names = {self.p1: "A1", self.p2: "A2"}
        if self.alt:
            self.names[self.alt] = "B1"

    @staticmethod
    def _udp(bind: str, port: int) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((bind, port))
        return s

    def serve(self) -> None:
        for sock in [s for s in (self.p1, self.p2, self.alt) if s]:
            threading.Thread(target=self._loop, args=(sock,), daemon=True).start()
        while True:
            time.sleep(60)
            now = time.time()
            with self.lock:
                for room in [r for r, (_, t) in self.rooms.items() if now - t > ROOM_TTL_S]:
                    del self.rooms[room]

    def _loop(self, sock: socket.socket) -> None:
        while True:
            try:
                raw, src = sock.recvfrom(2048)
                msg = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError, OSError):
                continue
            kind = msg.get("t")
            reply = {"t": kind, "n": msg.get("n"), "src": [src[0], src[1]], "via": self.names[sock]}
            if kind == "map":
                sock.sendto(json.dumps(reply).encode(), src)
            elif kind == "filt":
                want = msg.get("reply")
                out = {"same": sock, "alt-port": self.p2 if sock is self.p1 else self.p1, "alt-addr": self.alt}.get(want)
                if out is None:
                    reply["unsupported"] = want
                    sock.sendto(json.dumps(reply).encode(), src)
                else:
                    reply["via"] = self.names[out]
                    out.sendto(json.dumps(reply).encode(), src)
            elif kind == "life":
                # Send to the observed source after N s of the sender's silence:
                # arrival means the mapping outlived N s.
                after = float(msg.get("after", 0))
                threading.Timer(after, lambda: sock.sendto(json.dumps(reply).encode(), src)).start()
                reply2 = dict(reply, scheduled=after)
                sock.sendto(json.dumps(reply2).encode(), src)
            elif kind == "hp-reg":
                with self.lock:
                    self.rooms[str(msg.get("room"))] = ([src[0], src[1]], time.time())
                sock.sendto(json.dumps(reply).encode(), src)
            elif kind == "hp-get":
                with self.lock:
                    peer = self.rooms.get(str(msg.get("room")))
                reply["peer"] = peer[0] if peer else None
                sock.sendto(json.dumps(reply).encode(), src)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=3479)
    ap.add_argument("--alt-bind", default=None)
    ap.add_argument("--alt-port", type=int, default=None)
    a = ap.parse_args()
    Reflector(a.bind, a.port, a.alt_bind, a.alt_port).serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
