#!/usr/bin/env bash
# Hunt the recorded signed_config flake: 1 failure in 5 runs, test name unknown.
#
# WHY THE NAME WAS UNKNOWN, AND WHY IT WILL NOT BE AGAIN
# The original sighting ran through `tail -1`, so the score survived and the name
# did not. Run step 0 removed that shape from this repository's tooling, which is
# what makes this hunt worth running at all: every failure below keeps its whole
# log, and the failing test names itself.
#
# TIME-BOXED ON PURPOSE. An intermittent failure can absorb a whole session, so
# this stops at whichever comes first: the configured number of runs, the
# deadline, or the first reproduction — because one reproduction with a full log
# is the entire objective, and further runs after it buy nothing.
#
#   tools/hunt_flake.sh [runs] [minutes]      defaults: 10 runs, 45 minutes
#
# Exit 0 whether or not it reproduces. A hunt that finds nothing is a result
# ("not seen in N runs"), not a failure — and reporting it as a failure would
# push the next reader toward retrying until the answer changes.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PKG=$REPO/packages/signed_config
RUNS=${1:-10}
MINUTES=${2:-45}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGS=$REPO/tools/suite-logs/flake-$STAMP
mkdir -p "$LOGS"
DEADLINE=$(( $(date +%s) + MINUTES * 60 ))
SUMMARY=$LOGS/SUMMARY.txt

printf 'flake hunt %s · up to %d runs · deadline %d minutes\n' \
  "$STAMP" "$RUNS" "$MINUTES" | tee "$SUMMARY"

reproduced=0
completed=0
for i in $(seq 1 "$RUNS"); do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    printf 'stopped at the %d-minute deadline after %d runs\n' \
      "$MINUTES" "$completed" | tee -a "$SUMMARY"
    break
  fi
  log=$LOGS/run-$(printf '%02d' "$i").log
  ( cd "$PKG" && dart test ) > "$log" 2>&1
  rc=$?
  completed=$(( completed + 1 ))
  score=$(grep -oE '\+[0-9]+( -[0-9]+)?: (All tests passed!|Some tests failed)' \
    "$log" | awk 'END{print}')
  printf 'run %02d  rc=%d  %s\n' "$i" "$rc" "${score:-no score line}" \
    | tee -a "$SUMMARY"
  if [ "$rc" -ne 0 ]; then
    reproduced=1
    printf '\nREPRODUCED on run %d. Failing tests, by name:\n' "$i" \
      | tee -a "$SUMMARY"
    grep -hoE '^[0-9:]+ \+[0-9]+ -[0-9]+: [^[]*\[E\]' "$log" \
      | sed -E 's/^[0-9:]+ \+[0-9]+ -[0-9]+: //; s/ \[E\]$//' | sort -u \
      | sed 's/^/    /' | tee -a "$SUMMARY"
    printf '\nfull log: %s\n' "${log#"$REPO"/}" | tee -a "$SUMMARY"
    break
  fi
done

printf '\n' | tee -a "$SUMMARY"
if [ "$reproduced" -eq 1 ]; then
  printf 'RESULT: reproduced, with a named test and an intact log.\n' \
    | tee -a "$SUMMARY"
else
  printf 'RESULT: not reproduced in %d run(s). This is a measurement, not a\n' \
    "$completed" | tee -a "$SUMMARY"
  printf 'clean bill of health: the flake stays a dated open item, and the\n' \
    | tee -a "$SUMMARY"
  printf 'suite is "green with a recorded flake", never "green".\n' \
    | tee -a "$SUMMARY"
fi
printf 'logs: %s\n' "${LOGS#"$REPO"/}" | tee -a "$SUMMARY"
exit 0
