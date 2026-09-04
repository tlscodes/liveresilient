#!/usr/bin/env python3
"""Proof of the hub's /bundle route without a phone: a boot event carries a
public key, a signed bundle is accepted with sig_ok=true, a tampered payload
and a foreign key are refused as sig_ok=false / pubkey_match=false.

USAGE  python3 tools/t2/test_journey_hub_bundle.py     → exit 0 on PASS
"""
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

HERE = Path(__file__).resolve().parent
PORT = 8799


def post(path: str, body: bytes, ctype: str = "application/json") -> tuple[int, str]:
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=body, method="POST")
    req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> int:
    run_dir = Path(tempfile.mkdtemp(prefix="hubtest."))
    hub = subprocess.Popen([sys.executable, str(HERE / "journey_hub.py"), "--bind", "127.0.0.1",
                            "--port", str(PORT), "--dir", str(run_dir)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.6)
    failures = 0
    try:
        key = Ed25519PrivateKey.generate()
        pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        pub_b64 = base64.b64encode(pub).decode()
        code, _ = post("/report", json.dumps({"event": "boot", "run": None, "at": "t", "media": "x",
                                             "blob": True, "blackout": True, "pubkey": pub_b64}).encode())
        assert code == 200, code
        assert (run_dir / "peer_pubkey.b64").read_text().strip() == pub_b64
        payload = b"{\"run\":\"r1\"}" + bytes(range(256)) * 4
        sig = key.sign(payload)
        bid = hashlib.sha256(payload).hexdigest()[:16]
        env = {"run": "r1", "id": bid, "created_ms": int(time.time() * 1000) - 3_600_000,
               "payload": base64.b64encode(payload).decode(), "sig": base64.b64encode(sig).decode(),
               "pubkey": pub_b64}
        code, body = post("/bundle", json.dumps(env).encode())
        ok = code == 200 and "sig_ok=true" in body and "pubkey_match=true" in body
        print(f"good bundle: {code} {body.strip()} -> {'PASS' if ok else 'FAIL'}")
        failures += 0 if ok else 1
        events = [json.loads(l) for l in (run_dir / "phone_events.jsonl").read_text().splitlines()]
        rec = [e for e in events if e.get("event") == "bundle_received"][-1]
        ok = rec["sig_ok"] and rec["pubkey_match"] and rec["bytes"] == len(payload) and 3590 < rec["latency_s"] < 3610
        print(f"event latency_s={rec['latency_s']} sha={rec['sha256'][:12]} -> {'PASS' if ok else 'FAIL'}")
        failures += 0 if ok else 1
        assert (run_dir / "blobs" / f"bundle-{bid}.bin").read_bytes() == payload
        # tampered payload
        env2 = dict(env, payload=base64.b64encode(payload[:-1] + b"X").decode())
        code, body = post("/bundle", json.dumps(env2).encode())
        ok = code == 200 and "sig_ok=false" in body
        print(f"tampered:    {code} {body.strip()} -> {'PASS' if ok else 'FAIL'}")
        failures += 0 if ok else 1
        # foreign key
        other = Ed25519PrivateKey.generate()
        opub = base64.b64encode(other.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        env3 = dict(env, sig=base64.b64encode(other.sign(payload)).decode(), pubkey=opub)
        code, body = post("/bundle", json.dumps(env3).encode())
        ok = code == 200 and "sig_ok=true" in body and "pubkey_match=false" in body
        print(f"foreign key: {code} {body.strip()} -> {'PASS' if ok else 'FAIL'}")
        failures += 0 if ok else 1
        code, _ = post("/bundle", b"not json")
        print(f"bad body:    {code} -> {'PASS' if code == 400 else 'FAIL'}")
        failures += 0 if code == 400 else 1
    finally:
        hub.terminate()
    print(f"failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
