#!/usr/bin/env bash
# Analyze + test every workspace package and the app, and report per-target
# counts. Non-zero exit if any target fails analysis or tests.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Where the full analyze/test output is kept. Inside the repo tree and dated,
# not in a mktemp directory: an intermittent failure is only useful if its log
# still exists the next time it happens.
GATE_LOGS="$(pwd)/tools/suite-logs/gate-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$GATE_LOGS" || exit 1

fail=0
total=0

run_target() {
  local dir="$1" runner="$2" name
  name="$(basename "$dir")"
  [ -f "$dir/pubspec.yaml" ] || return 0

  local analyze
  # The output goes to a log on the way into the variable. A variable does not
  # survive an interrupt or a crash, and every line this function does not
  # print is gone with it — which is how an intermittent failure loses its
  # name. `tee` costs one token and keeps the whole run readable afterwards.
  analyze="$(cd "$dir" && $runner analyze 2>&1 | tee "$GATE_LOGS/$name.analyze.log")"
  if ! grep -q "No issues found" <<<"$analyze"; then
    echo "ANALYZE FAIL  $name"
    grep -E "error|warning" <<<"$analyze" | head -20
    fail=1
  fi

  local out passed
  out="$(cd "$dir" && $runner test 2>&1 | tee "$GATE_LOGS/$name.test.log")"
  # Read the count off the runner's own summary line, not off any +N in
  # the stream. A test's stdout can print something matching +N, and the
  # progress line the runner rewrites in place is not reliably last —
  # taking either the last or the largest match miscounts in both
  # directions.
  passed="$(grep -oE '\+[0-9]+[^:]*: (All tests passed|Some tests failed)' \
    <<<"$out" | grep -oE '\+[0-9]+' | tail -1 | tr -d '+')"
  passed="${passed:-0}"
  if grep -qE "All tests passed|No tests ran" <<<"$out"; then
    printf 'OK   %-28s %5s passed\n' "$name" "$passed"
    total=$((total + passed))
  else
    printf 'FAIL %-28s %5s passed\n' "$name" "$passed"
    grep -E "^\s+/.*_test\.dart:" <<<"$out" | head -10
    fail=1
    total=$((total + passed))
  fi
}

for pkg in packages/*/; do
  # A package that depends on the Flutter SDK must run under `flutter test`;
  # `dart test` cannot resolve its dev dependencies at all.
  if grep -qE '^\s+flutter:\s*$' "$pkg/pubspec.yaml" 2>/dev/null; then
    run_target "$pkg" flutter
  else
    run_target "$pkg" dart
  fi
done
run_target apps/reference_app flutter

echo "---------------------------------------------"
echo "TOTAL PASSED: $total"

# The three repo-wide gates CI also runs, so a local pass means the same
# thing a CI pass does.
echo "--- repo-wide gates ---"

if dart format --output=none --set-exit-if-changed . > /tmp/gate-format.log 2>&1
then
  echo "OK   format"
else
  echo "FAIL format          $(grep -c '^Changed' /tmp/gate-format.log) file(s)"
  fail=1
fi

if dart analyze --fatal-infos --fatal-warnings > /tmp/gate-analyze.log 2>&1; then
  echo "OK   analyze"
else
  echo "FAIL analyze"
  grep -E ' (error|warning|info) ' /tmp/gate-analyze.log | head -20
  fail=1
fi

if dart run tool/architecture_guard.dart > /tmp/gate-guard.log 2>&1; then
  echo "OK   architecture guard"
else
  echo "FAIL architecture guard"
  tail -10 /tmp/gate-guard.log
  fail=1
fi

# On-wire leak no-regression gate. The evaluator lives in a separate engine
# repo (LEAK_GATE_ENGINE_DIR). Contrast with the node section below: a
# missing node SKIPS silently because the Dart workspace does not need it —
# a missing engine is REPORTED as NOT RUN so it can never read as a pass,
# but it does not fail the local gate (only a real regression, exit 1, does).
bash tools/leak_gate.sh > /tmp/gate-leak.log 2>&1
leak_rc=$?
if [ "$leak_rc" -eq 0 ]; then
  echo "OK   leak gate         $(grep -oE 'kl=[0-9.]+' /tmp/gate-leak.log | head -1)"
elif [ "$leak_rc" -eq 3 ]; then
  echo "NOT RUN leak gate      engine dir unset/unbuildable (reported, not a skip; set LEAK_GATE_ENGINE_DIR)"
else
  echo "FAIL leak gate         (exit $leak_rc)"
  tail -10 /tmp/gate-leak.log
  fail=1
fi

# The relay worker is JavaScript, so it sits outside the Dart gates above.
# Mirrored here from the CI relay job so a local run covers the same
# ground; skipped rather than failed when node is absent, because the
# Dart workspace does not need it.
if command -v node > /dev/null 2>&1; then
  if (cd tools/cloudflare_relay_worker && node --test) \
      > /tmp/gate-worker.log 2>&1; then
    echo "OK   relay worker      $(grep -c '^✔' /tmp/gate-worker.log) passed"
  else
    echo "FAIL relay worker"
    grep -E '^(✖|not ok)' /tmp/gate-worker.log | head -10
    fail=1
  fi
  if (cd tools/web_verifier && node --test) > /tmp/gate-verifier.log 2>&1
  then
    echo "OK   web verifier      $(grep -c '^✔' /tmp/gate-verifier.log) passed"
  else
    echo "FAIL web verifier"
    grep -E '^(✖|not ok)' /tmp/gate-verifier.log | head -10
    fail=1
  fi
else
  echo "SKIP relay worker      node not installed"
  echo "SKIP web verifier      node not installed"
fi

exit "$fail"
