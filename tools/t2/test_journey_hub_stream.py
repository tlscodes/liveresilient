#!/usr/bin/env python3
"""Proof of the hub's stream lane (blackout v3) without a phone, over raw
sockets against a hub on 127.0.0.1:8799 with the lane on 8800. The 17 cases
of the adopted design: hello/state echo, a whole record, acks on a 100 KB
record, resume at the hub's `have` after a cut, a re-asked done, bad_offset,
meta_mismatch, a tampered byte, a foreign key, wrong_run, an oversized line,
too_large, preemption by a second hello, the hub's silence close
(--stream-stall-s 1), the time-based ack (--stream-ack-bytes 1000000), the
HTTP keep-alive (GET /health, POST /nowhere, GET /health on one
http.client connection; a chunked oversize /bundle → 413 then EOF), and the
lane parameters == STREAM_DEFAULTS.

USAGE  python3 tools/t2/test_journey_hub_stream.py     → exit 0 on PASS
"""
import base64
import http.client
import importlib.util
import json
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

HERE = Path(__file__).resolve().parent
HTTP_PORT = 8799
STREAM_PORT = 8800
RUN = "r1"

_spec = importlib.util.spec_from_file_location("journey_hub", HERE / "journey_hub.py")
_hub_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hub_mod)
STREAM_DEFAULTS = _hub_mod.STREAM_DEFAULTS


def check(label: str, ok: bool, detail: str = "") -> int:
    print(f"{label:<34} {detail} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


# ---- the hub under test

class HubProc:
    def __init__(self, run_dir: Path, extra: list[str]):
        self.run_dir = run_dir
        self.log = run_dir / "hub.log"
        self.proc = subprocess.Popen(
            [sys.executable, str(HERE / "journey_hub.py"), "--bind", "127.0.0.1",
             "--port", str(HTTP_PORT), "--dir", str(run_dir), "--stream-port", str(STREAM_PORT)] + extra,
            stdout=self.log.open("ab"), stderr=subprocess.STDOUT)
        for port in (HTTP_PORT, STREAM_PORT):
            deadline = time.monotonic() + 5
            while True:
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"hub port {port} never came up: {self.log.read_text()}")
                    time.sleep(0.05)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)

    def log_text(self) -> str:
        return self.log.read_text(errors="replace")


def post(path: str, body: bytes) -> tuple[int, str]:
    req = urllib.request.Request(f"http://127.0.0.1:{HTTP_PORT}{path}", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def new_run_dir() -> Path:
    run_dir = Path(tempfile.mkdtemp(prefix="hubstream."))
    (run_dir / "job.json").write_text(json.dumps({"run": RUN}))
    return run_dir


def register_key(pub_b64: str) -> None:
    code, _ = post("/report", json.dumps({"event": "boot", "run": None, "at": "t", "pubkey": pub_b64}).encode())
    assert code == 200, code


# ---- the wire

class Lane:
    """One raw connection to the stream lane with a line reader."""

    def __init__(self, timeout: float = 5.0):
        self.sock = socket.create_connection(("127.0.0.1", STREAM_PORT), timeout=timeout)
        self.buf = b""

    def send_line(self, obj: dict) -> None:
        self.sock.sendall(json.dumps(obj, separators=(",", ":")).encode() + b"\n")

    def send(self, data: bytes) -> None:
        self.sock.sendall(data)

    def line(self, timeout: float | None = None):
        """The next JSON line, or None at EOF (socket closed by the hub)."""
        if timeout is not None:
            self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            try:
                data = self.sock.recv(65536)
            except ConnectionResetError:
                return None
            if not data:
                return None
            self.buf += data
        raw, _, self.buf = self.buf.partition(b"\n")
        return json.loads(raw.decode())

    def eof(self, timeout: float = 5.0) -> bool:
        """True when the hub closed the connection (after any pending lines)."""
        self.sock.settimeout(timeout)
        try:
            while True:
                data = self.sock.recv(65536)
                if not data:
                    return True
        except ConnectionResetError:
            return True
        except TimeoutError:
            return False

    def hello(self, pub_b64: str, ids: list[str], run: str = RUN) -> dict:
        self.send_line({"v": 3, "run": run, "pubkey": pub_b64, "ids": ids})
        return self.line()

    def header(self, bundle_id: str, off: int, length: int, total: int, created_ms: int, sig: bytes) -> None:
        self.send_line({"id": bundle_id, "off": off, "len": length, "total": total,
                        "created_ms": created_ms, "sig": base64.b64encode(sig).decode()})

    def until_done(self, timeout: float = 10.0) -> tuple[list[dict], dict | None]:
        """(ack lines, the done or error line) — None when the hub closed first."""
        acks = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self.line(timeout=timeout)
            if msg is None:
                return acks, None
            if "ack" in msg:
                acks.append(msg)
            else:
                return acks, msg
        return acks, None

    def close(self) -> None:
        self.sock.close()


def b64(key) -> str:
    return base64.b64encode(key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def payload_of(n: int, seed: int) -> bytes:
    return bytes((i * 31 + seed) % 256 for i in range(n))


def events(run_dir: Path, bundle_id: str) -> list[dict]:
    path = run_dir / "phone_events.jsonl"
    if not path.exists():
        return []
    lines = path.read_text().splitlines()
    return [e for e in map(json.loads, lines) if e.get("event") == "bundle_received" and e.get("id") == bundle_id]


def stats(run_dir: Path) -> dict:
    path = run_dir / "stream_stats.json"
    if not path.exists():
        return {"bytes_carried": 0, "records": 0, "connections": 0}
    s = json.loads(path.read_text())
    return {k: s[k] for k in ("bytes_carried", "records", "connections")}


def stream_files(run_dir: Path) -> list[str]:
    sdir = run_dir / "stream"
    return sorted(p.name for p in sdir.iterdir()) if sdir.is_dir() else []


def send_whole(lane: Lane, bundle_id: str, payload: bytes, created_ms: int, sig: bytes,
               piece: int = 8192) -> tuple[list[dict], dict | None]:
    lane.header(bundle_id, 0, len(payload), len(payload), created_ms, sig)
    for i in range(0, len(payload), piece):
        lane.send(payload[i:i + piece])
    return lane.until_done()


# ---- cases against the default hub

def main_cases(run_dir: Path, hub: HubProc, key, pub_b64: str) -> int:
    f = 0
    now_ms = int(time.time() * 1000)
    # 1 hello → state echoes the parameters, unknown ids absent
    lane = Lane()
    state = lane.hello(pub_b64, ["nothing-yet", "also-nothing"])
    params = {k: state.get(k) for k in STREAM_DEFAULTS}
    ok = state.get("state") == {} and params == STREAM_DEFAULTS
    f += check("1 hello state + params", ok, json.dumps(state)[:120])
    lane.close()
    # 2 a 200 B record in one go
    p2 = payload_of(200, 2)
    sig2 = key.sign(p2)
    lane = Lane()
    lane.hello(pub_b64, ["c2"])
    acks, done = send_whole(lane, "c2", p2, now_ms - 3_600_000, sig2)
    ok = done == {"done": "c2", "sig_ok": True, "pubkey_match": True, "bytes": 200}
    f += check("2 200 B → done", ok, json.dumps(done))
    ev = events(run_dir, "c2")
    ok = (len(ev) == 1 and ev[0].get("stream") is True and "chunks" not in ev[0]
          and ev[0]["bytes"] == 200 and ev[0]["sig_ok"] and ev[0]["pubkey_match"]
          and 3590 < ev[0]["latency_s"] < 3610)
    f += check("2 one event stream:true", ok, f"events={len(ev)} {json.dumps(ev[0]) [:100] if ev else '-'}")
    ok = (run_dir / "blobs" / "bundle-c2.bin").read_bytes() == p2
    f += check("2 blob == payload", ok)
    st = stats(run_dir)
    ok = st["bytes_carried"] == 200 and st["records"] == 1
    f += check("2 stats 200 B / 1 record", ok, json.dumps(st))
    lane.close()
    # 3 100,000 B in 8 KB pieces: acks before done, have monotonic
    p3 = payload_of(100_000, 3)
    sig3 = key.sign(p3)
    lane = Lane()
    lane.hello(pub_b64, ["c3"])
    acks, done = send_whole(lane, "c3", p3, now_ms, sig3)
    haves = [a["have"] for a in acks]
    ok = (len(acks) >= 1 and all(a["ack"] == "c3" for a in acks)
          and haves == sorted(haves) and len(set(haves)) == len(haves) and haves[-1] <= 100_000
          and done is not None and done.get("done") == "c3" and done["sig_ok"] and done["bytes"] == 100_000)
    f += check("3 100 KB acks + done", ok, f"acks={len(acks)} last_have={haves[-1] if haves else '-'} done={json.dumps(done)[:60]}")
    lane.close()
    # 4 cut after 40,000 B, resume from the hub's have
    p4 = payload_of(100_000, 4)
    sig4 = key.sign(p4)
    before = stats(run_dir)["bytes_carried"]
    lane = Lane()
    lane.hello(pub_b64, ["c4"])
    lane.header("c4", 0, 100_000, 100_000, now_ms, sig4)
    lane.send(p4[:40_000])
    lane.close()
    time.sleep(0.4)
    lane = Lane()
    state = lane.hello(pub_b64, ["c4"])
    ok = state["state"].get("c4") == {"have": 40_000, "complete": False}
    f += check("4 state after cut have=40000", ok, json.dumps(state["state"]))
    lane.header("c4", 40_000, 60_000, 100_000, now_ms, sig4)
    lane.send(p4[40_000:])
    acks, done = lane.until_done()
    ok = done is not None and done.get("done") == "c4" and done["sig_ok"] and done["pubkey_match"]
    f += check("4 resumed → done", ok, json.dumps(done))
    ok = (run_dir / "blobs" / "bundle-c4.bin").read_bytes() == p4 and len(events(run_dir, "c4")) == 1
    f += check("4 blob == payload, one event", ok, f"events={len(events(run_dir, 'c4'))}")
    delta = stats(run_dir)["bytes_carried"] - before
    f += check("4 bytes_carried +100000", delta == 100_000, f"delta={delta}")
    lane.close()
    # 5 hello after completion; a re-asked done
    lane = Lane()
    state = lane.hello(pub_b64, ["c4"])
    ok = state["state"].get("c4") == {"have": 100_000, "complete": True}
    f += check("5 state complete", ok, json.dumps(state["state"]))
    n_before = len(events(run_dir, "c4"))
    lane.header("c4", 100_000, 0, 100_000, now_ms, sig4)
    acks, done = lane.until_done()
    ok = (done is not None and done.get("done") == "c4" and done["sig_ok"] and done["bytes"] == 100_000
          and len(events(run_dir, "c4")) == n_before)
    f += check("5 len 0 re-ask → done again", ok, f"{json.dumps(done)} events={len(events(run_dir, 'c4'))}")
    lane.close()
    # 6 off 0 when the hub has 40,000
    p6 = payload_of(100_000, 6)
    sig6 = key.sign(p6)
    lane = Lane()
    lane.hello(pub_b64, ["c6"])
    lane.header("c6", 0, 100_000, 100_000, now_ms, sig6)
    lane.send(p6[:40_000])
    lane.close()
    time.sleep(0.4)
    lane = Lane()
    lane.hello(pub_b64, ["c6"])
    lane.header("c6", 0, 100_000, 100_000, now_ms, sig6)
    msg = lane.line()
    ok = msg == {"error": "bad_offset", "id": "c6", "have": 40_000}
    f += check("6 bad_offset have=40000", ok, json.dumps(msg))
    f += check("6 socket EOF", lane.eof())
    size = (run_dir / "stream" / "c6.part").stat().st_size
    f += check("6 .part unchanged", size == 40_000, f"size={size}")
    lane.close()
    # 7 a different total / sig for a known id
    lane = Lane()
    lane.hello(pub_b64, ["c6"])
    lane.header("c6", 40_000, 60_001, 100_001, now_ms, sig6)
    msg = lane.line()
    ok = msg is not None and msg.get("error") == "meta_mismatch" and msg.get("id") == "c6"
    f += check("7 different total → meta_mismatch", ok, json.dumps(msg))
    f += check("7 closed", lane.eof())
    lane.close()
    lane = Lane()
    lane.hello(pub_b64, ["c6"])
    lane.header("c6", 40_000, 60_000, 100_000, now_ms, key.sign(p6 + b"x"))
    msg = lane.line()
    ok = msg is not None and msg.get("error") == "meta_mismatch"
    f += check("7 different sig → meta_mismatch", ok, json.dumps(msg))
    f += check("7 closed again", lane.eof())
    lane.close()
    # 8 a tampered byte
    p8 = payload_of(5000, 8)
    sig8 = key.sign(p8)
    bad8 = p8[:2500] + bytes([p8[2500] ^ 0xFF]) + p8[2501:]
    lane = Lane()
    lane.hello(pub_b64, ["c8"])
    acks, done = send_whole(lane, "c8", bad8, now_ms, sig8)
    ev = events(run_dir, "c8")
    comp = json.loads((run_dir / "stream" / "c8.complete.json").read_text())
    ok = (done == {"done": "c8", "sig_ok": False, "pubkey_match": True, "bytes": 5000}
          and len(ev) == 1 and ev[0]["sig_ok"] is False and comp["sig_ok"] is False)
    f += check("8 tampered → sig_ok false", ok, f"{json.dumps(done)} complete={json.dumps(comp)}")
    lane.close()
    # 9 a foreign key
    other = Ed25519PrivateKey.generate()
    p9 = payload_of(3000, 9)
    lane = Lane()
    lane.hello(b64(other), ["c9"])
    acks, done = send_whole(lane, "c9", p9, now_ms, other.sign(p9))
    ok = done == {"done": "c9", "sig_ok": True, "pubkey_match": False, "bytes": 3000}
    f += check("9 foreign key → pubkey_match false", ok, json.dumps(done))
    lane.close()
    # 10 wrong run
    files_before = stream_files(run_dir)
    st_before = stats(run_dir)
    lane = Lane()
    msg = lane.hello(pub_b64, ["c10"], run="r2")
    ok = msg == {"error": "wrong_run", "id": None, "have": None} and lane.eof()
    f += check("10 wrong_run + closed", ok, json.dumps(msg))
    ok = stream_files(run_dir) == files_before and stats(run_dir) == st_before
    f += check("10 nothing on disk", ok, f"stats={json.dumps(stats(run_dir))}")
    lane.close()
    # 11 300 KB without a newline
    files_before = stream_files(run_dir)
    st_before = stats(run_dir)
    lane = Lane()
    lane.sock.settimeout(5)
    try:
        lane.send(b"x" * 300_000)
    except OSError:
        pass  # the hub may close before the whole 300 KB is written
    closed = lane.eof()
    ok = closed and stream_files(run_dir) == files_before and stats(run_dir) == st_before
    f += check("11 oversized line → closed", ok, f"closed={closed} stats={json.dumps(stats(run_dir))}")
    lane.close()
    # 12 total over 16 MiB
    lane = Lane()
    lane.hello(pub_b64, ["c12"])
    lane.header("c12", 0, 16 * 1024 * 1024 + 1, 16 * 1024 * 1024 + 1, now_ms, sig2)
    msg = lane.line()
    ok = msg is not None and msg.get("error") == "too_large" and msg.get("id") == "c12" and lane.eof()
    f += check("12 too_large", ok, json.dumps(msg))
    lane.close()
    # 13 preemption: A mid-record, B hellos and resumes
    p13 = payload_of(100_000, 13)
    sig13 = key.sign(p13)
    a = Lane()
    a.hello(pub_b64, ["c13"])
    a.header("c13", 0, 100_000, 100_000, now_ms, sig13)
    a.send(p13[:20_000])
    time.sleep(0.4)
    b = Lane()
    state = b.hello(pub_b64, ["c13"])
    ok = state["state"].get("c13") == {"have": 20_000, "complete": False}
    f += check("13 B sees have=20000", ok, json.dumps(state["state"]))
    # A's next segment arrives right after B's hello, before A's ≤ 1 s tick
    # would have noticed the new generation: the check on the append itself
    # (journey_hub.py, the append loop in _record) must drop it, or the
    # .part becomes A + B + A bytes and never verifies. Sent before B's
    # header, so bad_offset for B is the failure signature.
    a_failed = False
    try:
        a.send(p13[20_000:40_000])
    except OSError:
        a_failed = True
    time.sleep(0.3)
    part_size = (run_dir / "stream" / "c13.part").stat().st_size
    f += check("13 A's late bytes not appended (.part still 20000)", part_size == 20_000, f"size={part_size}")
    b.header("c13", 20_000, 80_000, 100_000, now_ms, sig13)
    b.send(p13[20_000:])
    acks, done = b.until_done()
    ok = (done is not None and done.get("error") != "bad_offset" and done.get("done") == "c13" and done["sig_ok"]
          and (run_dir / "blobs" / "bundle-c13.bin").read_bytes() == p13 and len(events(run_dir, "c13")) == 1)
    f += check("13 B resumes → done, one event", ok, f"{json.dumps(done)} events={len(events(run_dir, 'c13'))}")
    a_acks, a_msg = a.until_done(timeout=5)
    try:
        a.send(p13[40_000:60_000])
    except OSError:
        a_failed = True
    ok = (a_msg is None or a_msg.get("error") == "preempted") and (a_failed or a.eof())
    f += check("13 A preempted / EOF", ok, f"a_msg={json.dumps(a_msg)} write_failed={a_failed}")
    a.close()
    b.close()
    # 16 HTTP keep-alive on one http.client connection
    log_before = hub.log_text()
    conn = http.client.HTTPConnection("127.0.0.1", HTTP_PORT, timeout=5)
    conn.request("GET", "/health")
    r1 = conn.getresponse()
    r1.read()
    conn.request("POST", "/nowhere", body=b"{}" * 100, headers={"Content-Type": "application/json"})
    r2 = conn.getresponse()
    r2.read()
    conn.request("GET", "/health")
    r3 = conn.getresponse()
    body3 = r3.read()
    conn.close()
    time.sleep(0.3)
    opened = [l for l in hub.log_text()[len(log_before):].splitlines() if l.startswith("hub conn ") and l.endswith(" open")]
    ok = (r1.status, r2.status, r3.status) == (200, 404, 200) and body3 == b"ok\n" and len(opened) <= 2
    f += check("16 keep-alive 200/404/200", ok, f"{r1.status}/{r2.status}/{r3.status} conn_open={len(opened)}")
    raw = socket.create_connection(("127.0.0.1", HTTP_PORT), timeout=5)
    raw.sendall(b"POST /bundle HTTP/1.1\r\nHost: hub\r\nTransfer-Encoding: chunked\r\n\r\n"
                b"1000001\r\n" + b"x" * 100 + b"\n")
    reply = b""
    try:
        while True:
            data = raw.recv(65536)
            if not data:
                break
            reply += data
    except (ConnectionResetError, TimeoutError):
        pass
    raw.close()
    ok = reply.startswith(b"HTTP/1.1 413")
    f += check("16 chunked oversize → 413 then EOF", ok, reply.split(b"\r\n", 1)[0].decode(errors="replace"))
    # 17 the lane parameters are the module's defaults
    f += check("17 params == STREAM_DEFAULTS", params == STREAM_DEFAULTS, json.dumps(params))
    return f


def stall_case(pub_b64: str) -> int:
    run_dir = new_run_dir()
    hub = HubProc(run_dir, ["--stream-stall-s", "1"])
    try:
        lane = Lane()
        state = lane.hello(pub_b64, [])
        t0 = time.monotonic()
        closed = lane.eof(timeout=6)
        dt = time.monotonic() - t0
        ok = state.get("stall_s") == 1 and closed and dt < 3.0
        lane.close()
        return check("14 stall_s 1 → EOF within 3 s", ok, f"closed={closed} after {dt:.2f}s")
    finally:
        hub.stop()


def time_ack_case(key, pub_b64: str) -> int:
    run_dir = new_run_dir()
    hub = HubProc(run_dir, ["--stream-ack-bytes", "1000000"])
    try:
        lane = Lane()
        state = lane.hello(pub_b64, [])
        payload = payload_of(100_000, 15)
        lane.header("c15", 0, 100_000, 100_000, int(time.time() * 1000), key.sign(payload))
        lane.send(payload[:500])
        t0 = time.monotonic()
        msg = lane.line(timeout=3.5)
        dt = time.monotonic() - t0
        ok = state.get("ack_bytes") == 1_000_000 and msg == {"ack": "c15", "have": 500} and dt < 3.0
        lane.close()
        return check("15 time-based ack within 3 s", ok, f"{json.dumps(msg)} after {dt:.2f}s")
    finally:
        hub.stop()


def stats_per_append_case(key, pub_b64: str) -> int:
    """bytes_carried in stream_stats.json follows the .part per append, not
    per ack: with the byte ack out of reach and the 2 s time ack not yet due,
    header + 5000 B must show bytes_carried == 5000 within 0.5 s."""
    run_dir = new_run_dir()
    hub = HubProc(run_dir, ["--stream-ack-bytes", "1000000"])
    try:
        lane = Lane()
        lane.hello(pub_b64, [])
        payload = payload_of(100_000, 16)
        lane.header("c16", 0, 100_000, 100_000, int(time.time() * 1000), key.sign(payload))
        lane.send(payload[:5000])
        t0 = time.monotonic()
        carried = -1
        while time.monotonic() - t0 < 0.5:
            carried = stats(run_dir)["bytes_carried"]
            if carried == 5000:
                break
            time.sleep(0.02)
        dt = time.monotonic() - t0
        part = run_dir / "stream" / "c16.part"
        part_size = part.stat().st_size if part.exists() else -1
        ok = carried == 5000 and part_size == 5000 and dt < 0.5
        lane.close()
        return check("16 stats bytes_carried follows the .part within 0.5 s", ok,
                     f"bytes_carried={carried} part={part_size} after {dt:.2f}s")
    finally:
        hub.stop()


def main() -> int:
    key = Ed25519PrivateKey.generate()
    pub_b64 = b64(key)
    failures = 0
    run_dir = new_run_dir()
    hub = HubProc(run_dir, [])
    try:
        register_key(pub_b64)
        failures += main_cases(run_dir, hub, key, pub_b64)
    finally:
        hub.stop()
    failures += stall_case(pub_b64)
    failures += time_ack_case(key, pub_b64)
    failures += stats_per_append_case(key, pub_b64)
    print(f"failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
