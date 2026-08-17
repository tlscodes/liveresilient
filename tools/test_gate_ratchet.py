"""Prove both failure directions of the gate-traceability ratchet.

A guard that has only ever been observed passing is not a guard: nothing
distinguishes "no gap exists" from "the check cannot see a gap". So this drives
the real `do_check()` against the real repository, mutating only the two
accounting lists, and asserts the exit code each way:

  1  a gate unproven and unlisted     -> must FAIL, and name it
  2  a gate listed but already proven -> must FAIL, and say it is stale
  3  the shipped lists, untouched     -> must PASS

Runs in well under a second and needs no SDK, which is why it can be a CI step
next to the check it verifies.

    python3 tools/test_gate_ratchet.py
"""

import contextlib
import importlib.util
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools', 'label_gates.py')

spec = importlib.util.spec_from_file_location('label_gates', SRC)
lg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lg)

# Probe the SAME data the check actually runs on. The backlog moved out of
# label_gates.py into docs/gate_backlog.json (see tools/gate_ratchet.py for why),
# so a proof that exercised the module's own stale dicts would be measuring
# something no longer in use — a subtler version of the adjacent-proof mistake
# this whole exercise is about.
ratchet_spec = importlib.util.spec_from_file_location(
    'gate_ratchet', os.path.join(ROOT, 'tools', 'gate_ratchet.py'))
gate_ratchet = importlib.util.module_from_spec(ratchet_spec)
ratchet_spec.loader.exec_module(gate_ratchet)
lg.BLOCKED, lg.IN_FLIGHT, _measured_below = gate_ratchet.load_backlog()

fails = 0


def run(label, want, mutate=None):
    """Run do_check() under a mutation, restore the lists, report the code."""
    global fails
    saved_b, saved_f = dict(lg.BLOCKED), dict(lg.IN_FLIGHT)
    if mutate:
        mutate()
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = lg.do_check()
    finally:
        lg.BLOCKED.clear()
        lg.BLOCKED.update(saved_b)
        lg.IN_FLIGHT.clear()
        lg.IN_FLIGHT.update(saved_f)
    ok = rc == want
    print('%s %-46s rc=%d want=%d' % ('PASS' if ok else 'FAIL', label, rc, want))
    if not ok:
        fails += 1
        print(buf.getvalue())
    return buf.getvalue()


def says(out, needle, what):
    """A failing guard must also be diagnosable, not merely non-zero."""
    global fails
    if needle in out:
        print('PASS %s' % what)
    else:
        print('FAIL %s' % what)
        fails += 1


# Pick the probes from the lists themselves rather than hardcoding ids, so this
# file does not go stale the moment a gate closes and its line is deleted.
#
# BORROW FROM EITHER LIST (2026-08-17). The probe used to come from IN_FLIGHT
# only, and the day that list emptied — gate 2c closed — the probe silently
# turned into a SKIP. A proof that skips its own failure direction when the data
# happens to be shaped a certain way is the thing this file exists to prevent,
# so it now falls back to BLOCKED, which is non-empty whenever anything is
# unproven at all. It can only skip when every gate is proven, and then there is
# genuinely no gap to borrow.
if lg.IN_FLIGHT:
    probe_list, probe_name = lg.IN_FLIGHT, 'in_flight'
else:
    probe_list, probe_name = lg.BLOCKED, 'blocked'
unlisted_probe = sorted(probe_list)[0] if probe_list else None
proven_probe = '3a'  # labelled by name in a test file; asserted below

if unlisted_probe:
    out = run('unlisted gap fails (borrowed from %s)' % probe_name, 1,
              lambda: probe_list.pop(unlisted_probe))
    says(out, 'unaccounted for', 'the failure names the unaccounted gate')
else:
    print('SKIP unlisted gap probe (every gate is proven — no gap to borrow)')

out = run('stale entry fails', 1,
          lambda: lg.IN_FLIGHT.update(
              {proven_probe: 'deliberately stale, probe only'}))
says(out, 'proven now', 'the failure says the entry is stale')

run('shipped lists pass', 0)

print('RATCHET PROOF PASSED' if not fails else 'RATCHET PROOF FAILED')
sys.exit(1 if fails else 0)
