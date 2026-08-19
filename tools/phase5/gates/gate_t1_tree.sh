#!/bin/bash
# Gate T1 — full-tree audit and zero-defect check (FULL_TEST_PLAN track 1).
#   T1.1 analyze on every package/app/server — complete output (no tail)
#        kept at tools/dossier/logs/full_tree_audit.log
#   T1.2 every unit-test suite — complete output at
#        tools/dossier/logs/full_tree_tests.log
#   T1.3 the pending datagram_lane_probe failure must be root-fixed, which
#        this gate sees as: its suite row is PASS like every other row.
# exit 0 ONLY when: the newest run_suites.sh pass is complete (row count ==
# computed expectation), has zero FAIL rows, and both dossier logs exist.
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t1_tree

check() {
  local run
  run=$(newest_suite_run)
  local exp got fails
  exp=$(expected_suite_rows)
  got=$(summary_rows "$run")
  fails=$(summary_fails "$run")
  echo "suite run: ${run#"$TREPO"/}  rows=$got expected=$exp fails=$fails"
  [ "$got" = "$exp" ] || die "incomplete pass: $got rows, expected $exp (a SKIP or early stop ate rows)"
  [ "$fails" = 0 ] || die "$fails failing rows in $run/SUMMARY.tsv"
  [ -s "$DLOGS/full_tree_audit.log" ] || die "full_tree_audit.log missing"
  [ -s "$DLOGS/full_tree_tests.log" ] || die "full_tree_tests.log missing"
  # the audit log must carry every analyze row's full output marker
  local n_analyze
  n_analyze=$(grep -c '^==== ' "$DLOGS/full_tree_audit.log" || true)
  echo "analyze sections in audit log: $n_analyze"
  [ "$n_analyze" -gt 0 ] || die "audit log has no analyze sections"
}

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  check
  echo "gate_t1_tree check-only OK"
  exit 0
fi

# ---- normal (long) mode: run the whole tree, then assemble dossier logs ----
cd "$TREPO"
bash tools/run_suites.sh
RUN=$(newest_suite_run)

# complete analyze outputs, concatenated with per-package section markers
: > "$DLOGS/full_tree_audit.log"
for f in "$RUN"/*.analyze.log; do
  [ -f "$f" ] || continue
  { echo "==== ${f##*/} ===="; cat "$f"; echo; } >> "$DLOGS/full_tree_audit.log"
done
# complete test outputs
: > "$DLOGS/full_tree_tests.log"
for f in "$RUN"/*.test.log; do
  [ -f "$f" ] || continue
  { echo "==== ${f##*/} ===="; cat "$f"; echo; } >> "$DLOGS/full_tree_tests.log"
done
cp "$RUN/SUMMARY.tsv" "$DLOGS/full_tree_summary.tsv"

check
echo "gate_t1_tree -> PASS"
