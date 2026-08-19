#!/bin/bash
# Gate T4 — uplift pass verification (FULL_TEST_PLAN track 4).
# The pass itself edits one file per step with numbered backups and a
# one-line "what rises" entry in tools/dossier/logs/uplift_ledger.tsv.
# exit 0 ONLY when, AFTER the pass:
#   - the newest run_suites.sh pass is complete and has zero FAIL rows
#     (analyze zero defects + all suites green)
#   - phase-5 goal_verify re-runs green (no uplift may turn a green row red)
#   - the uplift ledger exists (each applied step, or an explicit
#     none-applied line with its reason)
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t4_uplift

LEDGER="$DLOGS/uplift_ledger.tsv"

check_suites() {
  local run exp got fails
  run=$(newest_suite_run)
  exp=$(expected_suite_rows)
  got=$(summary_rows "$run")
  fails=$(summary_fails "$run")
  echo "post-uplift suite run: ${run#"$TREPO"/}  rows=$got expected=$exp fails=$fails"
  [ "$got" = "$exp" ] || die "post-uplift pass incomplete ($got of $exp rows)"
  [ "$fails" = 0 ] || die "post-uplift: $fails failing rows"
  [ -s "$LEDGER" ] || die "uplift ledger missing"
  echo "ledger rows: $(grep -c . "$LEDGER")"
}

check_phase5() {
  # goal_verify is check-shaped by design (GATE_CHECK_ONLY re-verification)
  ( cd "$TREPO" && bash tools/phase5/goal_verify.sh ) \
    || die "phase-5 goal_verify no longer green after uplift"
}

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  check_suites
  check_phase5
  echo "gate_t4_uplift check-only OK"
  exit 0
fi

# ---- normal (long) mode: re-run the whole tree, then both checks ----
cd "$TREPO"
bash tools/run_suites.sh
check_suites
check_phase5
echo "gate_t4_uplift -> PASS"
