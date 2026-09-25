"""One random name to the rig responder; prints the group so the log can be searched.

The responder logs a query name only when it is a PRB1 probe (other names get
NXDOMAIN at DEBUG level, invisible at INFO). So the "random name" is a PRB1
probe whose 8-byte group and nonce are fresh random bytes: the query name is
never seen before, and `probe group=<hex>` in the log proves that exact name
reached the responder. Sends to 192.168.2.1:5300 only.

    python3 tools/t2/rand_name_check.py [domain]     -> stdout: group hex
"""
from __future__ import annotations

import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from txt_query_wire import build_dns_query_packet, encode_queries  # noqa: E402

HOST, PORT = "192.168.2.1", 5300


def main() -> int:
    domain = sys.argv[1] if len(sys.argv) > 1 else "valve.test"
    group, nonce = os.urandom(8), os.urandom(8)
    _, names = encode_queries(b"PRB1" + group + nonce, domain)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    answered = []
    for i, name in enumerate(names):
        s.sendto(build_dns_query_packet(0x5100 + i, name), (HOST, PORT))
        try:
            answered.append(len(s.recvfrom(4096)[0]))
        except socket.timeout:
            answered.append(0)
    print(f"sent {len(names)} name(s) to {HOST}:{PORT}: {names[0]} reply_bytes={answered}", file=sys.stderr)
    print(group.hex())
    return 0


if __name__ == "__main__":
    sys.exit(main())
