#!/bin/bash
# Real-wire check of the letter path probe: Python responder on UDP + Dart client.
# Cases: 300 B letter, 4096 B letter (the cap), 4097 B (refused), all resolvers dead (queued).
set -u
cd "$(dirname "$0")"
PORT=${PORT:-53531}
DEAD=${DEAD:-53539}
OUT=$(mktemp -d)
python3 txt_query_server.py --domain valve.test --host 127.0.0.1 --port "$PORT" --letter-dir "$OUT/letters" > "$OUT/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1
cd ../../packages/adaptive_transport
fail=0
for n in 300 4096 4097; do
  dart run tool/letter_probe_e2e.dart "$PORT" "$DEAD" "$n" || { echo "CASE $n FAIL"; fail=1; }
done
# Every resolver dead: expect route=queued (exit 1 from the tool is the expected outcome here).
dart run tool/letter_probe_e2e.dart "$DEAD" "$DEAD" 50 | grep -q "route=queued" && echo "CASE all-dead queued PASS" || { echo "CASE all-dead FAIL"; fail=1; }
sleep 1
kill $SRV 2>/dev/null
wait $SRV 2>/dev/null
echo "--- server log (probe + letter lines) ---"
grep -E "probe group|complete session|letter session" "$OUT/server.log"
echo "letters on disk: $(ls "$OUT/letters" 2>/dev/null | wc -l | tr -d ' ')"
echo "E2E $([ $fail = 0 ] && echo PASS || echo FAIL) ($OUT)"
exit $fail
