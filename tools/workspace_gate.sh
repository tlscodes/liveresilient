#!/usr/bin/env bash
# Analyze + test every workspace package and the app, and report per-target
# counts. Non-zero exit if any target fails analysis or tests.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
total=0

run_target() {
  local dir="$1" runner="$2" name
  name="$(basename "$dir")"
  [ -f "$dir/pubspec.yaml" ] || return 0

  local analyze
  analyze="$(cd "$dir" && $runner analyze 2>&1)"
  if ! grep -q "No issues found" <<<"$analyze"; then
    echo "ANALYZE FAIL  $name"
    grep -E "error|warning" <<<"$analyze" | head -20
    fail=1
  fi

  local out passed
  out="$(cd "$dir" && $runner test 2>&1)"
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
