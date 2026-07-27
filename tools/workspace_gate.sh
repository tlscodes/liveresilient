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
  passed="$(grep -oE '\+[0-9]+' <<<"$out" | tail -1 | tr -d '+')"
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
exit "$fail"
