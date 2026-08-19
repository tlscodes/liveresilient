#!/bin/bash
# Run-level goal verifier for FULL_TEST_PLAN: green ONLY when all seven
# track gates re-verify in check-only mode AND the phase-5 goal_verify is
# still green. Pure reader — it never measures, builds, or writes evidence.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
fails=0

run() {
  local label="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  $label: GREEN"
  else
    echo "  $label: RED"
    fails=$((fails + 1))
  fi
}

echo "goal_verify_full $(date -u +%Y-%m-%dT%H:%M:%SZ)"
run gate_t0_device bash "$HERE/gate_t0_device.sh"
for g in t1_tree t1b_probe t2_ios t3_e2e t4_uplift t5_docs; do
  run "gate_$g" env GATE_CHECK_ONLY=1 bash "$HERE/gate_$g.sh"
done
run phase5_goal_verify bash "$REPO/tools/phase5/goal_verify.sh"

if [ "$fails" -eq 0 ]; then
  echo "FULL GOAL VERIFY GREEN: 7/7 track gates + phase-5 goal_verify"
  exit 0
fi
echo "FULL GOAL VERIFY RED: $fails gate(s) red"
exit 1
