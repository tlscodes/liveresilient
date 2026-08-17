#!/bin/bash
# Cold-check gate: fresh pub get + strict analyze + full tests, every package.
#
# EVIDENCE RULE. Every command's whole output is written to a log first, and the
# one-line summary is read back OUT of that log. The previous version did
# `dart test 2>&1 | tail -1`, which keeps the score and destroys the name of
# whatever failed — the exact command shape that lost a 1-in-5 intermittent
# failure in `signed_config`. Enforced by `tools/run_suites.sh --check-only`.
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGS="$REPO/tools/suite-logs/cold-$STAMP"
mkdir -p "$LOGS" || exit 1
out="$LOGS/RESULTS.txt"
: > "$out"

# The last line of a retained log, which is a different act from discarding
# every other line on the way past.
last_line() { awk 'NF{keep=$0} END{print keep}' "$1"; }

for d in packages/*/; do
  p=$(basename "$d")
  cd "$d" || continue
  dart pub get > "$LOGS/$p.pubget.log" 2>&1 && pg=OK || pg=FAIL
  dart analyze > "$LOGS/$p.analyze.log" 2>&1
  an=$(last_line "$LOGS/$p.analyze.log")
  if [ -d test ]; then
    dart test > "$LOGS/$p.test.log" 2>&1
    tl=$(last_line "$LOGS/$p.test.log")
  else
    tl="(no tests)"
  fi
  echo "$p | pubget=$pg | analyze=$an | test=$tl" >> "$out"
  cd "$REPO" || exit 1
done

cat "$out"
echo
echo "full logs: ${LOGS#"$REPO"/}"
