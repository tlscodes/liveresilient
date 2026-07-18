#!/usr/bin/env bash
# Mirrors the CI "Tests with coverage" step exactly, so the gate can be
# reproduced locally before pushing. Keep in sync with .github/workflows/ci.yml.
set -e
cd "$(dirname "$0")/.."
found=0
for d in packages/*/ apps/*/ server/*/ integration_test/ tool/*/; do
  [ -d "${d}test" ] || continue
  if grep -q 'sdk: flutter' "${d}pubspec.yaml" 2>/dev/null; then
    echo "== testing ${d} (flutter)"
    (cd "$d" && flutter test)
  else
    echo "== testing ${d} (dart)"
    (cd "$d" && dart test)
  fi
  found=1
done
if [ "$found" = "0" ]; then
  echo "No test/ directories found — that is itself a gate failure."
  exit 1
fi
echo "GATE LOOP OK"
