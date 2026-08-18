#!/usr/bin/env python3
"""Radio keep-awake that SURVIVES shaping: a 5 pps UDP trickle to the
phone's port 5353 — the one port the rig's shaping rules deliberately
exclude (mDNS), so the wake stream reaches the radio at full rate while
every experiment packet stays fully shaped. Rig hygiene only: emulates
'screen on', adds zero traffic to the shaped classes."""
import socket
import sys
import time

peer = sys.argv[1] if len(sys.argv) > 1 else '192.168.3.3'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
payload = b'wake'
while True:
    try:
        s.sendto(payload, (peer, 5353))
    except OSError:
        pass
    time.sleep(0.2)
