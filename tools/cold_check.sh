#!/bin/bash
# Cold-check gate: fresh pub get + strict analyze + full tests, every package.
cd "$(dirname "$0")/.." || exit 1
out=/tmp/cold_check_results.txt
: > "$out"
for d in packages/*/; do
  p=$(basename "$d")
  cd "$d" || continue
  pg="OK"; dart pub get >/dev/null 2>&1 || pg="FAIL"
  an=$(dart analyze 2>&1 | tail -1)
  if ls test/*_test.dart >/dev/null 2>&1 || [ -d test ]; then
    tl=$(dart test 2>&1 | tail -1)
  else
    tl="(no tests)"
  fi
  echo "$p | pubget=$pg | analyze=$an | test=$tl" >> "../../$out" 2>/dev/null
  echo "$p | pubget=$pg | analyze=$an | test=$tl" >> "$out" 2>/dev/null
  cd ../..
done
cat "$out"
