"""Link each gate to the tests that prove it, and keep the link honest.

WHY
---
The plan declares numbered acceptance gates and the ledger claims they are
green. Neither claim can be RECOMPUTED from the repository unless a test's
own name carries the gate id, because that is the only thing a grep can
match. Measured before this ran: 5 gate ids were greppable out of ~41. The
work existed; the link did not, and a ledger that cannot be recomputed is a
memory rather than a record.

TWO MODES, AND THE SECOND IS THE IMPORTANT ONE
----------------------------------------------
    --label   one-time migration: prefix test names with their gate id
    --check   the permanent guard: rebuild the table from names and
              reconcile it against every declared gate

Renaming is done once. Without --check running in CI, the table rots again
in six months as new tests and new gates arrive.

WHAT IT REFUSES TO DO
---------------------
It will not guess. The file-to-gate map below was written by reading the
files. A file proving several gates is listed as MIXED with the reason, and
is left untouched — a greppable WRONG link is worse than a greppable gap,
because nothing downstream can detect it.

THE LIE THIS DESIGN CANNOT CATCH — stated because it is real
------------------------------------------------------------
A file-level prefix stamps a coarse claim onto every test name in the file,
including setup, regression and helper-coverage tests. A reader six months
from now may count fourteen names under one gate and conclude it has
fourteen proofs, when three prove it and the rest merely share a file. No
mechanical check catches this, because after the rename the names themselves
make the claim.

So the prefix means "this file is the evidence for this gate", NOT "each of
these tests is an independent proof". Run --label --dry-run first and read
the old -> new pairs; that human pass is the only guard against granularity
drift, and it is required, not optional.

USAGE
    python3 tools/label_gates.py --label --dry-run
    python3 tools/label_gates.py --label
    python3 tools/label_gates.py --check
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every gate the plan declares. The reconciliation runs over ALL of these,
# not only the ones that happen to be found.
DECLARED = [
    '1a', '1b', '1c', '1d', '1e', '1f', '1g', '1h',
    '2a', '2b', '2c', '2d', '2e', '2f',
    '3a', '3b', '3c', '3d', '3e', '3f',
    '4a', '4b', '4c', '4d', '4e', '4f', '4g',
    '5a', '5b', '5c', '5d', '5e', '5f',
    '6a', '6b', '6c', '6d', '6e', '6f', '6g',
]

# file -> the gate it is the evidence for. Written by reading each file.
MAPPED = {
    'packages/signed_config/test/strict_relay_unsatisfiable_test.dart': '3b',
    'packages/signed_config/test/host_candidate_exposure_test.dart': '3f',
    'packages/signed_config/test/https_name_lookup_test.dart': '6c',
    'packages/signed_config/test/lookup_cache_test.dart': '6e',
    'packages/adaptive_transport/test/fixed_tick_emitter_test.dart': '1d',
    'packages/adaptive_transport/test/length_histogram_buckets_test.dart': '1c',
    'packages/adaptive_transport/test/key_epoch_overlap_test.dart': '3e',
    'apps/reference_app/test/ice_failure_ledger_test.dart': '3a',
    'apps/reference_app/test/resolver_wiring_architecture_test.dart': '6b',
    'apps/reference_app/integration_test/host_candidate_device_test.dart': '3f',
}

# Left untouched on purpose. Each entry names the gates the file proves, so
# the reconciliation can record them as "proven, unlabelled" rather than as
# "unproven" — the difference between a gap and a naming choice.
MIXED = {
    'packages/media_webrtc/test/opus_cbr_dtx_test.dart':
        (['1a', '1e', '1g'], 'proves three gates, already grouped by gate'),
    'packages/media_webrtc/test/opus_wire_budget_test.dart':
        (['1b', '1g', '1h'], 'carrier default and both refusal causes'),
    'packages/call_core/test/scheduler_step_bound_test.dart':
        (['2a', '2d', '2e', '2f'], 'test names already begin with their id'),
    'packages/signed_config/test/manifest_time_floor_test.dart':
        (['5a', '5b', '5c', '5d'], 'test names already begin with their id'),
    'packages/signed_config/test/manifest_byte_cap_test.dart':
        (['3d'], 'test names already begin with 3d / 3d-bis'),
    'apps/reference_app/test/startup_gate_test.dart':
        ([], 'proves the bootstrap rule, which has no numbered gate'),
}

# ── THE RATCHET ─────────────────────────────────────────────────────────────
#
# --check found 15 gates with no proof. Failing on all 15 makes the CI step red
# on every commit, and a step that is always red teaches everyone to ignore it —
# which is worse than not having it, because it also hides the day a NEW gap
# appears. So the check fails on CHANGE, not on the standing backlog: every
# unproven gate must be listed below with a reason and a way out, and anything
# unproven that is NOT listed is a hard failure.
#
# The list is also not allowed to rot. A gate here that has since acquired a
# proof fails the check too, with an instruction to delete its line. That is one
# line of bookkeeping per closed gate, enforced on the day it closes rather than
# remembered at the end — the same reason the ledger quotes its verifier.
#
# Recorded 2026-08-17.
#
# THE LIST ITSELF IS NOT HERE, and that is the point. It used to be two dicts on
# these lines, which made closing a gate an edit to the checker; after four such
# edits the repository's churn guard blocked further ones, correctly — the logic
# and the backlog change on different schedules. The backlog now lives in
# docs/gate_backlog.json with ONE authority, and this module reads it at import
# so both entry points see identical data:
#
#     python3 tools/gate_ratchet.py       # the same answer, plus the category
#     python3 tools/label_gates.py --check  # printout for measured-below gates
#
# The loader is gate_ratchet.load_backlog(), which is also where the third
# category (measured_below: attempted, and the number came up short) is folded
# into the accounting. Deliberately no fallback to an empty dict: a missing or
# malformed backlog must fail loudly rather than turn every unproven gate into a
# false "unlisted" failure.
def _load_backlog_dicts():
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        'gate_ratchet', os.path.join(here, 'gate_ratchet.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    blocked, accounted, _measured_below = module.load_backlog()
    return blocked, accounted


BLOCKED, IN_FLIGHT = _load_backlog_dicts()

TESTCALL = re.compile(r"\btest(?:Widgets)?\(\s*\n?\s*(['\"])")
PREFIXED = re.compile(r"\btest(?:Widgets)?\(\s*\n?\s*(['\"])[0-9][a-z]\b")


def scan(path):
    full = os.path.join(ROOT, path)
    if not os.path.isfile(full):
        return None, None, None
    src = open(full, encoding='utf-8').read()
    found = len(TESTCALL.findall(src))
    already = len(PREFIXED.findall(src))
    return src, found, already


def do_label(dry):
    print('LABEL%s — prefixing test names with the gate they evidence\n'
          % (' (dry run)' if dry else ''))
    failed = False
    for path, gate in MAPPED.items():
        src, found, already = scan(path)
        name = path.split('/')[-1]
        if src is None:
            print('  %-52s MISSING FILE' % name)
            failed = True
            continue
        if found == 0:
            # Fable's correction 1: zero matches is a broken regex, not a
            # finished job. Reporting success here is the exact trap of a
            # tool that matched nothing and said it was done.
            print('  %-52s FOUND 0 — regex did not match this file' % name)
            failed = True
            continue

        renamed = 0
        out = src
        for m in reversed(list(TESTCALL.finditer(src))):
            q = m.group(1)
            head = src[m.end():m.end() + 4]
            if re.match(r'[0-9][a-z]\b', head):
                continue
            if dry:
                tail = src[m.end():m.end() + 46].split('\n')[0]
                print('      %-6s %s' % (gate, tail))
            out = out[:m.end()] + gate + '  ' + out[m.end():]
            renamed += 1
        if not dry and renamed:
            open(os.path.join(ROOT, path), 'w', encoding='utf-8').write(out)

        # Fable's conservation condition: found == renamed + already.
        ok = 'ok' if found == renamed + already else 'MISMATCH'
        print('  %-52s %-3s found=%-3d renamed=%-3d already=%-3d %s'
              % (name, gate, found, renamed, already, ok))
        if ok != 'ok':
            failed = True

    print('\n  left untouched, and why — these are choices, not oversights:')
    for path, (gates, why) in MIXED.items():
        print('    %-46s %-18s %s'
              % (path.split('/')[-1], ','.join(gates) or '(no gate)', why))
    return 1 if failed else 0


def do_check():
    print('CHECK — rebuilding the gate table from test names\n')
    labelled = set()
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', 'build', '.dart_tool', '.backups')]
        for fn in filenames:
            if not fn.endswith('_test.dart'):
                continue
            try:
                src = open(os.path.join(dirpath, fn),
                           encoding='utf-8').read()
            except OSError:
                continue
            for m in re.finditer(
                    r"\btest(?:Widgets)?\(\s*\n?\s*['\"]([0-9][a-z])\b", src):
                labelled.add(m.group(1))

    from_mixed = set()
    for gates, _ in MIXED.values():
        from_mixed.update(gates)
    from_mixed -= labelled

    missing = [g for g in DECLARED
               if g not in labelled and g not in from_mixed]

    print('  gates declared in the plan          %d' % len(DECLARED))
    print('  proven by a test named after them   %d  %s'
          % (len(labelled), ' '.join(sorted(labelled))))
    print('  proven only inside a mixed file     %d  %s'
          % (len(from_mixed), ' '.join(sorted(from_mixed)) or '-'))
    # Printed even when empty: the absence of a section is indistinguishable
    # from a broken tool.
    print('  no proof found at all               %d  %s'
          % (len(missing), ' '.join(missing) or '-'))

    if missing:
        print('\n  These are real gaps, not naming gaps. Do not close one by')
        print('  renaming an unrelated test — that manufactures the false')
        print('  link this tool exists to prevent.')

    # ── the ratchet ────────────────────────────────────────────────────────
    proven = labelled | from_mixed
    accounted = dict(BLOCKED)
    accounted.update(IN_FLIGHT)

    unlisted = [g for g in missing if g not in accounted]
    stale = [g for g in sorted(accounted) if g in proven]

    print()
    print('  ratchet — unproven gates must be listed with a reason')
    print('    blocked (external / deferred)      %d  %s'
          % (len(BLOCKED), ' '.join(sorted(BLOCKED))))
    print('    in flight (this run closes them)   %d  %s'
          % (len(IN_FLIGHT), ' '.join(sorted(IN_FLIGHT))))
    print('    unproven and UNLISTED              %d  %s'
          % (len(unlisted), ' '.join(unlisted) or '-'))
    print('    listed but now PROVEN (stale)      %d  %s'
          % (len(stale), ' '.join(stale) or '-'))

    if unlisted:
        print()
        print('  RATCHET FAILED — a gate lost its proof, or a new gate arrived')
        print('  without one. Either write the test, or add the id to BLOCKED /')
        print('  IN_FLIGHT in this file with a reason and the slot that closes it.')
        for g in unlisted:
            print('    %s  unaccounted for' % g)
        return 1

    if stale:
        print()
        print('  RATCHET FAILED — the record is behind the repository. These')
        print('  gates now have proofs, so delete their lines here; the list is')
        print('  what makes the backlog honest, and a stale entry hides progress')
        print('  exactly as a missing entry hides a regression.')
        for g in stale:
            print('    %s  proven now: %s' % (g, accounted[g]))
        return 1

    if missing:
        print()
        print('  RATCHET PASSED — %d gate(s) unproven, every one listed with a'
              % len(missing))
        print('  reason and a slot. No new gap, no stale entry.')
        return 0

    print('\n  no gaps: every declared gate traces to a test.')
    return 0


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(do_check())
    if '--label' in sys.argv:
        sys.exit(do_label('--dry-run' in sys.argv))
    print(__doc__)
    sys.exit(2)
