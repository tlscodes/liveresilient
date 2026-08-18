#!/usr/bin/env python3
"""Perform a full TURN Allocate with long-term credentials and report the result.

A STUN Binding Success proves the server answers; it does NOT prove it will
issue relay allocations. This probe does the real thing:
  1. Allocate (unauthenticated) -> expect 401 with REALM + NONCE
  2. Allocate (USERNAME/REALM/NONCE + MESSAGE-INTEGRITY) -> expect success
     with XOR-RELAYED-ADDRESS, or print the exact STUN error code/reason.

Usage: turn_probe.py <host> <port> <user> <pass>   exit 0 = allocation granted
"""
import hashlib
import hmac
import os
import socket
import struct
import sys

MAGIC = 0x2112A442


def attrs(data):
    out = {}
    i = 0
    while i + 4 <= len(data):
        t, l = struct.unpack("!HH", data[i:i + 4])
        out.setdefault(t, []).append(data[i + 4:i + 4 + l])
        i += 4 + l + ((4 - l % 4) % 4)
    return out


def msg(mtype, txid, attrlist, key=None):
    body = b""
    for t, v in attrlist:
        body += struct.pack("!HH", t, len(v)) + v + b"\x00" * ((4 - len(v) % 4) % 4)
    if key is not None:
        hdr = struct.pack("!HHI", mtype, len(body) + 24, MAGIC) + txid
        mac = hmac.new(key, hdr + body, hashlib.sha1).digest()
        body += struct.pack("!HH", 0x0008, 20) + mac
    return struct.pack("!HHI", mtype, len(body), MAGIC) + txid + body


def rt(s, host, port, m):
    s.sendto(m, (host, port))
    data, _ = s.recvfrom(2048)
    return data


def xoraddr(v):
    fam, xport = struct.unpack("!xBH", v[:4])
    port = xport ^ (MAGIC >> 16)
    ip = bytes(b ^ m for b, m in zip(v[4:8], struct.pack("!I", MAGIC)))
    return f"{socket.inet_ntoa(ip)}:{port}"


def main():
    host, port, user, pw = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(4.0)
    txid = os.urandom(12)
    reqtrans = (0x0019, struct.pack("!B3x", 17))  # REQUESTED-TRANSPORT = UDP
    r = rt(s, host, port, msg(0x0003, txid, [reqtrans]))
    mtype = struct.unpack("!H", r[0:2])[0]
    a = attrs(r[20:])
    if mtype == 0x0113 and 0x0009 in a:
        code = a[0x0009][0]
        num = (code[2] & 0x7) * 100 + code[3]
        if num != 401:
            print(f"turn_probe: first Allocate got error {num} {code[4:].decode(errors='replace')}")
            return 1
        realm = a[0x0014][0]
        nonce = a[0x0015][0]
    else:
        print(f"turn_probe: unexpected first response type 0x{mtype:04x}")
        return 1
    print(f"turn_probe: challenged realm={realm.decode()} nonce={nonce[:16].decode(errors='replace')}...")
    key = hashlib.md5(f"{user}:{realm.decode()}:{pw}".encode()).digest()
    txid2 = os.urandom(12)
    r2 = rt(s, host, port, msg(0x0003, txid2, [
        reqtrans,
        (0x0006, user.encode()),
        (0x0014, realm),
        (0x0015, nonce),
    ], key=key))
    mtype2 = struct.unpack("!H", r2[0:2])[0]
    a2 = attrs(r2[20:])
    if mtype2 == 0x0103:
        rel = xoraddr(a2[0x0016][0]) if 0x0016 in a2 else "?"
        life = struct.unpack("!I", a2[0x000D][0])[0] if 0x000D in a2 else -1
        print(f"turn_probe: ALLOCATED relay {rel} lifetime {life}s  (resp {len(r2)}B)")
        return 0
    if 0x0009 in a2:
        code = a2[0x0009][0]
        num = (code[2] & 0x7) * 100 + code[3]
        print(f"turn_probe: Allocate REFUSED error {num} {code[4:].decode(errors='replace')}  (resp {len(r2)}B)")
    else:
        print(f"turn_probe: unexpected second response type 0x{mtype2:04x} ({len(r2)}B)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
