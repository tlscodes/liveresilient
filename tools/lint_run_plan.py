"""Lint an AUTORUN plan against the four driver guards, before arming it.

The driver enforces these at every stop. Checking them here means a defective
plan is caught in seconds rather than hours into an unattended run:

  A  the plan must have steps at all
  B  every step except the last carries arm_next — the continuation must be
     running in the background before the turn ends, or nothing wakes the run
  C  the run carries goal_verify_cmd — "all my steps passed" is a different
     claim from "the goal is met", and only the second is worth reporting
  D  every step carries verify_cmd (a step without one can never close), and
     the LAST step carries no arm_next (it would demand a continuation that
     cannot exist)

Usage:  python3 tools/lint_run_plan.py [.autorun/run.json]
"""

import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else '.autorun/run.json'
run = json.load(open(path, encoding='utf-8'))
steps = run.get('steps') or []
fail = []

print('plan: %s' % path)
print('  steps: %d' % len(steps))

if not steps:
    fail.append('A  no steps — an armed run with no plan blocks forever')

no_verify = [s.get('id', '?') for s in steps if not s.get('verify_cmd')]
if no_verify:
    fail.append('D  steps without verify_cmd can never close: %s'
                % ', '.join(no_verify))

if len(steps) > 1:
    unarmed = [s.get('id', '?') for s in steps[:-1] if not s.get('arm_next')]
    if unarmed:
        fail.append('B  non-final steps without arm_next: %s'
                    % ', '.join(unarmed))
    print('  arm_next on non-final steps: %d of %d'
          % (sum(1 for s in steps[:-1] if s.get('arm_next')), len(steps) - 1))

if steps and 'arm_next' in steps[-1]:
    fail.append('D  the last step (%s) carries arm_next; it would demand a '
                'continuation that cannot exist' % steps[-1].get('id', '?'))

if not run.get('goal_verify_cmd'):
    fail.append('C  no goal_verify_cmd — the run could report done on a plan '
                'that was incomplete')

print('  goal_verify_cmd: %s' % ('present' if run.get('goal_verify_cmd')
                                 else 'MISSING'))

if fail:
    print('\nPLAN LINT FAILED')
    for f in fail:
        print('  %s' % f)
    sys.exit(1)
print('\nPLAN LINT PASSED — this plan satisfies all four driver guards')
