#!/usr/bin/env python3
"""NAT-behavior probe (RFC 4787 / RFC 5780 style) that records NO identity.

Three questions, each answered by a fresh local socket (a fresh mapping):
  mapping    endpoint-independent (eim) / address-dependent (adm) /
             address-and-port-dependent (apdm, "symmetric"): the reflexive
             port seen by A1, A2 and B1 is the same, changes with the
             address, or changes with the port.
  filtering  eif / adf / apdf: after sending to A1, does a reply from A2
             (same address, other port) or from B1 (other address) get in?
             Without an alternate address the answer is "eif-or-adf".
  hairpin    two devices behind the same NAT learn each other's reflexive
             address through the reflector's mailbox, both punch, and report
             whether anything arrived — the way a real call would do it.
Optional: mapping lifetime (how long a silent mapping stays open), the
number that sets a phone-as-host keepalive interval.

THE RECORD holds no address, no device id, no exact time: operator label
(chosen by the user from a list, or "unknown"), access type, the CLASS of
the local address (private / carrier-grade / public), the three verdicts,
the lifetime bucket and a round-trip bucket. Nothing else leaves the device.

Transports: --reflector <ip:port> [--alt <ip>] talks to a real reflector;
--via-sim <ip:port> goes through nat_sim.py (proof of the classifier).

USAGE  probe.py --reflector 203.0.113.10:3479 --alt 203.0.113.11 --operator irancell --access mobile
       probe.py --via-sim 127.0.0.1:4000 --hairpin-room r1 --role a
"""
import argparse
import ipaddress
import json
import os
import socket
import threading
import time
from datetime import datetime, timezone

VERSION = "py-0.1"


class Direct:
    def __init__(self, reflector: str, alt: str | None):
        host, port = reflector.rsplit(":", 1)
        self.names = {"A1": (host, int(port)), "A2": (host, int(port) + 1)}
        if alt:
            self.names["B1"] = (alt, int(port))

    def sock(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", 0))
        return s

    def send(self, s, dst, msg):
        target = self.names[dst] if isinstance(dst, str) else (dst[0], int(dst[1]))
        s.sendto(json.dumps(msg).encode(), target)

    def recv(self, s, timeout):
        s.settimeout(timeout)
        try:
            raw, src = s.recvfrom(4096)
        except (socket.timeout, OSError):
            return None, None
        return json.loads(raw.decode()), src

    def has_alt(self):
        return "B1" in self.names


class ViaSim:
    def __init__(self, sim: str, has_alt: bool):
        host, port = sim.rsplit(":", 1)
        self.sim = (host, int(port))
        self._alt = has_alt

    def sock(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        return s

    def send(self, s, dst, msg):
        s.sendto(json.dumps({"dst": dst, "data": msg}).encode(), self.sim)

    def recv(self, s, timeout):
        s.settimeout(timeout)
        try:
            raw, _ = s.recvfrom(4096)
        except (socket.timeout, OSError):
            return None, None
        env = json.loads(raw.decode())
        return env["data"], tuple(env["src"])

    def has_alt(self):
        return self._alt


def local_class(ip: str) -> str:
    a = ipaddress.ip_address(ip)
    if a.is_loopback:
        return "loopback"
    if a in ipaddress.ip_network("100.64.0.0/10"):
        return "cgnat100.64"
    if a in ipaddress.ip_network("10.0.0.0/8"):
        return "private10"
    if a in ipaddress.ip_network("172.16.0.0/12"):
        return "private172"
    if a in ipaddress.ip_network("192.168.0.0/16"):
        return "private192"
    return "public" if a.is_global else "other"


def nonce():
    return os.urandom(4).hex()


def test_mapping(t):
    s = t.sock()
    seen = {}
    rtts = []
    for name in ["A1", "A2"] + (["B1"] if t.has_alt() else []):
        n = nonce()
        t0 = time.time()
        t.send(s, name, {"t": "map", "n": n})
        for _ in range(3):
            msg, _src = t.recv(s, 1.5)
            if msg and msg.get("n") == n:
                seen[name] = tuple(msg["src"])
                rtts.append((time.time() - t0) * 1000)
                break
    s.close()
    if "A1" not in seen or "A2" not in seen:
        return "unreachable", seen, rtts
    if seen["A1"] != seen["A2"]:
        return "apdm", seen, rtts
    if t.has_alt() and "B1" in seen and seen["B1"] != seen["A1"]:
        return "adm", seen, rtts
    return "eim", seen, rtts


def test_filtering(t):
    s = t.sock()
    got = set()
    for want in ["same", "alt-port", "alt-addr"]:
        if want == "alt-addr" and not t.has_alt():
            continue
        n = nonce()
        t.send(s, "A1", {"t": "filt", "n": n, "reply": want})
        for _ in range(3):
            msg, _src = t.recv(s, 1.5)
            if msg and msg.get("n") == n:
                if "unsupported" not in msg:
                    got.add(msg.get("via"))
                break
    s.close()
    if "A1" not in got:
        return "unreachable"
    if "B1" in got:
        return "eif"
    if "A2" in got:
        return "adf" if t.has_alt() else "eif-or-adf"
    return "apdf"


def test_hairpin(t, room: str, role: str):
    """Both devices register, fetch the other's reflexive address, punch three
    times, and listen. Success = anything from the peer arrived."""
    s = t.sock()
    mine, theirs = f"{room}-{role}", f"{room}-{'b' if role == 'a' else 'a'}"
    # Register twice: the first datagram of a fresh mapping can be lost on
    # the way up (measured once in the simulator's first case, 2026-09-05).
    for _ in range(2):
        t.send(s, "A1", {"t": "hp-reg", "n": nonce(), "room": mine})
        t.recv(s, 1.0)
    peer = None
    for _ in range(16):
        n = nonce()
        t.send(s, "A1", {"t": "hp-get", "n": n, "room": theirs})
        msg, _src = t.recv(s, 1.0)
        if msg and msg.get("n") == n and msg.get("peer"):
            peer = msg["peer"]
            break
        time.sleep(0.25)
    if peer is None:
        s.close()
        return "untested"
    arrived = {"ok": False}

    def listen():
        end = time.time() + 4.0
        while time.time() < end:
            msg, _src = t.recv(s, 0.5)
            if msg and msg.get("t") in ("hp-ping", "hp-pong"):
                arrived["ok"] = True
                if msg.get("t") == "hp-ping":
                    t.send(s, peer, {"t": "hp-pong", "n": nonce()})

    th = threading.Thread(target=listen)
    th.start()
    for _ in range(3):
        t.send(s, peer, {"t": "hp-ping", "n": nonce()})
        time.sleep(0.3)
    th.join()
    s.close()
    return "yes" if arrived["ok"] else "no"


def test_lifetime(t, steps=(10, 30, 60, 120)):
    best = None
    for n in steps:
        s = t.sock()
        t.send(s, "A1", {"t": "life", "n": nonce(), "after": n})
        t.recv(s, 1.5)  # the schedule confirmation
        msg, _src = t.recv(s, n + 3.0)
        s.close()
        if msg and msg.get("t") == "life":
            best = n
        else:
            break
    return f">={best}" if best else f"<{steps[0]}"


def bucket_rtt(rtts):
    if not rtts:
        return "unknown"
    m = min(rtts)
    return "<50" if m < 50 else "50-200" if m < 200 else "200-1000" if m < 1000 else ">1000"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reflector")
    ap.add_argument("--alt")
    ap.add_argument("--via-sim")
    ap.add_argument("--sim-has-alt", action="store_true")
    ap.add_argument("--operator", default="unknown")
    ap.add_argument("--access", choices=["mobile", "fixed", "unknown"], default="unknown")
    ap.add_argument("--hairpin-room")
    ap.add_argument("--role", choices=["a", "b"], default="a")
    ap.add_argument("--lifetime", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    t = ViaSim(a.via_sim, a.sim_has_alt) if a.via_sim else Direct(a.reflector, a.alt)

    mapping, seen, rtts = test_mapping(t)
    local_ip = "127.0.0.1"
    if not a.via_sim:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(t.names["A1"])
        local_ip = probe.getsockname()[0]
        probe.close()
    reflexive = seen.get("A1")
    nat = None if reflexive is None else (reflexive[0] != local_ip)
    record = {
        "v": 1,
        "probe": VERSION,
        "day": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "operator": a.operator,
        "access": a.access,
        "local_class": local_class(local_ip),
        "nat": nat,
        "mapping": mapping,
        "filtering": test_filtering(t) if mapping != "unreachable" else "unreachable",
        "hairpin": test_hairpin(t, a.hairpin_room, a.role) if a.hairpin_room else "untested",
        "lifetime_s": test_lifetime(t) if a.lifetime else "untested",
        "rtt_ms": bucket_rtt(rtts),
        "alt_address_available": t.has_alt(),
    }
    line = json.dumps(record, separators=(",", ":"))
    print(line)
    if a.out:
        with open(a.out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
