#!/bin/bash
# T3 driver v2 — attach-then-shape. v1 drove the matrix through h2_run.sh,
# which applies the profile BEFORE flutter attaches; under t3x the
# CoreDevice debug tunnel (QUIC/UDP) died in launch, measured verbatim:
# "Unable to start the app on the device" (h2run.lMUVqM/test.log). So this
# driver owns the sequence instead:
#   1. real datagram relay up (unshaped)
#   2. flutter test attaches to the device UNSHAPED
#   3. on the test's E2E_MATRIX_WAITING_FOR_SHAPE marker, net_shape.sh
#      applies the t3x numbers; the in-test rtt-probe barrier releases the
#      matrix only when the lane OBSERVES the shaped path (>1500ms echo),
#      which doubles as the traffic-crossed-the-shaped-interface proof
#   4. teardown from a trap — success, failure or Ctrl-C alike
# Profile claim (FULL_TEST_PLAN track 3): bw 2Kbit/s per crossing, one-way
# delay 1000ms (rtt 2000ms), loss 60% end-to-end composed as 0.3675 per
# crossing (probe-suite convention: matching, not doubling). The pipe is
# shared by both crossings, so the applied bw is doubled to 4Kbit/s —
# h2_run.sh's own calibration rule.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO/apps/reference_app"
DLOGS="$REPO/tools/dossier/logs"
E2E="$REPO/tools/dossier/e2e_ios_results.tsv"
SHAPE="$REPO/tools/t2/net_shape.sh"
IFACE="${T2_IFACE:-bridge100}"
export T2_SHAPE_TCP_PORT="{ 8443 }"
UDID=$(tr -d '[:space:]' < "$DLOGS/device_udid.txt")
[ -n "$UDID" ] || { echo "no UDID recorded"; exit 1; }
SELF=$(ifconfig "$IFACE" | awk '/inet /{print $2; exit}')
[ -n "$SELF" ] || { echo "no IPv4 on $IFACE"; exit 1; }
TESTLOG="$DLOGS/e2e_matrix_test.log"

RELAY_PID=""
TEST_PID=""
teardown() {
  sudo "$SHAPE" teardown >/dev/null 2>&1 || true
  [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null || true
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
}
trap teardown EXIT

# shaping evidence for gate_t3 — the whole driver transcript
exec > >(tee "$DLOGS/e2e_netshape.log") 2>&1

echo "== t3 matrix v2 $(date -u +%Y-%m-%dT%H:%M:%SZ) device=$UDID self=$SELF =="
echo "profile t3x: bw 2Kbit/s per crossing (4Kbit/s applied, shared pipe),"
echo "one-way delay 1000ms => rtt 2000ms, plr 0.3675/crossing = 60% end-to-end"

pkill -f 'datagram_relay' 2>/dev/null || true
( cd "$REPO/server/signaling_server" \
  && exec dart run bin/datagram_relay.dart --port 3737 ) \
  > "$DLOGS/e2e_dgram_relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 60); do
  grep -q 'datagram relay listening on' "$DLOGS/e2e_dgram_relay.log" && break
  sleep 1
done
grep -q 'datagram relay listening on' "$DLOGS/e2e_dgram_relay.log" \
  || { echo "relay never became ready"; exit 1; }
echo "relay up (pid $RELAY_PID)"

( cd "$APP" && flutter test --no-pub \
    --dart-define=E2E_DGRAM_HOST="$SELF" \
    --dart-define=E2E_DGRAM_PORT=3737 \
    integration_test/e2e_matrix_test.dart -d "$UDID" ) > "$TESTLOG" 2>&1 &
TEST_PID=$!

# wait for the attach + the barrier marker (build/install can take minutes)
for _ in $(seq 1 180); do
  grep -aq 'E2E_MATRIX_WAITING_FOR_SHAPE' "$TESTLOG" && break
  kill -0 "$TEST_PID" 2>/dev/null || break
  sleep 5
done
if ! grep -aq 'E2E_MATRIX_WAITING_FOR_SHAPE' "$TESTLOG"; then
  echo "attach failed before the barrier; tail of test log:"
  tail -20 "$TESTLOG"
  exit 1
fi
echo "attached; applying the profile NOW"
sudo "$SHAPE" shape 4Kbit/s 1000 0.3675
sudo "$SHAPE" status | head -12 || true

wait "$TEST_PID"
TEST_RC=$?
TEST_PID=""
sudo "$SHAPE" teardown >/dev/null 2>&1 || true
echo "flutter exit=$TEST_RC (shape torn down)"

grep -a 'SHAPE_OBSERVED' "$TESTLOG" || echo "WARN: no SHAPE_OBSERVED line"

TMPF="$E2E.tmp.$$"
printf 'Feature\tWireBytes\tBudget_s\tMeasured_s\tStatus\tNote\n' > "$TMPF"
grep -a $'^E2E_ROW\t' "$TESTLOG" | cut -f2- >> "$TMPF" || true
ROWS=$(($(wc -l < "$TMPF") - 1))
mv "$TMPF" "$E2E"
echo "e2e_ios_results.tsv rows: $ROWS"
cat "$E2E"
[ "$ROWS" = 6 ] || { echo "expected 6 rows, got $ROWS"; exit 1; }
exit "$TEST_RC"
