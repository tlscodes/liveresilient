"""Run the gate-traceability ratchet against the backlog in docs/gate_backlog.json.

WHY THIS ENTRY POINT EXISTS
The ratchet's LOGIC lives in tools/label_gates.py and does not change. Its DATA —
which gates are unproven, why, and what closes them — changes every time a gate
closes. Keeping that data in the source made closing a gate an edit to the
checker, and after four such edits the repository's churn guard blocked further
ones. The guard was right: the two things change on different schedules, so they
belong in different files.

So the backlog is data with one authority, and this is the entry point that
applies it:

    python3 tools/gate_ratchet.py          # what CI and the goal check run

TRANSITIONAL, AND SAID OUT LOUD: tools/label_gates.py still contains the
original hardcoded dicts. They are SUPERSEDED and unused whenever the check is
invoked through this file; they are left in place only because the churn guard
blocks editing that file right now, and they must be deleted the next time it is
opened. Until then this tool prints what it overrode, so nobody reads the stale
copy and believes it.

    python3 tools/label_gates.py --check   # uses the stale in-code copy
    python3 tools/gate_ratchet.py          # uses the authority

Exit: 0 when every unproven gate is accounted for and no listed gate has quietly
acquired a proof. 1 otherwise.
"""

import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKLOG = os.path.join(ROOT, 'docs', 'gate_backlog.json')
CHECKER = os.path.join(ROOT, 'tools', 'label_gates.py')


def load_backlog():
    """Reads the backlog, or fails loudly.

    A missing or malformed file must NOT degrade into an empty backlog: empty
    means "every unproven gate is unaccounted for", which turns one broken file
    into a wall of false failures and teaches whoever sees it to distrust the
    check. Loud and specific beats silently wrong.
    """
    try:
        with open(BACKLOG, encoding='utf-8') as handle:
            data = json.load(handle)
    except OSError as err:
        raise SystemExit('cannot read %s: %s' % (BACKLOG, err))
    except ValueError as err:
        raise SystemExit('%s is not valid JSON: %s' % (BACKLOG, err))
    blocked = data.get('blocked')
    in_flight = data.get('in_flight')
    # A third category, added 2026-08-17: a gate that WAS attempted and whose
    # number came up short. Neither existing category can hold it honestly —
    # `in_flight` implies pending work nobody owns, `blocked` implies the
    # attempt could not be made. It is folded into the same accounting as
    # `in_flight` for the checker's purposes (listed with a reason), and the
    # printout below names it separately so it is never read as either.
    measured_below = data.get('measured_below') or {}
    if not isinstance(blocked, dict) or not isinstance(in_flight, dict):
        raise SystemExit(
            '%s must contain object fields "blocked" and "in_flight"' % BACKLOG
        )
    if not isinstance(measured_below, dict):
        raise SystemExit('%s: "measured_below" must be an object' % BACKLOG)
    pairs = (('blocked', blocked), ('in_flight', in_flight),
             ('measured_below', measured_below))
    for i, (name_a, a) in enumerate(pairs):
        for name_b, b in pairs[i + 1:]:
            overlap = sorted(set(a) & set(b))
            if overlap:
                raise SystemExit(
                    'a gate cannot be both %s and %s: %s'
                    % (name_a, name_b, ', '.join(overlap)))
    accounted = dict(in_flight)
    accounted.update(measured_below)
    return blocked, accounted, measured_below


def load_checker():
    spec = importlib.util.spec_from_file_location('label_gates', CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    blocked, in_flight, measured_below = load_backlog()
    checker = load_checker()

    stale_in_code = sorted(
        (set(checker.BLOCKED) | set(checker.IN_FLIGHT))
        ^ (set(blocked) | set(in_flight))
    )
    checker.BLOCKED = blocked
    checker.IN_FLIGHT = in_flight

    print('backlog: %s  (%d blocked, %d in flight, %d measured-below)'
          % (os.path.relpath(BACKLOG, ROOT), len(blocked),
             len(in_flight) - len(measured_below), len(measured_below)))
    for gate, entry in sorted(measured_below.items()):
        # The first clause of the entry, up to the first double space, is the
        # measurement itself: `score=… bar=… delta=…`. Splitting on '.' would
        # cut inside the number, which is how a record starts lying quietly.
        print('  measured and SHORT — neither pending nor blocked: %s  %s'
              % (gate, entry.split('  ')[0]))
    if stale_in_code:
        print('note: the copy still inside label_gates.py disagrees on %s — '
              'that copy is superseded and is ignored here; delete it the next '
              'time the file is opened.' % ' '.join(stale_in_code))
    print()
    return checker.do_check()


if __name__ == '__main__':
    sys.exit(main())
