#!/usr/bin/env python3
"""Proof of the `whitelist` rule set without root, pf, or the phone.

Everything here runs `bash net_shape.sh whitelist-print <spec>` as a
subprocess. That subcommand shares whitelist_rules() with `whitelist`, so what
is pinned below is literally the text pf is handed. Pinned: the exact six
lines for the reference spec, their ORDER (the pass rules before the
return-rst rule before the catch-all drop, compared by index), the port-list
rendering, a single port, the rst override and its 443 default, refusal on a
malformed spec with no rules printed, and the absence of any dummynet/pipe
rule — a filter profile that quietly shaped traffic would be a different
experiment than the one the row claims.

USAGE  python3 tools/t2/test_net_shape_whitelist.py     → exit 0 on PASS
"""
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "net_shape.sh"
IFACE = "bridge100"
SPEC = "peer=192.168.2.2,allow=192.168.2.1,tcp=4443+3478+8765"

EXPECTED = [
    f"pass  out quick on {IFACE} proto tcp from 192.168.2.1 to 192.168.2.2 port {{ 4443, 3478, 8765 }} keep state",
    f"pass  in  quick on {IFACE} proto tcp from 192.168.2.2 to 192.168.2.1 port {{ 4443, 3478, 8765 }} keep state",
    f"pass  out quick on {IFACE} proto udp from 192.168.2.1 to 192.168.2.2 port 53 keep state",
    f"pass  in  quick on {IFACE} proto udp from 192.168.2.2 to 192.168.2.1 port 53 keep state",
    f"block return-rst in quick on {IFACE} proto tcp from 192.168.2.2 to any port 443",
    f"block drop        in quick on {IFACE} from 192.168.2.2 to any",
]


def run(spec: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, T2_IFACE=IFACE)
    return subprocess.run(
        ["bash", str(SCRIPT), "whitelist-print", spec],
        capture_output=True, text=True, timeout=20, env=env,
    )


def lines(spec: str) -> list[str]:
    return [ln for ln in run(spec).stdout.splitlines() if ln.strip()]


def check(label: str, ok: bool, detail: str = "") -> int:
    print(f"{label:<26} {detail} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    failures = 0
    if not SCRIPT.is_file():
        print(f"missing {SCRIPT}")
        return 1

    res = run(SPEC)
    got = [ln for ln in res.stdout.splitlines() if ln.strip()]
    failures += check("exit code", res.returncode == 0, f"rc={res.returncode}")
    failures += check("rule count", len(got) == 6, f"{len(got)} lines")
    for i, want in enumerate(EXPECTED):
        have = got[i] if i < len(got) else "<missing>"
        failures += check(f"line {i}", have == want, repr(have) if have != want else "")

    # Order is the rule: first match wins under `quick`, so the passes must
    # precede the reset, and the reset must precede the catch-all drop.
    def idx(prefix: str) -> int:
        for i, ln in enumerate(got):
            if ln.startswith(prefix):
                return i
        return -1

    i_rst = idx("block return-rst")
    i_drop = idx("block drop")
    i_pass_last = max((i for i, ln in enumerate(got) if ln.startswith("pass ")), default=-1)
    failures += check("passes before rst", 0 <= i_pass_last < i_rst, f"{i_pass_last} < {i_rst}")
    failures += check("rst before drop", 0 <= i_rst < i_drop, f"{i_rst} < {i_drop}")

    failures += check(
        "port list rendering",
        all("port { 4443, 3478, 8765 }" in ln for ln in got[:2]),
        "{ 4443, 3478, 8765 }",
    )

    one = lines("peer=192.168.2.2,allow=192.168.2.1,tcp=4443")
    failures += check(
        "single port",
        len(one) == 6 and "port { 4443 }" in one[0] and "port { 4443 }" in one[1],
        one[0] if one else "<no output>",
    )

    over = lines("peer=192.168.2.2,allow=192.168.2.1,tcp=4443,rst=8443")
    failures += check(
        "rst override",
        len(over) == 6 and over[4].endswith("to any port 8443"),
        over[4] if len(over) > 4 else "<no output>",
    )
    failures += check(
        "rst default 443",
        len(one) == 6 and one[4].endswith("to any port 443"),
        one[4] if len(one) > 4 else "<no output>",
    )

    failures += check(
        "no dummynet rule",
        not any("dummynet" in ln or "pipe " in ln for ln in got),
        "filter only",
    )

    bad = [
        ("no peer", "allow=192.168.2.1,tcp=4443"),
        ("no allow", "peer=192.168.2.2,tcp=4443"),
        ("empty tcp", "peer=192.168.2.2,allow=192.168.2.1,tcp="),
        ("non-numeric port", "peer=192.168.2.2,allow=192.168.2.1,tcp=44a3"),
        ("port 0", "peer=192.168.2.2,allow=192.168.2.1,tcp=0"),
        ("port 65536", "peer=192.168.2.2,allow=192.168.2.1,tcp=65536"),
        ("bad rst", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,rst=70000"),
    ]
    for label, spec in bad:
        r = run(spec)
        printed = [ln for ln in r.stdout.splitlines() if ln.strip()]
        ok = r.returncode != 0 and not printed and r.stderr.strip() != ""
        failures += check(
            f"refuse {label}",
            ok,
            f"rc={r.returncode} out={len(printed)} err={r.stderr.strip().splitlines()[0] if r.stderr.strip() else ''}",
        )

    print(f"failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
