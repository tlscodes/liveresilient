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
lg.BLOCKED, lg.IN_FLIGHT = gate_ratchet.load_backlog()

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
in_flight_probe = sorted(lg.IN_FLIGHT)[0] if lg.IN_FLIGHT else None
proven_probe = '3a'  # labelled by name in a test file; asserted below

if in_flight_probe:
    out = run('unlisted gap fails', 1,
              lambda: lg.IN_FLIGHT.pop(in_flight_probe))
    says(out, 'unaccounted for', 'the failure names the unaccounted gate')
else:
    print('SKIP unlisted gap probe (no in-flight gates left to borrow)')

out = run('stale entry fails', 1,
          lambda: lg.IN_FLIGHT.update(
              {proven_probe: 'deliberately stale, probe only'}))
says(out, 'proven now', 'the failure says the entry is stale')

run('shipped lists pass', 0)

print('RATCHET PROOF PASSED' if not fails else 'RATCHET PROOF FAILED')
sys.exit(1 if fails else 0)
