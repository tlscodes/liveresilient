#!/usr/bin/env bash
# verify_all.sh — analyze and test everything, never stop at the first failure,
# and write a report you can read after the fact.
#
# WHY IT DOES NOT USE `&&`. A chain of `cmd && cmd && cmd` stops at the first
# non-zero exit, so one broken package hides the state of every package after
# it. That turns "what is the health of this repo" into "what is the first
# thing that broke", and the two questions have very different answers when
# five packages changed. Every step here runs regardless; the exit code is the
# summary, not the first casualty.
#
# SCOPE, STATED UP FRONT. This runs on the HOST only: analysis, unit tests,
# widget tests, and the offline simulations. It does not build for a device,
# does not place a call, and does not shape the network — which is why it takes
# minutes rather than an hour. The device and shaped-path evidence comes from
# `tools/t2/h2_run.sh` and `tools/t2/h2_matrix.sh`, and a green run here says
# nothing about either.
#
# USAGE
#   tools/verify_all.sh                  everything
#   tools/verify_all.sh --fast           skip the app's Flutter steps (~2 min)
#   tools/verify_all.sh --report out.md  write the report somewhere specific
#
# Exit: 0 when every step passed, 1 otherwise. Never leaves a half-written
# report: the file is completed on every exit path.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$REPO/tools/verify-report-$STAMP.md"
LOGDIR=$(mktemp -d /tmp/verify_all.XXXXXX)
FAST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fast) FAST=1; shift ;;
    --report) REPORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Dart/Flutter must be the SDK the repo pins. A different flutter on PATH
# selects a different Dart, and this repo has already lost an afternoon to
# exactly that (see the note in tools/t2/h2_run.sh).
FLUTTER_BIN=$(command -v flutter || true)
DART_BIN=$(command -v dart || true)
[ -n "$FLUTTER_BIN" ] || { echo "flutter not on PATH" >&2; exit 2; }
[ -n "$DART_BIN" ] || { echo "dart not on PATH" >&2; exit 2; }

PASS=0
FAIL=0
SKIP=0
declare -a ROWS=()

# WHERE A STEP RUNS IS PART OF THE STEP.
#
# The first version ran everything from the repository root, including
# `dart test packages/<pkg>`. That is a legal invocation, but two tests in this
# repo open files by RELATIVE path — `bin/manifest_keygen.dart`,
# `lib/src/rateless_stream.dart` — so from the root they resolved against the
# workspace and threw PathNotFound. Two packages went red while nothing in them
# was broken.
#
# A harness that manufactures failures is worse than no harness: a false FAIL
# costs the same attention as a real one and teaches you to distrust the
# report. So each package is tested from its OWN directory, which is where a
# developer runs it and therefore the only place whose result is meaningful.
# (The tests were also made cwd-independent, because two defences against a
# silent wrong answer are the right number.)
step_in() {
  local dir="$1" name="$2"; shift 2
  local log="$LOGDIR/$(echo "$name" | tr ' /' '__').log"
  printf '%-46s ' "$name"
  local started ended
  started=$(date +%s)
  ( cd "$dir" && "$@" ) >"$log" 2>&1
  local rc=$?
  ended=$(date +%s)
  local secs=$(( ended - started ))

  # Pull the one line that actually says what happened, per tool.
  local summary
  summary=$(grep -oE 'No issues found!|[0-9]+ issues? found|All tests passed!|\+[0-9]+( -[0-9]+)?: (All tests passed!|Some tests failed)|[0-9]+ tests? passed|Some tests failed' "$log" | tail -1)
  summary="${summary:-see log}"

  local res=PASS
  [ $rc -eq 0 ] || res=FAIL
  echo "$res  (${secs}s)  $summary"
  if [ "$res" = PASS ]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi
  ROWS+=("$res	$name	${secs}s	$summary	$log	cd ${dir#"$REPO"/} && $*")
}

step() { step_in "$REPO" "$@"; }

skip() {
  local name="$1" why="$2"
  printf '%-46s SKIP  %s\n' "$name" "$why"
  SKIP=$(( SKIP + 1 ))
  ROWS+=("SKIP	$name	-	$why	-	-")
}

# THE FAILURE TEXT, NOT THE FIRST N LINES.
#
# This used to be `head -40`. On a `--reporter expanded` log the first forty
# lines are forty PASSING tests, so the report announced a failure and then
# printed a wall of successes — worse than printing nothing, because it looks
# like evidence. A failure appears wherever it happens, so select it by MARKER,
# and when no marker matches fall back to the END of the log, never the
# beginning: a command that dies says why on its way out.
excerpt() {
  local log="$1" out=''
  # dart/flutter test: `[E]` opens a block that runs to the next progress line.
  out=$(awk '
    /\[E\]$/ { inblock = 1 }
    inblock  { print }
    inblock && /^[0-9][0-9]:[0-9][0-9] \+[0-9]+( -[0-9]+)?: / && !/\[E\]$/ { inblock = 0 }
  ' "$log" 2>/dev/null | head -60)
  # dart analyze (`error - file:line`) and flutter analyze (`error • …`).
  [ -n "$out" ] || out=$(grep -E '^[[:space:]]*(error|warning|info)[[:space:]]*[-•]' "$log" 2>/dev/null | head -40)
  [ -n "$out" ] || out=$(tail -40 "$log" 2>/dev/null)
  [ -n "$out" ] || out='(log empty)'
  printf '%s\n' "$out"
}

# The report is written from a trap, so an interrupted run still leaves a
# readable artifact rather than nothing.
write_report() {
  {
    echo "# Verification report"
    echo
    echo "_$(date -u +%FT%TZ) · $(uname -s) $(uname -r) · $($FLUTTER_BIN --version 2>/dev/null | head -1)_"
    echo
    echo '```'
    echo "flutter  $FLUTTER_BIN"
    echo "dart     $DART_BIN"
    echo '```'
    echo
    if [ $FAIL -eq 0 ] && [ $PASS -gt 0 ]; then
      echo "## Verdict: GREEN — $PASS passed, $SKIP skipped"
    else
      echo "## Verdict: RED — $FAIL failed, $PASS passed, $SKIP skipped"
    fi
    echo
    echo '| result | step | time | summary |'
    echo '|---|---|---|---|'
    for r in "${ROWS[@]}"; do
      IFS=$'\t' read -r res name secs sum _log _cmd <<<"$r"
      echo "| $res | \`$name\` | $secs | $sum |"
    done
    echo
    if [ $FAIL -gt 0 ]; then
      echo '## Failures'
      echo
      echo 'Each excerpt is the FAILING text — the `[E]` blocks for a test run,'
      echo 'the diagnostics for an analyzer run — not the head of the log. The'
      echo 'exact invocation is given with each one, because the difference'
      echo 'between a broken package and a badly-invoked harness is not visible'
      echo 'in the failure text alone.'
      echo
      for r in "${ROWS[@]}"; do
        IFS=$'\t' read -r res name _secs _sum log cmd <<<"$r"
        [ "$res" = FAIL ] || continue
        echo "### $name"
        echo
        echo "Invoked as: \`$cmd\`"
        echo
        echo '```'
        excerpt "$log"
        echo '```'
        echo
        echo "Full log: \`$log\`"
        echo
      done
    fi
    echo '## What this report does NOT cover'
    echo
    echo '- **No device, and no radio.** Everything above runs on this Mac against'
    echo '  the host loopback. Nothing was installed on a phone, no call was placed,'
    echo '  and no packet crossed a real network — which is why it finishes in'
    echo '  minutes. A green report here is a statement about the code, not about'
    echo '  the product.'
    echo '- **No shaped network.** Loss, latency and bandwidth numbers come from'
    echo '  `sudo tools/t2/h2_matrix.sh`, which drives pf/dummynet and a physical'
    echo '  iPhone; they live in `h2_results.tsv`, not here.'
    echo '- **Analysis is not a test.** `No issues found` means it compiles and'
    echo '  lints, which is the floor, not the ceiling.'
    echo '- **The simulations are simulations.** They exercise the same arithmetic'
    echo '  the documents cite, on synthetic channels.'
    echo
    echo 'To cover the first two, with the phone attached and unlocked:'
    echo
    echo '```'
    echo 'sudo tools/t2/h2_run.sh clean integration_test/sla_thresholds_test.dart'
    echo 'sudo tools/t2/h2_matrix.sh    # every profile, ~1 h'
    echo '```'
    echo
    echo "Logs for every step: \`$LOGDIR\`"
  } >"$REPORT"
}
trap 'write_report; echo; echo "report: $REPORT"' EXIT INT TERM

echo "=============================================================="
echo " verify_all · $STAMP"
echo "=============================================================="
echo

# --- 1. resolve dependencies once, loudly ---------------------------------
step "pub get (workspace)" "$FLUTTER_BIN" pub get

# --- 2. static analysis ----------------------------------------------------
# Pure-Dart packages first: they are fast, and a type error here explains most
# app failures downstream.
for pkg in adaptive_transport connection_orchestrator messaging signed_config \
           call_core media_webrtc quality_governor security device_link; do
  if [ -d "$REPO/packages/$pkg" ]; then
    step_in "$REPO/packages/$pkg" "analyze packages/$pkg" "$DART_BIN" analyze .
  else
    skip "analyze packages/$pkg" "no such package"
  fi
done

if [ $FAST -eq 0 ]; then
  step "analyze apps/reference_app" "$FLUTTER_BIN" analyze apps/reference_app
else
  skip "analyze apps/reference_app" "--fast"
fi

# --- 3. unit tests ---------------------------------------------------------
for pkg in adaptive_transport connection_orchestrator messaging signed_config \
           call_core media_webrtc quality_governor security device_link; do
  if [ -d "$REPO/packages/$pkg/test" ]; then
    step_in "$REPO/packages/$pkg" "test packages/$pkg" \
      "$DART_BIN" test --reporter expanded
  else
    skip "test packages/$pkg" "no test directory"
  fi
done

# --- 4. app tests (Flutter binding required) -------------------------------
if [ $FAST -eq 0 ]; then
  if [ -d "$REPO/apps/reference_app/test" ]; then
    step_in "$REPO/apps/reference_app" "test apps/reference_app" \
      "$FLUTTER_BIN" test --reporter expanded
  else
    skip "test apps/reference_app" "no test directory"
  fi
else
  skip "test apps/reference_app" "--fast"
fi

# --- 5. the repo's own matrix, if it exists --------------------------------
# "absent" and "present but not executable" are different facts and only one of
# them is fixable with chmod; reporting them as one string sent the reader
# looking for a permission problem on a file that does not exist.
if [ -x "$REPO/tools/test-matrix.sh" ]; then
  step "tools/test-matrix.sh" bash "$REPO/tools/test-matrix.sh"
elif [ -f "$REPO/tools/test-matrix.sh" ]; then
  skip "tools/test-matrix.sh" "present but not executable (chmod +x)"
else
  skip "tools/test-matrix.sh" "absent"
fi

# --- 6. simulation harnesses (no network, no device) -----------------------
# These produce the numbers several documents cite; running them here keeps a
# claim and its evidence from drifting apart.
BENCH="$REPO/../questions/compression-bench"
if [ -d "$BENCH" ] && command -v python3 >/dev/null; then
  for sim in v8b_headsim.py v8c_multilane.py v8d_probe.py v8e_verify_dart_logic.py; do
    if [ -f "$BENCH/$sim" ]; then
      step "sim $sim" python3 "$BENCH/$sim"
    fi
  done
else
  skip "simulation harnesses" "compression-bench or python3 absent"
fi

echo
echo "=============================================================="
printf ' %d passed · %d failed · %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo "=============================================================="

# SAY WHAT WAS NOT RUN, ON THE TERMINAL, EVERY TIME.
#
# This finishes in minutes and never touches a phone, and a run that ends on a
# clean summary invites the reading that the product was verified. It was not:
# nothing here installs a build, places a call, or sends a byte across a real
# radio. The limits are already in the report, but a limit nobody scrolls to is
# a limit nobody reads — so it goes here too, next to the number it qualifies.
echo
echo "NOT covered by this run: no phone, no radio, no shaped network."
echo "  Everything above ran on this Mac. To measure the device path:"
DEVICES=$("$FLUTTER_BIN" devices --machine 2>/dev/null | grep -c '"targetPlatform": "ios' || true)
if [ "${DEVICES:-0}" -gt 0 ]; then
  echo "  (an iOS device IS attached right now)"
else
  echo "  (no iOS device attached — attach and unlock one first)"
fi
echo "    sudo tools/t2/h2_run.sh clean integration_test/sla_thresholds_test.dart"
echo "    sudo tools/t2/h2_matrix.sh"

[ "$FAIL" -eq 0 ]
