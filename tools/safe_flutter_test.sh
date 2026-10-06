#!/bin/bash
# Runs `flutter test` for one package in a way that cannot take this machine
# down.
#
# Twice a full suite was left running on an 8 GB machine beside another
# flutter process; both times the machine hung and had to be restarted, and
# what the run had written under a temp directory went with it. So:
#
#   * one at a time. A lock is held for the whole run, and the run is refused
#     while another flutter test, a flutter or Xcode build, or a `dart
#     analyze` / `dart format` is alive;
#   * it does not start on a machine that is already loaded;
#   * it has a wall-clock limit — by default 630 s, one and a half times the
#     seven minutes the reference app's suite takes. At the limit the whole
#     process group is stopped and the run is a TIMEOUT. A suite at twice its
#     usual time is a reason to stop, not to wait;
#   * nothing is started after a stop until no test process is left;
#   * the log goes where it is told (inside the repository, not a temp
#     directory), and one verdict line with the measured seconds is APPENDED
#     to the summary file, so three runs leave three lines.
#
# Usage:  tools/safe_flutter_test.sh <package dir> <log file> <summary file> [flutter test arguments...]
# Limits: SAFE_TEST_LIMIT_S (630)   SAFE_TEST_MAX_LOAD (6.0, the 1-minute load)
# Line:   SAFE_TEST verdict=PASS|FAIL|TIMEOUT|REFUSED seconds=N passed=N failed=N limit=N at=<utc> pkg=<dir>
# Exit:   0 PASS · 1 FAIL · 3 REFUSED · 4 TIMEOUT
set -uo pipefail
PKG=${1:?package directory}
LOGFILE=${2:?log file}
SUMMARY=${3:?summary file}
shift 3
LIMIT=${SAFE_TEST_LIMIT_S:-630}
MAX_LOAD=${SAFE_TEST_MAX_LOAD:-6.0}
LOCK="${TMPDIR:-/tmp}/vck_safe_flutter_test.lock"
PKG_ABS=$(cd "$PKG" && pwd) || { echo "no package at $PKG" >&2; exit 2; }
mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$SUMMARY")"

verdict() { # verdict seconds passed failed
  local line="SAFE_TEST verdict=$1 seconds=$2 passed=$3 failed=$4 limit=$LIMIT at=$(date -u +%Y-%m-%dT%H:%M:%SZ) pkg=$PKG"
  echo "$line" | tee -a "$SUMMARY"
}

others() {
  pgrep -fl 'flutter_tester|flutter_tools\.snapshot.* (test|build|run|drive)|xcodebuild|dart (analyze|format)|dart-sdk/bin/dart (analyze|format)' \
    | grep -v "$$" || true
}

# --- one at a time ----------------------------------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
  HOLDER=$(cat "$LOCK/pid" 2>/dev/null || echo "")
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    echo "refused: another safe test run (pid $HOLDER) holds the lock" >&2
    verdict REFUSED 0 0 0
    exit 3
  fi
  rm -rf "$LOCK" && mkdir "$LOCK" || { verdict REFUSED 0 0 0; exit 3; }
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

BUSY=$(others)
if [ -n "$BUSY" ]; then
  echo "refused: something that must not run beside a test suite is alive:" >&2
  echo "$BUSY" | cut -c1-160 >&2
  verdict REFUSED 0 0 0
  exit 3
fi
LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
if awk -v l="${LOAD:-0}" -v m="$MAX_LOAD" 'BEGIN{exit !(l>m)}'; then
  echo "refused: the 1-minute load is $LOAD, over $MAX_LOAD" >&2
  verdict REFUSED 0 0 0
  exit 3
fi

# --- the run, in a process group of its own ---------------------------------
START=$(date +%s)
( cd "$PKG_ABS" && exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    flutter test "$@" ) >"$LOGFILE" 2>&1 &
RUN=$!
TIMED_OUT=0
while kill -0 "$RUN" 2>/dev/null; do
  if [ $(( $(date +%s) - START )) -ge "$LIMIT" ]; then
    TIMED_OUT=1
    kill -TERM -- "-$RUN" 2>/dev/null
    sleep 5
    kill -KILL -- "-$RUN" 2>/dev/null
    break
  fi
  sleep 2
done
wait "$RUN" 2>/dev/null
RC=$?
SECONDS_TAKEN=$(( $(date +%s) - START ))

# Nothing may follow this run until no test process is left.
for _ in $(seq 1 30); do
  pgrep -f flutter_tester >/dev/null || break
  pkill -KILL -f flutter_tester 2>/dev/null
  sleep 1
done

# flutter's own last count line: "07:02 +812: All tests passed!" or
# "07:02 +809 ~1 -2: Some tests failed."
LAST=$(grep -aE '\+[0-9]+( ~[0-9]+)?( -[0-9]+)?: ' "$LOGFILE" | tail -n 1)
PASSED=$(echo "$LAST" | sed -nE 's/.*\+([0-9]+).*/\1/p')
FAILED=$(echo "$LAST" | sed -nE 's/.* -([0-9]+): .*/\1/p')
PASSED=${PASSED:-0}
FAILED=${FAILED:-0}

if [ "$TIMED_OUT" = 1 ]; then
  verdict TIMEOUT "$SECONDS_TAKEN" "$PASSED" "$FAILED"
  exit 4
fi
if [ "$RC" = 0 ] && grep -aq 'All tests passed!' "$LOGFILE"; then
  verdict PASS "$SECONDS_TAKEN" "$PASSED" "$FAILED"
  exit 0
fi
verdict FAIL "$SECONDS_TAKEN" "$PASSED" "$FAILED"
exit 1
