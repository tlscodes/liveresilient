#!/bin/bash
# Shared helpers for the FULL_TEST_PLAN track gates (gate_t*.sh).
# Contract (FULL_TEST_PLAN.md, section «قواعد ران»):
#   - verify_cmd is check-only: GATE_CHECK_ONLY=1 must never re-measure,
#     never rebuild, never write evidence — it only reads what a prior
#     normal run left behind.
#   - full logs, never tails: every normal run tees its complete output
#     into tools/dossier/logs/.
#   - no hardcoded device id: the UDID is read from
#     tools/dossier/logs/device_udid.txt every time it is needed.

TREPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PHASE5="$TREPO/tools/phase5"
DOSSIER="$TREPO/tools/dossier"
DLOGS="$DOSSIER/logs"
UDID_FILE="$DLOGS/device_udid.txt"

die() { echo "GATE FAIL: $*" >&2; exit 1; }

# tgate_log <slug> — tee complete output to the dossier log dir.
# CHECK-ONLY MUST NOT TOUCH EVIDENCE: a verification pass that rewrites the
# retained log changes the manifest hashes it is being verified against
# (measured: goal_verify_full turned gate_t5 red by re-teeing gate logs).
# So check-only runs log to a .check file that the manifest never lists.
tgate_log() {
  mkdir -p "$DLOGS"
  if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
    exec > >(tee "$DLOGS/gate_$1.check.log") 2>&1
  else
    exec > >(tee "$DLOGS/gate_$1.log") 2>&1
  fi
  echo "== gate_$1 $(date -u +%Y-%m-%dT%H:%M:%SZ) check_only=${GATE_CHECK_ONLY:-0} =="
}

device_udid() {
  [ -s "$UDID_FILE" ] || die "device UDID file missing: $UDID_FILE (run gate_t0 first)"
  tr -d '[:space:]' < "$UDID_FILE"
}

# newest_suite_run — prints the newest tools/suite-logs/<stamp> dir, or fails
newest_suite_run() {
  local d
  d=$(ls -1dt "$TREPO"/tools/suite-logs/*/ 2>/dev/null | head -1)
  [ -n "$d" ] || die "no suite run found under tools/suite-logs/"
  printf '%s\n' "${d%/}"
}

# expected_suite_rows — how many rows a COMPLETE run_suites.sh pass produces:
# for every packages/*/ and apps/*/ dir with a pubspec: pub get + analyze
# (+ test when a test/ dir exists). Computed, never hardcoded, so the count
# tracks the tree.
expected_suite_rows() {
  local n=0 d
  for d in "$TREPO"/packages/*/ "$TREPO"/apps/*/; do
    [ -f "$d/pubspec.yaml" ] || continue
    n=$((n + 2))
    [ -d "$d/test" ] && n=$((n + 1))
  done
  echo "$n"
}

# summary_rows <run-dir>    — data-row count of SUMMARY.tsv
# summary_fails <run-dir>   — FAIL-row count of SUMMARY.tsv
summary_rows()  { awk 'NR>1' "$1/SUMMARY.tsv" 2>/dev/null | grep -c . || true; }
summary_fails() { awk -F'\t' 'NR>1 && $1=="FAIL"' "$1/SUMMARY.tsv" 2>/dev/null | grep -c . || true; }
