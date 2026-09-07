#!/usr/bin/env python3
"""Proof of the `whitelist` rule set without root, pf, or the phone.

Everything here runs `bash net_shape.sh whitelist-print <spec>` as a
subprocess. That subcommand shares whitelist_rules() with `whitelist`, so what
is pinned below is literally the text pf is handed. Pinned: the exact seven
lines for the reference spec, their ORDER (the pass rules before the
return-rst rule before the IPv4 catch-all drop before the inet6 catch-all drop,
compared by index), the port-list rendering, a single port, the rst override and
its 443 default, refusal on a malformed spec with no rules printed, and the
absence of any dummynet/pipe rule — a filter profile that quietly shaped traffic
would be a different experiment than the one the row claims.

Two of those checks exist because the rules were wrong once (2026-09-05):

  * Every pass/block rule carries an IPv4 literal, so pf compiles it with
    af=AF_INET and it can never match an IPv6 packet. bridge100 has a live IPv6
    link-local and the phone configures its own, so without a separate inet6
    catch-all an entire family crossed while the row printed "all else
    dropped". `inet6 catch-all` and `inet6 last` pin the closing rule; `no
    inet6 pass` pins that the family is only ever dropped, never allowed.
  * peer and allow are interpolated into the rule text. `allow=any` produced
    `pass ... from <peer> to any port { 4443 }` — the inverse of a whitelist —
    and pf accepts that text. The refusal table now covers wildcard and
    malformed addresses, so that spec cannot print a rule again.

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
    f"block drop        in quick on {IFACE} inet6 from any to any",
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
    failures += check("rule count", len(got) == 7, f"{len(got)} lines")
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

    # The IPv4 rules cannot match an IPv6 packet (pf fixes the family from the
    # address literals), so the family is closed by its own rule, and that rule
    # is the last one: nothing may be added after a catch-all.
    i_v6 = idx("block drop        in quick on %s inet6" % IFACE)
    failures += check("inet6 catch-all", i_v6 >= 0, f"index {i_v6}")
    failures += check("inet6 last", i_v6 == len(got) - 1, f"{i_v6} of {len(got) - 1}")
    failures += check("drop before inet6", 0 <= i_drop < i_v6, f"{i_drop} < {i_v6}")
    failures += check(
        "no inet6 pass",
        not any(ln.startswith("pass ") and "inet6" in ln for ln in got),
        "inet6 is dropped, never allowed",
    )

    failures += check(
        "port list rendering",
        all("port { 4443, 3478, 8765 }" in ln for ln in got[:2]),
        "{ 4443, 3478, 8765 }",
    )

    one = lines("peer=192.168.2.2,allow=192.168.2.1,tcp=4443")
    failures += check(
        "single port",
        len(one) == 7 and "port { 4443 }" in one[0] and "port { 4443 }" in one[1],
        one[0] if one else "<no output>",
    )

    over = lines("peer=192.168.2.2,allow=192.168.2.1,tcp=4443,rst=8443")
    failures += check(
        "rst override",
        len(over) == 7 and over[4].endswith("to any port 8443"),
        over[4] if len(over) > 4 else "<no output>",
    )
    failures += check(
        "rst default 443",
        len(one) == 7 and one[4].endswith("to any port 443"),
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
        # Addresses reach the rule text by interpolation. A wildcard turns the
        # whitelist into its inverse, so these must never print a rule.
        ("wildcard peer", "peer=any,allow=192.168.2.1,tcp=4443"),
        ("wildcard allow", "peer=192.168.2.2,allow=any,tcp=4443"),
        ("unspecified allow", "peer=192.168.2.2,allow=0.0.0.0,tcp=4443"),
        ("zero prefix allow", "peer=192.168.2.2,allow=0.0.0.0/0,tcp=4443"),
        ("octet over 255", "peer=192.168.2.256,allow=192.168.2.1,tcp=4443"),
        ("three octets", "peer=192.168.2,allow=192.168.2.1,tcp=4443"),
        ("five octets", "peer=192.168.2.2.5,allow=192.168.2.1,tcp=4443"),
        ("trailing dot", "peer=192.168.2.,allow=192.168.2.1,tcp=4443"),
        ("prefix out of range", "peer=192.168.2.2/33,allow=192.168.2.1,tcp=4443"),
        ("rule text in allow", "peer=192.168.2.2,allow=192.168.2.1 to any,tcp=4443"),
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
