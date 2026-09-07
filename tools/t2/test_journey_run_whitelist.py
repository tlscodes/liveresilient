#!/usr/bin/env python3
"""Proof of the `whitelist` profile's two preconditions in tools/t2/journey_run.sh
without pf, sudo, a relay, a phone or a rig.

Two defects are pinned here, both of which cost a whole rig run when they were
live (2026-09-05):

  * The reset control aimed at 192.168.2.9. That address is inside the phone's
    own 192.168.2.0/24 on bridge100 and nothing answers ARP for it, so the phone
    never put a SYN on the wire and pf's `block return-rst ... to any port 443`
    (net_shape.sh:558) could never fire. The control returned EHOSTUNREACH on a
    perfectly filtered network AND on a completely unfiltered one: it measured
    an absent host, not the filter. The runner now aims both negative controls
    at an address whose SYN is guaranteed to reach pf, and refuses an override
    that reintroduces the on-link decoy.
  * The relay precondition was `curl -sk ... >/dev/null`, which exits 0 for ANY
    status. A relay still running from before the ordinary-service page answers
    426 with an empty body and logs no room_rendezvous_complete, so the run
    proceeded through the fixtures, coturn, the pf load, a ~20 min build, the
    phone launch and a whole call before both whitelist rows came back witness-
    less. The runner now restarts the relay from source (so $RELAY_LOG and the
    answering process are one) and requires the literal status 200, before the
    fixtures and before anything privileged.

The negative-path tests run the real script with a stub PATH and a stub relay
restarter, and stop it at the fixture-script gate, so nothing here touches pf,
sudo, the hub port, the relay port or the phone.

USAGE  python3 tools/t2/test_journey_run_whitelist.py     -> exit 0 on PASS
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The runner under test. The env seam exists so a mutation check can point this
# suite at a deliberately broken copy and prove the checks can fail; the rig
# always runs it against the real file.
RUNNER = os.environ.get("JOURNEY_RUNNER_UNDER_TEST", os.path.join(HERE, "journey_run.sh"))
FAILURES = []
CHECKS = [0]

# An interface name that exists on no Mac: SELF stays empty, so the dry print
# falls back to the design's default allowed address and nothing is read off a
# live bridge.
NO_IFACE = "t2test0"


def check(name, condition, detail=""):
    CHECKS[0] += 1
    if not condition:
        FAILURES.append(f"{name}: {detail}")


def run(env_extra, args=("whitelist",), expect_rc=None):
    env = dict(os.environ)
    env.pop("RELAY_LOG", None)
    env["T2_IFACE"] = NO_IFACE
    env.update(env_extra)
    proc = subprocess.run([RUNNER, *args], capture_output=True, text=True,
                          env=env, timeout=120)
    if expect_rc is not None:
        check(f"exit code of {args} with {sorted(env_extra)}",
              proc.returncode == expect_rc,
              f"wanted {expect_rc}, got {proc.returncode}; stderr={proc.stderr[-300:]!r}")
    return proc


def dry(env_extra=None, expect_rc=0):
    return run({**(env_extra or {}), "JOURNEY_DRY": "1"}, expect_rc=expect_rc)


def field(pattern, text, name):
    m = re.search(pattern, text)
    check(f"{name} present", m is not None, f"no {pattern!r} in output")
    return m.group(1) if m else ""


# --- 1. the reset control's destination is one the phone's SYN can reach ------
out = dry().stdout
allow = field(r"allow=([0-9.]+),", out, "shaper allow= address")
tcp_list = field(r"tcp=([0-9+]+),", out, "shaper tcp= allow list")
rst = field(r"rst=(\d+)", out, "shaper rst= port")
blocked = field(r'"blocked_host":"([0-9.]+)"', out, "job blocked_host")
rst_port = field(r'"rst_port":(\d+)', out, "job rst_port")
quic_port = field(r'"quic_port":(\d+)', out, "job quic_port")

check("the blocked host is no longer the unreachable on-link decoy",
      blocked != "192.168.2.9",
      "192.168.2.9 is on-link for the phone with nothing answering its ARP")
check("the blocked host is an address this Mac holds on the bridge, so it answers ARP itself",
      blocked == allow, f"blocked_host={blocked} allow={allow}")
check("both negative controls use one port, the single-source 443",
      rst == rst_port == quic_port == "443",
      f"rst={rst} rst_port={rst_port} quic_port={quic_port}")
check("that port is NOT in the allow list, so the packet reaches the return-rst rule",
      rst not in tcp_list.split("+"), f"port {rst} is inside tcp={tcp_list}")
check("the row's note names the destination and why it reaches pf",
      f"reset_control={blocked}:443" in out and "on-link" in out
      and "block return-rst" in out,
      "no reset_control note in the dry print")

# --- 2. an override cannot reintroduce the on-link decoy ---------------------
bad = run({"JOURNEY_DRY": "1", "JOURNEY_WHITELIST_BLOCKED_HOST": "192.168.2.9"},
          expect_rc=1)
check("the refusal names the ARP failure the decoy causes",
      "ARP" in bad.stderr and "SYN" in bad.stderr,
      f"stderr={bad.stderr[-200:]!r}")
check("the refusal happens before any shaper or job line is printed",
      "shaper" not in bad.stdout and "blocked_host" not in bad.stdout,
      f"stdout={bad.stdout[-200:]!r}")

# An off-link decoy is the other faithful choice and stays available; its note
# says plainly that it rests on the phone's default route, which this Mac
# cannot verify.
off = dry({"JOURNEY_WHITELIST_BLOCKED_HOST": "203.0.113.9"})
check("an off-link decoy is accepted",
      '"blocked_host":"203.0.113.9"' in off.stdout, off.stdout[-200:])
check("and its note states the assumption it rests on",
      "operator-set" in off.stdout and "default route" in off.stdout,
      off.stdout[-300:])

# The refuter's other remedy stays legal: an on-link decoy that this Mac DOES
# answer ARP for (`ifconfig bridge100 alias 192.168.2.9/32`) is accepted, and
# the note says which of the three shapes was chosen.
with tempfile.TemporaryDirectory() as _alias_tmp:
    _bin = os.path.join(_alias_tmp, "bin")
    os.makedirs(_bin)
    with open(os.path.join(_bin, "ifconfig"), "w", encoding="utf-8") as _fh:
        _fh.write('#!/bin/sh\necho "\tinet 192.168.2.1 netmask 0xffffff00"\n'
                  'echo "\tinet 192.168.2.9 netmask 0xffffffff"\n')
    os.chmod(os.path.join(_bin, "ifconfig"), 0o755)
    alias = dry({"PATH": _bin + os.pathsep + os.environ.get("PATH", ""),
                 "T2_IFACE": "bridge100",
                 "JOURNEY_WHITELIST_BLOCKED_HOST": "192.168.2.9"})
    check("an on-link decoy this Mac answers ARP for is accepted",
          '"blocked_host":"192.168.2.9"' in alias.stdout, alias.stdout[-300:])
    check("and the note calls it an alias, not an off-link address",
          "an alias on bridge100" in alias.stdout, alias.stdout[-300:])

# --- 3. the dry print names the relay precondition --------------------------
check("the dry print names the restart from source",
      "relay_restart.sh" in out and "RELAY_LOG=" in out, out[:400])
check("the dry print names the 200 requirement and what a 426 means",
      "must print 200" in out and "426" in out, out[:400])


# --- 4. the precondition itself, against a stub relay ------------------------
def stub_run(status, tmp, fixtures="/nonexistent/journey_fixtures.sh"):
    """Run the real script with a stub curl, ifconfig and relay restarter.

    Nothing privileged is reachable: the script is stopped at the fixture-script
    gate, which is before the shaper, the traps, coturn, the hub and the phone.
    """
    binaries = os.path.join(tmp, "bin")
    os.makedirs(binaries, exist_ok=True)
    marker = os.path.join(tmp, "restart.log")
    # curl: the door probe's status code on stdout for the -w form, nothing else.
    write_stub(os.path.join(binaries, "curl"),
               f'#!/bin/sh\nprintf "{status}"\nexit 0\n')
    # ifconfig: a bridge that exists and holds the design's allowed address.
    write_stub(os.path.join(binaries, "ifconfig"),
               '#!/bin/sh\necho "\tinet 192.168.2.1 netmask 0xffffff00 broadcast 192.168.2.255"\n')
    write_stub(os.path.join(tmp, "relay_restart_stub.sh"),
               f'#!/bin/sh\necho "$RELAY_LOG $*" >>"{marker}"\n'
               'echo "signaling_server.dart --port $1"\n')
    env = {"PATH": binaries + os.pathsep + os.environ.get("PATH", ""),
           "HOME": tmp,
           "TMPDIR": tmp,
           "JOURNEY_RELAY_RESTART": os.path.join(tmp, "relay_restart_stub.sh"),
           "JOURNEY_FIXTURES": fixtures}
    proc = run(env)
    log = open(marker).read() if os.path.exists(marker) else ""
    return proc, log


def write_stub(path, body):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(path, 0o755)


with tempfile.TemporaryDirectory() as tmp:
    stale, log = stub_run("426", tmp)
    check("a relay answering 426 stops the run", stale.returncode != 0,
          f"rc={stale.returncode}")
    check("the refusal names the status seen and the status needed",
          "426" in stale.stderr and "200" in stale.stderr,
          f"stderr={stale.stderr[-300:]!r}")
    check("the refusal names the missing rendezvous witness",
          "room_rendezvous_complete" in stale.stderr, stale.stderr[-300:])
    check("nothing was built before the refusal",
          "fixtures  " not in stale.stdout and "turn " not in stale.stdout,
          f"stdout={stale.stdout[-300:]!r}")
    check("the relay was restarted from source first",
          log.strip().endswith("4443"), f"restart log={log!r}")
    check("and it was restarted with the same RELAY_LOG the rows are read from",
          bool(log.split()) and log.split()[0].endswith("signaling_relay_4443.log"),
          f"restart log={log!r}")

with tempfile.TemporaryDirectory() as tmp:
    good, log = stub_run("200", tmp)
    check("a relay answering 200 passes the precondition",
          "ordinary-service page 200" in good.stdout, good.stdout[-300:])
    # The property is that the runner STOPS at a named precondition rather
    # than continuing silently. Which precondition it names first belongs to
    # the host, not to the runner: this Mac reaches the fixture check, while
    # the Linux CI runner stops earlier on `say`, a macOS-only tool the media
    # probes need. Pinning the fixture message alone measured the host and
    # failed on the runner with every other check green.
    check("and the run then stops at a named precondition, not past it silently",
          good.returncode != 0
          and ("fixture script missing" in good.stderr
               or "missing tool" in good.stderr),
          f"rc={good.returncode} stderr={good.stderr[-200:]!r}")

# --- 5. the other profiles keep the soft note, not this gate ----------------
src = open(RUNNER, encoding="utf-8").read()
check("the strict precondition is whitelist-only",
      'if [ "$PROFILE" = whitelist ]; then\n  [ -x "$RELAY_RESTART" ]' in src,
      "the whitelist guard around the relay restart is gone")
check("the other profiles still only get a note",
      'if [ "$PROFILE" != whitelist ]; then\n  curl -sk --max-time 5' in src,
      "the soft probe for the other profiles is gone")

if FAILURES:
    print(f"FAIL {len(FAILURES)} of {CHECKS[0]} checks")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print(f"PASS {CHECKS[0]} checks (journey_run.sh whitelist preconditions)")
