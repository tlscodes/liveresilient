#!/usr/bin/env python3
"""Send one STUN Binding Request and require a well-formed answer.

Used by h2_run.sh to prove the TURN server is actually answering on the
bridge address BEFORE a matrix row runs. A TURN server that is up but
unreachable produces relay-less ICE that silently falls back — precisely the
loopback-wearing-a-shaped-label failure the harness exists to prevent, so
this probe fails loudly instead.

Usage: stun_probe.py <host> <port>   exit 0 = STUN Binding Success received
"""
import os
import socket
import struct
import sys


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    txid = os.urandom(12)
    # Binding Request: type 0x0001, length 0, magic cookie, transaction id.
    req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txid
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    try:
        s.sendto(req, (host, port))
        data, _ = s.recvfrom(2048)
    except OSError as e:
        print(f"stun_probe: no answer from {host}:{port} ({e})", file=sys.stderr)
        return 1
    finally:
        s.close()
    if len(data) < 20 or data[4:8] != struct.pack("!I", 0x2112A442) or data[8:20] != txid:
        print("stun_probe: malformed STUN answer", file=sys.stderr)
        return 1
    mtype = struct.unpack("!H", data[0:2])[0]
    if mtype != 0x0101:  # Binding Success Response
        print(f"stun_probe: unexpected message type 0x{mtype:04x}", file=sys.stderr)
        return 1
    print(f"stun_probe: {host}:{port} answered Binding Success")
    return 0


if __name__ == "__main__":
    sys.exit(main())
