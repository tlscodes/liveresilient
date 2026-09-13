#!/usr/bin/env python3
"""Proof of the `whitelist` rule set without root, pf, or the phone.

Everything here runs `bash net_shape.sh whitelist-print <spec>` as a
subprocess. That subcommand shares whitelist_rules() with `whitelist`, so what
is pinned below is literally the text pf is handed. Pinned: the exact nine
lines for the reference spec, their ORDER (the stateful pass rules before the
stateless catch-all pass before the return-rst rule before the IPv4 inbound
catch-all drop before the two inet6 drops, compared by index), the port-list
rendering, a single port, the rst override and its 443 default, refusal on a
malformed spec with no rules printed, and the absence of any dummynet/pipe rule
— a filter profile that quietly shaped traffic would be a different experiment
than the one the row claims.

Also pinned: the optional `udp=<port>` key, which adds ONE more allowed UDP port
to the allowed host (the rig's DNS responder listens on 5300 because binding 53
needs root). Its pair of pass rules sits with the other passes, UDP 53 keeps
passing either way, a malformed port prints no rule at all, and a spec without
the key prints the same nine lines it printed before the key existed — that
last one is the check that keeps this a purely additive change.

Three of those checks exist because the rules were wrong once:

  * Every rule was `in` until 2026-09-13, so a Mac-originated packet to a port
    that is not on the allow list matched nothing in this anchor and fell
    through to the Internet Sharing anchor macOS evaluates after it, which
    state-creates anything on bridge100 (`flags any`, so even a mid-stream
    packet does it). pf checks the state table before any rule, so the peer's
    answer rode that state back in and the inbound catch-all was never
    evaluated (Evaluations 0 on the rig). The repair is a STATELESS pass, not a
    drop: a drop fails connect() locally with an errno, which tcp_door_probe.py
    reports as `error:<n>` — a failed verdict that also misdescribes the wire.
    `stateless pass present`, `keep-state passes first` and `stateless before
    rst` pin the rule that keeps this anchor self-contained; the inbound drop
    is `inet from any to any` for the same reason, so no second address on the
    bridge is left undecided here.
  * (2026-09-05) Every pass/block rule carries an IPv4 literal, so pf compiles it with
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
    f"pass  out quick on {IFACE} inet from 192.168.2.1 to 192.168.2.2 no state",
    f"block return-rst in quick on {IFACE} proto tcp from 192.168.2.2 to any port 443",
    f"block drop        in quick on {IFACE} inet from any to any",
    f"block drop        out quick on {IFACE} inet6 all",
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
    failures += check("rule count", len(got) == 9, f"{len(got)} lines")
    for i, want in enumerate(EXPECTED):
        have = got[i] if i < len(got) else "<missing>"
        failures += check(f"line {i}", have == want, repr(have) if have != want else "")

    # Order is the rule: first match wins under `quick`. Every STATEFUL pass
    # must precede the stateless catch-all pass — a flow that matched the
    # stateless rule first would create no state, and its reply would meet the
    # inbound drop. The stateless pass then precedes the reset, and the reset
    # precedes the inbound catch-all drop. Each rule is located by a prefix long
    # enough to tell it from its neighbours: `inet from` never matches the
    # `inet6 from` line.
    def idx(prefix: str) -> int:
        for i, ln in enumerate(got):
            if ln.startswith(prefix):
                return i
        return -1

    STATELESS_OUT = "pass  out quick on %s inet from" % IFACE
    IN_DROP = "block drop        in quick on %s inet from" % IFACE
    V6_OUT = "block drop        out quick on %s inet6 all" % IFACE
    V6_IN = "block drop        in quick on %s inet6 from" % IFACE

    i_rst = idx("block return-rst")
    i_out = idx(STATELESS_OUT)
    i_drop = idx(IN_DROP)
    i_keep_last = max(
        (i for i, ln in enumerate(got) if ln.startswith("pass ") and ln.endswith("keep state")),
        default=-1,
    )
    failures += check("passes before rst", 0 <= i_keep_last < i_rst, f"{i_keep_last} < {i_rst}")
    failures += check("rst before drop", 0 <= i_rst < i_drop, f"{i_rst} < {i_drop}")
    # Without this rule a Mac-originated packet to a non-allowed port matches
    # nothing here and the next anchor state-creates it, after which the peer's
    # answer is passed by that state and the inbound drops never run. It is a
    # PASS with `no state`, not a drop: the SYN has to reach the wire for the
    # probe's timeout to mean anything about the wire.
    failures += check("stateless pass present", i_out >= 0, f"index {i_out}")
    failures += check(
        "stateless pass is stateless",
        i_out >= 0 and got[i_out].endswith(" no state"),
        got[i_out] if i_out >= 0 else "<missing>",
    )
    failures += check("keep-state passes first", 0 <= i_keep_last < i_out, f"{i_keep_last} < {i_out}")
    failures += check("stateless before rst", 0 <= i_out < i_rst, f"{i_out} < {i_rst}")
    # The inbound catch-all decides EVERY inbound IPv4 packet on the interface,
    # not only the peer's: the next anchor state-creates on `flags any`, so an
    # address this rule left undecided would be admitted there.
    failures += check(
        "inbound drop is interface-wide",
        i_drop >= 0 and got[i_drop].endswith("inet from any to any"),
        got[i_drop] if i_drop >= 0 else "<missing>",
    )

    # The IPv4 rules cannot match an IPv6 packet (pf fixes the family from the
    # address literals), so the family is closed by its own rules — both
    # directions, because an undecided outbound v6 packet state-creates in the
    # next anchor exactly as an IPv4 one did — and the inbound one is last:
    # nothing may be added after a catch-all.
    i_v6_out = idx(V6_OUT)
    i_v6 = idx(V6_IN)
    failures += check("inet6 out drop", i_v6_out >= 0, f"index {i_v6_out}")
    failures += check("inet6 catch-all", i_v6 >= 0, f"index {i_v6}")
    failures += check("inet6 last", i_v6 == len(got) - 1, f"{i_v6} of {len(got) - 1}")
    failures += check("drop before inet6", 0 <= i_drop < i_v6_out < i_v6, f"{i_drop} < {i_v6_out} < {i_v6}")
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
        len(one) == 9 and "port { 4443 }" in one[0] and "port { 4443 }" in one[1],
        one[0] if one else "<no output>",
    )

    over = lines("peer=192.168.2.2,allow=192.168.2.1,tcp=4443,rst=8443")
    failures += check(
        "rst override",
        len(over) == 9 and over[5].endswith("to any port 8443"),
        over[5] if len(over) > 5 else "<no output>",
    )
    failures += check(
        "rst default 443",
        len(one) == 9 and one[5].endswith("to any port 443"),
        one[5] if len(one) > 5 else "<no output>",
    )

    failures += check(
        "no dummynet rule",
        not any("dummynet" in ln or "pipe " in ln for ln in got),
        "filter only",
    )

    # --- the optional udp=<port> key ----------------------------------------
    # The rig's authoritative DNS responder cannot bind port 53 (that needs
    # root, and this rig grants only the shaper), so the filter must be able to
    # allow ONE more UDP port to the allowed host. With no udp= in the spec the
    # output is byte-for-byte what it was before the key existed — that is what
    # `rule count` and the `line N` checks above already pin, since SPEC carries
    # no udp= field.
    udp_spec = SPEC + ",udp=5300"
    ures = run(udp_spec)
    udp_got = [ln for ln in ures.stdout.splitlines() if ln.strip()]
    failures += check("udp exit code", ures.returncode == 0, f"rc={ures.returncode}")
    failures += check("udp rule count", len(udp_got) == 11, f"{len(udp_got)} lines")
    failures += check(
        "udp keeps four passes",
        udp_got[:4] == EXPECTED[:4],
        repr(udp_got[:4]) if udp_got[:4] != EXPECTED[:4] else "",
    )
    want_udp = [
        f"pass  out quick on {IFACE} proto udp from 192.168.2.1 to 192.168.2.2 port 5300 keep state",
        f"pass  in  quick on {IFACE} proto udp from 192.168.2.2 to 192.168.2.1 port 5300 keep state",
    ]
    failures += check(
        "udp pair at 4 and 5",
        udp_got[4:6] == want_udp,
        repr(udp_got[4:6]) if udp_got[4:6] != want_udp else "",
    )
    failures += check(
        "udp 53 still passes",
        sum(1 for ln in udp_got if "proto udp" in ln and "port 53 " in ln) == 2,
        "the key ADDS a port; it does not replace 53",
    )
    failures += check(
        "udp keeps block rules",
        udp_got[6:] == EXPECTED[4:],
        repr(udp_got[6:]) if udp_got[6:] != EXPECTED[4:] else "",
    )

    # Order is the rule under `quick`, so it is re-asserted on the eleven-line
    # output rather than assumed to have survived the new pair.
    def uidx(prefix: str) -> int:
        for i, ln in enumerate(udp_got):
            if ln.startswith(prefix):
                return i
        return -1

    u_rst = uidx("block return-rst")
    u_out = uidx(STATELESS_OUT)
    u_drop = uidx(IN_DROP)
    u_v6_out = uidx(V6_OUT)
    u_v6 = uidx(V6_IN)
    u_keep_last = max(
        (i for i, ln in enumerate(udp_got) if ln.startswith("pass ") and ln.endswith("keep state")),
        default=-1,
    )
    failures += check("udp passes before rst", 0 <= u_keep_last < u_rst, f"{u_keep_last} < {u_rst}")
    failures += check("udp rst before drop", 0 <= u_rst < u_drop, f"{u_rst} < {u_drop}")
    failures += check("udp stateless pass present", u_out >= 0, f"index {u_out}")
    failures += check("udp keep-state passes first", 0 <= u_keep_last < u_out, f"{u_keep_last} < {u_out}")
    failures += check("udp stateless before rst", 0 <= u_out < u_rst, f"{u_out} < {u_rst}")
    failures += check("udp inet6 out drop", u_v6_out >= 0, f"index {u_v6_out}")
    failures += check("udp drop before inet6", 0 <= u_drop < u_v6_out < u_v6,
                      f"{u_drop} < {u_v6_out} < {u_v6}")
    failures += check("udp inet6 last", u_v6 == len(udp_got) - 1, f"{u_v6} of {len(udp_got) - 1}")
    failures += check(
        "udp no inet6 pass",
        not any(ln.startswith("pass ") and "inet6" in ln for ln in udp_got),
        "inet6 is dropped, never allowed",
    )
    failures += check(
        "udp no dummynet rule",
        not any("dummynet" in ln or "pipe " in ln for ln in udp_got),
        "filter only",
    )
    failures += check(
        "no udp key, no udp rule",
        len(one) == 9 and not any("5300" in ln for ln in one),
        f"{len(one)} lines",
    )

    # The usage text is part of the contract: a help string that misdescribes
    # the spec is the same defect class as an unstated rule.
    usage = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True,
                           timeout=20, env=dict(os.environ, T2_IFACE=IFACE))
    usage_text = usage.stdout + usage.stderr
    failures += check("usage names udp key", "udp=<port>" in usage_text,
                      "the spec line does not name the key")

    bad = [
        ("no peer", "allow=192.168.2.1,tcp=4443"),
        ("no allow", "peer=192.168.2.2,tcp=4443"),
        ("empty tcp", "peer=192.168.2.2,allow=192.168.2.1,tcp="),
        ("non-numeric port", "peer=192.168.2.2,allow=192.168.2.1,tcp=44a3"),
        ("port 0", "peer=192.168.2.2,allow=192.168.2.1,tcp=0"),
        ("port 65536", "peer=192.168.2.2,allow=192.168.2.1,tcp=65536"),
        ("bad rst", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,rst=70000"),
        # The udp port reaches the rule text by interpolation exactly as rst
        # does, so it is refused on the same table and prints no rule.
        ("udp port 0", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,udp=0"),
        ("udp non-numeric", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,udp=x"),
        ("udp port 65536", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,udp=65536"),
        ("udp rule text", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,udp=53 keep state"),
        ("still refuses unknown keys", "peer=192.168.2.2,allow=192.168.2.1,tcp=4443,udpx=5300"),
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
