#!/usr/bin/env python3
"""Prove the probe's classifier against the NAT simulator: every mapping and
filtering policy, hairpin on and off, two clients behind the same NAT. A
verdict that disagrees with the configured policy fails the run — the gate
is proven on counterexamples before the probe meets a real operator.

USAGE  sim_matrix.py            (≈ 2 minutes; exit 1 on any mismatch)
"""
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY = sys.executable
REFLECTOR = ("127.0.0.1", 3479)
ALT_PORT = 3489
SIM = "127.0.0.1:4000"

CASES = [
    # mapping, filtering, hairpin
    ("eim", "eif", True),
    ("eim", "adf", True),
    ("eim", "apdf", True),
    ("adm", "eif", False),
    ("apdm", "eif", False),
    ("apdm", "apdf", True),
    ("eim", "eif", False),
    ("adm", "apdf", False),
]


def start(cmd):
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def run_probe(role, room):
    cmd = [PY, str(HERE / "probe.py"), "--via-sim", SIM, "--sim-has-alt", "--hairpin-room", room, "--role", role]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def main() -> int:
    reflector = start([PY, str(HERE / "reflector.py"), "--bind", REFLECTOR[0], "--port", str(REFLECTOR[1]), "--alt-port", str(ALT_PORT)])
    time.sleep(0.5)
    failures = 0
    print(f"{'mapping':8} {'filtering':10} {'hairpin':8} | {'got mapping':12} {'got filtering':14} {'got hairpin':12} verdict")
    try:
        for i, (mapping, filtering, hairpin) in enumerate(CASES):
            cmd = [PY, str(HERE / "nat_sim.py"), "--listen", SIM, "--reflector", f"{REFLECTOR[0]}:{REFLECTOR[1]}",
                   "--alt", f"{REFLECTOR[0]}:{ALT_PORT}", "--mapping", mapping, "--filtering", filtering, "--timeout", "30"]
            if hairpin:
                cmd.append("--hairpin")
            sim = start(cmd)
            time.sleep(0.4)
            room = f"case{i}"
            pa, pb = run_probe("a", room), run_probe("b", room)
            outs = [p.communicate(timeout=60)[0].strip().splitlines()[-1] for p in (pa, pb)]
            sim.terminate()
            sim.wait()
            recs = [json.loads(o) for o in outs]
            got_map = {r["mapping"] for r in recs}
            got_filt = {r["filtering"] for r in recs}
            got_hp = {r["hairpin"] for r in recs}
            # Hairpin punching needs the NAT to route inside-to-inside AND a
            # mapping the peer can hit: with address- or port-dependent
            # mappings each punch opens a NEW outside port while the peer aims
            # at the registered one, so only endpoint-independent filtering
            # lets anything through — the same rule real symmetric NATs impose.
            hp_expected = "yes" if hairpin and (mapping == "eim" or filtering == "eif") else "no"
            ok = got_map == {mapping} and got_filt == {filtering} and got_hp == {hp_expected}
            failures += 0 if ok else 1
            print(f"{mapping:8} {filtering:10} {str(hairpin):8} | {'/'.join(sorted(got_map)):12} {'/'.join(sorted(got_filt)):14} {'/'.join(sorted(got_hp)):12} {'PASS' if ok else 'FAIL'}")
    finally:
        reflector.terminate()
    print(f"cases={len(CASES)} failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
