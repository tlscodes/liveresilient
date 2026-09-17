#!/usr/bin/env python3
"""Direct-path probe using the real wire protocol (tools/t2/txt_query_wire.py),
so the responder answers rcode=0 (NOERROR) instead of NXDOMAIN."""
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import txt_query_wire as wire  # noqa: E402

DOMAIN = "valve.test"
HOST = "192.168.2.1"
PORT = 5300
# Relative to the repo root (this script expects to be run as
# `python3 tools/t2/probe_direct_wire.py` from the repo root, matching every
# other tools/t2/*.py rig script's convention).
LOG_PATH = Path("tools/dossier/logs/journey/dnsvalve.valve.log")

payload = b"probe-direct-check"
session_id, names = wire.encode_queries(payload, DOMAIN)
name = names[0]
parsed = wire.parse_query_name(name, DOMAIN)
nonce = parsed.nonce

txid = 0x51C4
pkt = wire.build_dns_query_packet(txid, name)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3.0)
start = time.perf_counter()
status = None
rcode = None
rtt_ms = None
answer_payload = None
try:
    sock.sendto(pkt, (HOST, PORT))
    resp, _ = sock.recvfrom(2048)
    rtt_ms = round((time.perf_counter() - start) * 1000, 1)
    ans = wire.parse_dns_answer_packet(resp)
    rcode = ans.rcode
    answer_payload = ans.payload
    status = "REACHABLE"
except socket.timeout:
    status = "TIMEOUT"
except ConnectionRefusedError:
    status = "RESET"
finally:
    sock.close()

print(f"name_sent      = {name}")
print(f"session_id     = {session_id}")
print(f"nonce          = {nonce}")
print(f"client_status  = {status}" + (f" rtt={rtt_ms}ms rcode={rcode}" if status == "REACHABLE" else ""))
print(f"answer_payload = {answer_payload!r}")

in_log = False
if LOG_PATH.exists():
    content = LOG_PATH.read_text(encoding="utf-8", errors="ignore")
    in_log = nonce.lower() in content.lower()
print(f"nonce_in_log   = {'بله' if in_log else 'خیر'}  (log={LOG_PATH})")

if status == "REACHABLE" and rcode == 0:
    verdict = "مستقیم‌باز" if in_log else "جعل"
else:
    verdict = "بسته"
print(f"verdict        = {verdict}")
