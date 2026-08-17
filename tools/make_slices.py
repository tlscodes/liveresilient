"""Generate one mechanical slice file per remaining unit, and the run steps.

WHY SLICES
Everything left is either a feature, a measurement or an integration, and each
one wants a different kind of evidence. A single prose plan cannot carry that —
it flattens "author this and prove it red-green" into the same sentence as "run
this and record whatever number it prints". So each remaining unit gets one file
with four fields that a worker can act on without re-reading the conversation:

    SCOPE      the files it may touch, and nothing else
    GATE       the acceptance gate in the plan, quoted
    VERIFY     the exact command whose exit 0 closes it
    REFUSE     what must NOT be done, because each unit has a tempting shortcut

ONE AUTHORITY. The slices and the AUTORUN steps come from the same table below,
so a step can never point at a gate its slice does not describe. Editing the
table regenerates both.

    python3 tools/make_slices.py            # write slices + patch run.json
    python3 tools/make_slices.py --dry-run  # print what would change
"""

import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLICES = os.path.join(ROOT, 'docs', 'slices')
RUNS = ('/Users/behnam/src/ruby-3.3.0/.autorun/run.json',
        os.path.join(ROOT, '.autorun', 'run.json'))
CD = 'cd %s && ' % ROOT
SUITE = 'bash tools/run_suites.sh'
ARM = (CD + '(bash tools/run_suites.sh > /tmp/autorun_next.log 2>&1 &) '
       '&& sleep 1 && pgrep -f run_suites >/dev/null')

# id, title, gate, scope, verify, refuse, author
UNITS = [
    {
        'id': '5e-time-floor-feature',
        'title': 'Gate 5e — the lenient re-check, and a floor a fresh install '
                 'already has',
        'gate': 'Fresh install: a document older than the in-binary floor is '
                'rejected. And the lenient re-check extends to notYetValid, '
                'and reaches the freshly-fetched document path — not only '
                'manifest_cache.dart:152.',
        'scope': [
            'packages/signed_config/lib/src/manifest_cache.dart',
            'packages/signed_config/lib/src/manifest_verifier.dart',
            'packages/signed_config/test/manifest_time_floor_test.dart',
            'packages/signed_config/test/embedded_floor_test.dart  (new)',
        ],
        'verify': (CD + 'grep -rq "test(\'5e" packages/signed_config/test && '
                   + SUITE + ' --only signed_config'),
        'refuse': [
            'Do not widen the relaxation to every rejection reason. Only '
            '`expired` and `notYetValid` are time facts a wrong clock can '
            'manufacture; a bad signature or an unknown key never is, and '
            'relaxing those would turn a clock workaround into an '
            'authentication hole.',
            'Do not read the build time from the filesystem or the clock at '
            'runtime. An in-binary floor that a device can influence is not a '
            'floor — it must be a compile-time constant, and it must say in '
            'its own doc how it is set and what it costs when it goes stale.',
            'Do not let the floor extend a document past its own expiresAt; '
            'gate 5d already pins that and its test must stay green.',
        ],
        'author': 'fable',
    },
    {
        'id': '6d-stale-record-attempt',
        'title': 'Gate 6d — an expired cache with the network down attempts '
                 'the stale record',
        'gate': 'Expired cache + network down -> attempt with the stale '
                'record, not an immediate failure.',
        'scope': [
            'packages/signed_config/lib/src/lookup_cache.dart',
            'packages/signed_config/test/lookup_cache_test.dart',
        ],
        'verify': (CD + 'grep -rq "test(\'6d" packages/signed_config/test && '
                   + SUITE + ' --only signed_config'),
        'refuse': [
            'Do not close this by asserting that a stale entry is RETURNED if '
            'the code merely keeps it. The gate is about what happens when '
            'refresh FAILS: the attempt must be made with the stale value, '
            'and the test has to make refresh fail to prove it.',
            'Do not remove the TTL. One validity authority already exists in '
            'this file; the TTL only schedules a refresh, and conflating the '
            'two is the defect the file was written to avoid.',
            'If the behaviour is already implemented, say so and write the '
            'test only — a feature invented to justify a gate is worse than '
            'a gate closed by a test.',
        ],
        'author': 'fable',
    },
    {
        'id': '2c-replay-measurement',
        'title': 'Gate 2c — run the replay and record the number it prints',
        'gate': 'Replay v4 on the same corpus, total score >= 1.107. Last '
                'recorded: 1.0996 at epoch 4.',
        'scope': [
            'packages/connection_orchestrator/tool/intelligence_replay.dart '
            '(run only, do not edit)',
            'tools/t2/replay_corpus/  (inputs, read only)',
            'docs/GATE_2C_REPLAY.md  (new, the record)',
        ],
        'verify': (CD + 'test -f docs/GATE_2C_REPLAY.md && '
                   'grep -qE "score[^0-9]*1\\.[0-9]{3,4}" '
                   'docs/GATE_2C_REPLAY.md'),
        'refuse': [
            'Do not re-run until the number clears the bar. The first '
            'complete run is the measurement; a second run is only legitimate '
            'if the first was invalid for a stated reason, and then both get '
            'recorded.',
            'Do not tune the scorer, the corpus or the weights to reach '
            '1.107. That converts a measurement into a decoration.',
            'A score below the bar is a real finding about the system and is '
            'recorded as one, with the number, the epoch and the delta.',
        ],
        'author': 'conductor',
    },
    {
        'id': '4-native-tls-integration',
        'title': 'Gates 4a-4g — link the chosen library behind a Dart seam',
        'gate': 'The seven ticket 4 gates. The CHOICE is settled: the section '
                '5 falsification test ran on 2026-08-17 and configuration '
                'alone reproduces the profile. What is open is the '
                'integration and the arm64 capture.',
        'scope': [
            'tools/first_record/  (the instrument, extend for arm64)',
            'packages/adaptive_transport/lib/src/probe_defense/  (the seam)',
            'docs/TICKET4_INTEGRATION.md  (new, the plan and its blockers)',
        ],
        'verify': (CD + 'test -f docs/TICKET4_INTEGRATION.md && '
                   'grep -qE "BLOCKER|blocker" docs/TICKET4_INTEGRATION.md'),
        'refuse': [
            'Do not hand-write TLS 1.3 in Dart. That is forbidden by the '
            'ticket and by the decision document.',
            'Do not claim a gate green because a build linked. A green build '
            'proves it compiles; every 4x gate needs its own behavioural '
            'evidence, and gates that need a device or an arm64 host are '
            'closed as dated blockers with a scheduled slot, never silently.',
            'Do not vendor the library into this repository. The decision '
            'names a pinned commit and an external clone; changing that is a '
            'separate decision.',
        ],
        'author': 'fable',
    },
    {
        'id': 'comparator-order-fix',
        'title': 'The named defect in compare_first_record.py',
        'gate': 'Its closing verdict line judges extension ORDER as if order '
                'were always part of a profile shape. For a profile '
                'declaring shufflesExtensions it must compare the SET, and '
                'require two captures to differ.',
        'scope': [
            'tools/compare_first_record.py',
            'docs/TICKET4_FIRST_RECORD/RESULT.md  (drop the follow-up note)',
        ],
        'verify': (CD + 'python3 tools/compare_first_record.py '
                   'docs/TICKET4_FIRST_RECORD/FIRST_RECORD_CONFIGURED_1.hex '
                   'docs/TICKET4_FIRST_RECORD/FIRST_RECORD_CONFIGURED_2.hex '
                   '2>&1 | grep -q "reproduces the profile shape"'),
        'refuse': [
            'Do not make the verdict unconditionally favourable. The set '
            'comparison must still fail on a missing or extra extension, and '
            'the permutation evidence must fail when every capture shares one '
            'order.',
            'Read shufflesExtensions from the profile source. Hardcoding '
            '"chrome permutes" recreates the drift the tool already avoids '
            'for the two lists.',
        ],
        'author': 'fable',
    },
]

TEMPLATE = """# {title}

Slice `{id}`. Generated by `tools/make_slices.py` — edit the table there, not
this file, or the next run will overwrite you.

## GATE, quoted from the plan

{gate}

## SCOPE — these files, nothing else

```
{scope}
```

An edit outside this list is out of scope for the slice. If the work turns out
to need one, say so and stop; a slice that quietly grows is how a wave stops
being reviewable.

## VERIFY — the only thing that closes this

```
{verify}
```

No claim of done without this command's exit 0 in the same turn as the claim.
For a slice that adds a test, the test must ALSO have been driven red: disable
the subject, watch it fail, restore it, watch it pass. A test only ever seen
green does not prove it measures its gate.

## REFUSE — the shortcuts that would make this look finished

{refuse}

## AUTHOR

{author}
"""


def render(unit):
    return TEMPLATE.format(
        title=unit['title'],
        id=unit['id'],
        gate=unit['gate'],
        scope='\n'.join(unit['scope']),
        verify=unit['verify'],
        refuse='\n'.join('- %s' % r for r in unit['refuse']),
        author=('Fable 5 authors the code; the conductor writes the tests, '
                'debugs and verifies.' if unit['author'] == 'fable'
                else 'The conductor: this is a measurement, not a design.'),
    )


def main():
    dry = '--dry-run' in sys.argv
    if not dry:
        os.makedirs(SLICES, exist_ok=True)
    for unit in UNITS:
        path = os.path.join(SLICES, 'SLICE_%s.md' % unit['id'])
        if dry:
            print('would write %s' % os.path.relpath(path, ROOT))
            continue
        open(path, 'w', encoding='utf-8').write(render(unit))
        print('wrote %s' % os.path.relpath(path, ROOT))

    steps = []
    for unit in UNITS:
        steps.append({
            'id': unit['id'],
            'desc': '%s  Slice: docs/slices/SLICE_%s.md — read it before '
                    'acting; it carries the scope, the refusals and the '
                    'verifier.' % (unit['title'], unit['id']),
            'verify_cmd': unit['verify'],
            'arm_next': ARM,
            'timeout_s': 7200,
            'irreversible': False,
            'status': 'pending',
        })

    for path in RUNS:
        if dry:
            print('would patch %s with %d steps' % (path, len(steps)))
            continue
        run = json.load(open(path, encoding='utf-8'))
        shutil.copyfile(path, path + '.pre-slices.bak')
        have = {s['id'] for s in run['steps']}
        additions = [s for s in steps if s['id'] not in have]
        final = run['steps'][-1]
        run['steps'] = run['steps'][:-1] + additions + [final]
        json.dump(run, open(path, 'w', encoding='utf-8'),
                  ensure_ascii=False, indent=2)
        print('%s -> %d steps (+%d); final is %s'
              % (path, len(run['steps']), len(additions),
                 run['steps'][-1]['id']))


if __name__ == '__main__':
    main()
