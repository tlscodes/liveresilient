#!/usr/bin/env bash
# run_suites.sh — run the host suites so that the EVIDENCE survives the run.
#
# WHY THIS EXISTS
# A `signed_config` test failed once in five runs and the failure was never
# identified, because the command that found it ended in a truncating filter.
# The last line of a Dart test run is a one-line score; the name of the test
# that failed is forty lines above it, and that output no longer exists
# anywhere. The bug was real, it was caught, and the catching was thrown away.
#
# So this runner keeps three promises:
#
#   1. Every command's FULL output goes to a file under tools/suite-logs/<stamp>/
#      before anything is summarised. Summaries are derived FROM the logs, never
#      instead of them.
#   2. The logs are durable and inside the repo tree, not in a mktemp directory
#      that the next reboot removes. An intermittent failure is only useful if
#      its log is still there tomorrow when it happens again.
#   3. Failing test NAMES are lifted out of the logs and printed, so a flake
#      identifies itself on the run that reproduces it, without anyone
#      re-running anything.
#
# --check-only AUDITS THE OTHER SCRIPTS
# Fixing the one command that lost the evidence is not the same as removing the
# defect. `--check-only` scans this repo's own shell tooling for verification
# commands whose output cannot survive the run, runs no suites, takes under a
# second, and is what CI and the plan's step verifier call.
#
# SCOPE, STATED PLAINLY. Host only: pub get, analyze, unit and widget tests.
# No device, no radio, no shaped network. A green run here says the code
# compiles and its tests pass on this Mac; it says nothing about a call.
#
# USAGE
#   tools/run_suites.sh                 every package, full logs
#   tools/run_suites.sh --check-only    audit the tooling, run nothing
#   tools/run_suites.sh --only <pkg>    one package (repeatable)
#
# Exit: 0 when every step passed (or, under --check-only, when no
# evidence-destroying command remains). 1 otherwise.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 2

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGROOT="$REPO/tools/suite-logs"
RUN="$LOGROOT/$STAMP"
CHECK_ONLY=0
declare -a ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --only) ONLY+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── THE AUDIT ───────────────────────────────────────────────────────────────
# A line FAILS when it invokes a verification command whose output has no path
# to a file, and is then either truncated by a filter or swallowed by a shell
# substitution:
#
#   filtered    … | head/tail/grep          the discarded part never existed
#   captured    x="$(… 2>&1)"               whole, but only in a variable
#
# Captured counts as a failure, not a warning. Retention has to be
# unconditional at the moment of capture: a variable does not survive a crash,
# an early exit or an interrupt, and grep-level logic cannot prove that some
# later `printf "%s" "$out" > file` runs on every path. The cure is one token —
# `2>&1 | tee "$log"` — so failing costs nothing and closes the hole for good.
#
# Three exclusions keep the rule from manufacturing failures. They narrow the
# CONTEXT, never the predicate:
#   · this file, by name — its patterns contain the offending strings literally
#   · comments and echo/printf lines — talking about a command is not running one
#   · filters whose input is a FILE (`… "$log"`, `< file`, `<<<"$var"` after a
#     redirect to disk) — reading back a retained log is the cure, not the disease
#
# SCOPE IS tools/ ONLY, deliberately. A CI step that prints to the console is
# fine: GitHub keeps the run log. Auditing .github/ would report failures for
# commands whose evidence is in fact preserved. A shell run on a laptop has no
# such archive, which is exactly the gap this closes.
audit() {
  local defects=0 checked=0 f line text stripped
  local invoke='(dart|flutter|\$[A-Za-z_][A-Za-z_0-9]*)[[:space:]]+(test|analyze)([[:space:]]|$)'

  while IFS= read -r f; do
    [ "$f" = "./tools/run_suites.sh" ] && continue
    while IFS=: read -r line text; do
      stripped=$(printf '%s' "$text" | sed 's/^[[:space:]]*//')
      # Exclusion 2: prose about a command, not an invocation of one.
      case "$stripped" in
        '#'*|echo*|printf*|'"'*) continue ;;
      esac
      checked=$((checked + 1))

      local filtered=0 captured=0 to_file=0 from_file=0
      printf '%s' "$text" | grep -qE '\|[[:space:]]*(head|tail|grep)([[:space:]]|$)' && filtered=1
      printf '%s' "$text" | grep -qE '=[[:space:]]*"?\$\(' && captured=1
      printf '%s' "$text" | grep -qE 'tee|>>?[[:space:]]*"?\$?[A-Za-z_./]' && to_file=1
      # `>/dev/null` discards; it is not a file. `tee` still counts.
      if printf '%s' "$text" | grep -qE '>[[:space:]]*/dev/null' \
         && ! printf '%s' "$text" | grep -q 'tee'; then to_file=0; fi
      # Exclusion 3: the filter's input is a file already on disk.
      printf '%s' "$text" | grep -qE '(head|tail|grep)[^|]*(\$(log|LOG)|\.log|<)' && from_file=1

      if [ $to_file -eq 0 ] && [ $from_file -eq 0 ] \
         && { [ $filtered -eq 1 ] || [ $captured -eq 1 ]; }; then
        local why='captured into a variable, never written to a file'
        [ $filtered -eq 1 ] && why='filtered on a live pipe with no copy on disk'
        printf 'DEFECT  %s:%s\n        %s\n        %s\n' \
          "${f#./}" "$line" "$stripped" "$why"
        defects=$((defects + 1))
      fi
    done < <(grep -nE "$invoke" "$f" 2>/dev/null)
  done < <(find ./tools -type f -name '*.sh' | sort)

  echo
  echo "audited $checked verification invocation(s) under tools/"
  if [ $defects -gt 0 ]; then
    echo "EVIDENCE AUDIT FAILED — $defects command(s) cannot survive their own run"
    return 1
  fi
  echo 'EVIDENCE AUDIT PASSED — every verification command writes its full output to a file'
  return 0
}

if [ $CHECK_ONLY -eq 1 ]; then
  audit
  exit $?
fi

# ── THE RUN ─────────────────────────────────────────────────────────────────
FLUTTER_BIN=$(command -v flutter || true)
DART_BIN=$(command -v dart || true)
[ -n "$DART_BIN" ] || { echo 'dart not on PATH' >&2; exit 2; }

mkdir -p "$RUN" || exit 2
PASS=0; FAIL=0
declare -a ROWS=()

# One step, one log, no exceptions. The log is written BEFORE the summary is
# read, and the summary is read out of the log — so the printed line and the
# retained evidence can never disagree.
step() {
  local dir="$1" name="$2" log="$RUN/$3.log"; shift 3
  printf '%-52s ' "$name"
  local started ended rc secs summary res
  started=$(date +%s)
  ( cd "$dir" && "$@" ) >"$log" 2>&1
  rc=$?
  ended=$(date +%s); secs=$((ended - started))
  summary=$(grep -oE 'No issues found!|[0-9]+ issues? found|All tests passed!|Some tests failed|No tests ran' "$log" 2>/dev/null | awk 'END{print}')
  summary=${summary:-see log}
  res=PASS; [ $rc -eq 0 ] || res=FAIL
  printf '%s  (%ss)  %s\n' "$res" "$secs" "$summary"
  if [ "$res" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  ROWS+=("$res	$name	${secs}s	$summary	${log#"$REPO"/}")
}

# The line a flake hunt needs: the runner's own `[E]` marker carries the test
# name. Read out of the retained log, so it is available for every past run
# under tools/suite-logs/, not only this one.
failing_names() {
  local log="$1"
  grep -hoE '^[0-9:]+ \+[0-9]+ -[0-9]+: [^[]*\[E\]' "$log" 2>/dev/null \
    | sed -E 's/^[0-9:]+ \+[0-9]+ -[0-9]+: //; s/ \[E\]$//' | sort -u
}

wanted() {
  local p="$1" o
  [ ${#ONLY[@]} -eq 0 ] && return 0
  for o in "${ONLY[@]}"; do [ "$o" = "$p" ] && return 0; done
  return 1
}

for d in packages/*/; do
  p=$(basename "$d")
  wanted "$p" || continue
  [ -f "$d/pubspec.yaml" ] || continue
  # A package depending on the Flutter SDK cannot resolve under plain `dart`.
  runner="$DART_BIN"
  if grep -qE '^[[:space:]]+flutter:[[:space:]]*$' "$d/pubspec.yaml" 2>/dev/null; then
    [ -n "$FLUTTER_BIN" ] || { echo "SKIP $p (needs flutter, not on PATH)"; continue; }
    runner="$FLUTTER_BIN"
  fi
  step "$d" "$p  pub get" "$p.pubget" "$runner" pub get
  step "$d" "$p  analyze" "$p.analyze" "$runner" analyze
  if [ -d "$d/test" ]; then
    step "$d" "$p  test" "$p.test" "$runner" test
  fi
done

{
  printf 'result\tstep\ttime\tsummary\tlog\n'
  for r in "${ROWS[@]}"; do printf '%s\n' "$r"; done
} > "$RUN/SUMMARY.tsv"

echo
if [ $FAIL -gt 0 ]; then
  echo '── failing tests, by name ──'
  found=0
  for l in "$RUN"/*.test.log; do
    [ -f "$l" ] || continue
    names=$(failing_names "$l")
    [ -n "$names" ] || continue
    found=1
    printf '%s\n' "${l#"$RUN"/}"
    printf '%s\n' "$names" | sed 's/^/    /'
  done
  [ $found -eq 1 ] || echo '(no [E] markers — the failure is outside the test runner; read the logs)'
  echo
fi
echo "logs (kept): ${RUN#"$REPO"/}"
echo "summary:     ${RUN#"$REPO"/}/SUMMARY.tsv"
if [ $FAIL -eq 0 ] && [ $PASS -gt 0 ]; then
  echo "SUITES GREEN — $PASS steps passed"
  exit 0
fi
echo "SUITES RED — $FAIL failed, $PASS passed"
exit 1
