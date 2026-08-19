#!/bin/bash
# Gate T1b — probe_defense subsystem, judged ONLY through its own gates
# (FULL_TEST_PLAN track 1b). This gate CALLS tools/run_suites.sh,
# tools/gate_ratchet.py and tools/plan_check.py; it never restates any
# subsystem content here (see the plan's DO/DO NOT block — payload rule).
# exit 0 ONLY when:
#   - the newest run_suites.sh pass executed EVERY row (0 unrun; the count
#     is computed from the tree, not hardcoded)
#   - gate_ratchet reports zero blocked AND zero unproven-unlisted gates
#   - the complete outputs sit in tools/dossier/logs/probe_defense_gate.log
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t1b_probe

PDLOG="$DLOGS/probe_defense_gate.log"

ratchet_check() {
  # parse the two ledger lines out of the retained ratchet output
  local blocked unlisted
  blocked=$(grep -E 'blocked \(external / deferred\)' "$PDLOG" | grep -oE '[0-9]+' | head -1)
  unlisted=$(grep -E 'unproven and UNLISTED' "$PDLOG" | grep -oE '[0-9]+' | head -1)
  echo "ratchet: blocked=${blocked:-?} unproven_unlisted=${unlisted:-?}"
  [ "${blocked:-x}" = 0 ] || die "ratchet blocked count not zero"
  [ "${unlisted:-x}" = 0 ] || die "ratchet unproven-unlisted count not zero"
}

check() {
  local run exp got fails
  run=$(newest_suite_run)
  exp=$(expected_suite_rows)
  got=$(summary_rows "$run")
  fails=$(summary_fails "$run")
  echo "suite run: ${run#"$TREPO"/}  rows=$got expected=$exp fails=$fails"
  [ "$got" = "$exp" ] || die "rows unrun: $got of $exp (the plan's open item is exactly this)"
  [ "$fails" = 0 ] || die "$fails failing rows"
  [ -s "$PDLOG" ] || die "probe_defense_gate.log missing"
  ratchet_check
}

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  check
  echo "gate_t1b_probe check-only OK"
  exit 0
fi

# ---- normal mode: call the subsystem's own gates, retain full output ----
cd "$TREPO"
{
  echo "== probe_defense gates $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  echo "-- gate_ratchet.py --"
  python3 tools/gate_ratchet.py
  echo "-- plan_check.py (evidence only; its verdict is logged, the plan's"
  echo "   verify clause gates on rows+ratchet+log) --"
  python3 tools/plan_check.py || true
} > "$PDLOG" 2>&1
cat "$PDLOG"

check
echo "gate_t1b_probe -> PASS"
