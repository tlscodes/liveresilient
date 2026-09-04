#!/usr/bin/env python3
"""A userspace NAT between "inside" probe clients and the reflector, with
every RFC 4787 behavior selectable, so the probe's classification can be
proven on counterexamples BEFORE it meets a real operator.

Inside clients do not send to the reflector directly; they send to this
process an envelope {"dst": "<A1|A2|B1>", "data": <json>} and it forwards
the payload from an OUTSIDE socket chosen by the mapping policy:
  eim   endpoint-independent mapping:      one outside port per inside socket
  adm   address-dependent mapping:         one per (inside socket, dst address)
  apdm  address-and-port-dependent mapping ("symmetric"): one per (inside, dst addr, dst port)
Inbound datagrams on an outside socket pass the filtering policy:
  eif   endpoint-independent filtering:    anything may come in
  adf   address-dependent filtering:       only from addresses this mapping sent to
  apdf  address-and-port-dependent:        only from addr:port this mapping sent to
Hairpin: a datagram whose destination is one of this NAT's own outside
sockets is delivered to the inside owner (source = the sender's outside
address) when --hairpin is on, dropped otherwise. Mappings expire after
--timeout seconds without outbound traffic. The reflector's logical
addresses are ports on 127.0.0.1; A1/A2 share "address A", B1 is "address B"
(what matters to the policies is the logical address, exactly as a real NAT
keys on the destination IP).

USAGE  nat_sim.py --listen 127.0.0.1:4000 --reflector 127.0.0.1:3479 [--alt 127.0.0.1:3489]
                  --mapping eim|adm|apdm --filtering eif|adf|apdf [--hairpin] [--timeout 30]
"""
import argparse
import json
import socket
import threading
import time


def parse(addr: str) -> tuple[str, int]:
    host, port = addr.rsplit(":", 1)
    return host, int(port)


class NatSim:
    def __init__(self, a):
        self.inside = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.inside.bind(parse(a.listen))
        r = parse(a.reflector)
        alt = parse(a.alt) if a.alt else None
        # logical name -> (real addr, logical address)
        self.targets = {"A1": (r, "A"), "A2": ((r[0], r[1] + 1), "A")}
        if alt:
            self.targets["B1"] = (alt, "B")
        self.mapping, self.filtering, self.hairpin, self.timeout = a.mapping, a.filtering, a.hairpin, a.timeout
        self.maps: dict[tuple, dict] = {}   # key -> {sock, inside, sent:set, last}
        self.by_out: dict[tuple, dict] = {}  # outside (ip,port) -> map
        self.lock = threading.Lock()

    def key(self, inside, laddr, lport):
        if self.mapping == "eim":
            return (inside,)
        if self.mapping == "adm":
            return (inside, laddr)
        return (inside, laddr, lport)

    def run(self):
        threading.Thread(target=self._reaper, daemon=True).start()
        while True:
            raw, inside = self.inside.recvfrom(4096)
            try:
                env = json.loads(raw.decode())
                dst = env["dst"]
                payload = json.dumps(env["data"]).encode()
            except (ValueError, KeyError):
                continue
            if isinstance(dst, list):  # hairpin: an explicit outside address
                self._hairpin(inside, (dst[0], int(dst[1])), payload)
                continue
            real, laddr = self.targets[dst]
            k = self.key(inside, laddr, real[1])
            with self.lock:
                m = self.maps.get(k)
                if m is None:
                    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    out.bind(("127.0.0.1", 0))
                    m = {"sock": out, "inside": inside, "sent": set(), "last": time.time(), "key": k}
                    self.maps[k] = m
                    self.by_out[out.getsockname()] = m
                    threading.Thread(target=self._outside_loop, args=(m,), daemon=True).start()
                m["sent"].add((laddr, real[1]))
                m["last"] = time.time()
            m["sock"].sendto(payload, real)

    def _logical(self, src):
        for name, (real, laddr) in self.targets.items():
            if real == src:
                return laddr, real[1]
        return src[0], src[1]  # another inside client's outside socket (hairpin pong)

    def _outside_loop(self, m):
        sock = m["sock"]
        while True:
            try:
                raw, src = sock.recvfrom(4096)
            except OSError:
                return
            laddr, lport = self._logical(src)
            allowed = (
                self.filtering == "eif"
                or (self.filtering == "adf" and any(a == laddr for a, _ in m["sent"]))
                or (self.filtering == "apdf" and (laddr, lport) in m["sent"])
            )
            with self.lock:
                alive = m["key"] in self.maps
            if not allowed or not alive:
                continue
            env = {"src": [src[0], src[1]], "data": json.loads(raw.decode())}
            self.inside.sendto(json.dumps(env).encode(), m["inside"])

    def _hairpin(self, inside, dst_out, payload):
        # The sender needs its own mapping toward that destination (a real
        # NAT allocates one for any outbound packet).
        k = self.key(inside, dst_out[0], dst_out[1])
        with self.lock:
            m = self.maps.get(k)
            if m is None:
                out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                out.bind(("127.0.0.1", 0))
                m = {"sock": out, "inside": inside, "sent": set(), "last": time.time(), "key": k}
                self.maps[k] = m
                self.by_out[out.getsockname()] = m
                threading.Thread(target=self._outside_loop, args=(m,), daemon=True).start()
            m["sent"].add(dst_out)
            m["last"] = time.time()
            target = self.by_out.get(dst_out)
        if not self.hairpin or target is None:
            return
        # Deliver inside-to-inside with the sender's OUTSIDE address as source,
        # subject to the receiver's filtering policy.
        sender_out = m["sock"].getsockname()
        allowed = (
            self.filtering == "eif"
            or (self.filtering == "adf" and any(a == sender_out[0] for a, _ in target["sent"]))
            or (self.filtering == "apdf" and sender_out in target["sent"])
        )
        if not allowed:
            return
        env = {"src": [sender_out[0], sender_out[1]], "data": json.loads(payload.decode())}
        self.inside.sendto(json.dumps(env).encode(), target["inside"])

    def _reaper(self):
        while True:
            time.sleep(0.5)
            now = time.time()
            with self.lock:
                for k, m in list(self.maps.items()):
                    if now - m["last"] > self.timeout:
                        del self.maps[k]
                        self.by_out.pop(m["sock"].getsockname(), None)
                        m["sock"].close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:4000")
    ap.add_argument("--reflector", default="127.0.0.1:3479")
    ap.add_argument("--alt", default=None)
    ap.add_argument("--mapping", choices=["eim", "adm", "apdm"], default="eim")
    ap.add_argument("--filtering", choices=["eif", "adf", "apdf"], default="eif")
    ap.add_argument("--hairpin", action="store_true")
    ap.add_argument("--timeout", type=float, default=30.0)
    NatSim(ap.parse_args()).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
