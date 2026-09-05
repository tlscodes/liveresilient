#!/usr/bin/env python3
"""Proof of the hub's /bundle route without a phone: a boot event carries a
public key, a signed bundle is accepted with sig_ok=true, a tampered payload
and a foreign key are refused as sig_ok=false / pubkey_match=false. Then the
chunked route: a 20 KB envelope in three 8 KB pieces posted out of order with
one duplicate ends in ONE bundle_received with chunks=3 and sig_ok=true, /have
reports the stored indexes, a piece naming a different sha for a known id is
409, a joined envelope whose sha differs from the query is 409, a piece over
64 KB is 413, and a bad idx is 400.

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


def get(path: str) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def check(label: str, ok: bool, detail: str = "") -> int:
    print(f"{label:<28} {detail} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def envelope(key, pub_b64: str, run: str, bundle_id: str, payload: bytes, age_ms: int) -> bytes:
    env = {"run": run, "id": bundle_id, "created_ms": int(time.time() * 1000) - age_ms,
           "payload": base64.b64encode(payload).decode(),
           "sig": base64.b64encode(key.sign(payload)).decode(), "pubkey": pub_b64}
    return json.dumps(env, separators=(",", ":")).encode()


def pieces(raw: bytes, size: int) -> list[bytes]:
    return [raw[i:i + size] for i in range(0, len(raw), size)]


def events(run_dir: Path, event: str, bundle_id: str) -> list[dict]:
    lines = (run_dir / "phone_events.jsonl").read_text().splitlines()
    return [e for e in map(json.loads, lines) if e.get("event") == event and e.get("id") == bundle_id]


def chunk_cases(run_dir: Path, key, pub_b64: str) -> int:
    failures = 0
    chunk = 8192
    payload = bytes((i * 7) % 256 for i in range(15_000))  # → ~20 KB envelope after base64
    bid = "big-" + hashlib.sha256(payload).hexdigest()[:12]
    raw = envelope(key, pub_b64, "r1", bid, payload, 7_200_000)
    sha = hashlib.sha256(raw).hexdigest()
    parts = pieces(raw, chunk)
    n = len(parts)
    failures += check("chunk count", n == 3, f"envelope={len(raw)}B n={n}")
    url = f"/chunk?id={bid}&n={n}&sha256={sha}&idx="
    code, body = post(url + "2", parts[2], "application/octet-stream")
    failures += check("chunk 2 first", code == 200 and body.strip() == "ok", f"{code} {body.strip()}")
    code, body = post(url + "0", parts[0], "application/octet-stream")
    failures += check("chunk 0", code == 200 and body.strip() == "ok", f"{code} {body.strip()}")
    code, body = post(url + "0", parts[0], "application/octet-stream")
    failures += check("chunk 0 duplicate", code == 200 and body.strip() == "ok", f"{code} {body.strip()}")
    code, body = get(f"/have?id={bid}")
    have = json.loads(body)
    ok = code == 200 and have == {"id": bid, "have": [0, 2], "n": 3, "complete": False}
    failures += check("/have after two", ok, body.strip())
    code, body = post(url + "1", parts[1], "application/octet-stream")
    ok = code == 200 and body.strip() == "complete sig_ok=true pubkey_match=true"
    failures += check("chunk 1 completes", ok, f"{code} {body.strip()}")
    recs = events(run_dir, "bundle_received", bid)
    ok = (len(recs) == 1 and recs[0]["chunks"] == 3 and recs[0]["sig_ok"] and recs[0]["pubkey_match"]
          and recs[0]["bytes"] == len(payload) and 7190 < recs[0]["latency_s"] < 7210)
    failures += check("one event chunks=3", ok, f"events={len(recs)} latency_s={recs[0]['latency_s'] if recs else '-'}")
    ok = (run_dir / "blobs" / f"bundle-{bid}.bin").read_bytes() == payload
    failures += check("blob bytes", ok)
    code, body = post(url + "1", parts[1], "application/octet-stream")
    ok = code == 200 and body.startswith("complete sig_ok=true") and len(events(run_dir, "bundle_received", bid)) == 1
    failures += check("repost after complete", ok, f"{code} {body.strip()} events={len(events(run_dir, 'bundle_received', bid))}")
    code, body = get(f"/have?id={bid}")
    failures += check("/have complete", json.loads(body)["complete"] is True, body.strip())
    # a second piece naming a different sha for a known id
    other_sha = hashlib.sha256(b"other").hexdigest()
    code, body = post(f"/chunk?id={bid}&n={n}&sha256={other_sha}&idx=1", parts[1], "application/octet-stream")
    failures += check("different sha → 409", code == 409, f"{code} {body.strip()}")
    # the joined bytes differ from the declared sha: 409 before any parsing, pieces kept
    bid2 = "wrong-" + bid[4:]
    url2 = f"/chunk?id={bid2}&n={n}&sha256={other_sha}&idx="
    for i in (0, 1):
        code, _ = post(url2 + str(i), parts[i], "application/octet-stream")
        assert code == 200, code
    code, body = post(url2 + "2", parts[2], "application/octet-stream")
    ok = code == 409 and "sha mismatch" in body and not events(run_dir, "bundle_received", bid2)
    failures += check("joined sha mismatch → 409", ok, f"{code} {body.strip()}")
    code, body = get(f"/have?id={bid2}")
    failures += check("/have keeps pieces", json.loads(body)["have"] == [0, 1, 2], body.strip())
    # oversize piece
    code, body = post(f"/chunk?id=huge&n=2&sha256={sha}&idx=0", b"x" * (64 * 1024 + 1), "application/octet-stream")
    failures += check("oversize → 413", code == 413, f"{code} {body.strip()}")
    code, body = post(f"/chunk?id=huge&n=2&sha256={sha}&idx=0", b"x" * (64 * 1024), "application/octet-stream")
    failures += check("64 KB exactly → 200", code == 200, f"{code} {body.strip()}")
    # bad query
    code, body = post(f"/chunk?id=huge&n=2&sha256={sha}&idx=2", b"x", "application/octet-stream")
    failures += check("idx ≥ n → 400", code == 400, f"{code} {body.strip()}")
    code, body = post(f"/chunk?id=bad/id&n=2&sha256={sha}&idx=0", b"x", "application/octet-stream")
    failures += check("bad id → 400", code == 400, f"{code} {body.strip()}")
    code, body = post(f"/chunk?id=huge&n=5000&sha256={sha}&idx=0", b"x", "application/octet-stream")
    failures += check("n > 4096 → 400", code == 400, f"{code} {body.strip()}")
    return failures


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
        failures += chunk_cases(run_dir, key, pub_b64)
    finally:
        hub.terminate()
    print(f"failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
