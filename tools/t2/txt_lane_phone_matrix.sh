#!/usr/bin/env bash
# txt_lane_phone_matrix.sh — the DNS TXT-query lane on the rig iPhone under
# the same impairment profiles the app journey matrix uses (same shaper,
# same numbers, tools/t2/net_shape.sh on bridge100).
#
# One profile at a time: shape bridge100 for the phone, run
# apps/reference_app/integration_test/txt_query_lane_on_device_test.dart on
# the phone against tools/t2/txt_query_server.py bound to the Mac's
# bridge100 address, tear the shaping down, append the measured rows.
#
# Every `TXTLANE …` line the test prints becomes one TSV row; every failing
# case becomes a `FAIL` row naming the case; the flutter summary is the last
# row of the profile. Nothing is interpreted here — the TSV is the record.
#
# USAGE  tools/t2/txt_lane_phone_matrix.sh [profile ...]
#        default: clean normal latency loss10 bandwidth narrow loss60 extreme
#        JOURNEY_PHONE=<udid>  T2_IFACE=bridge100  T2_PEER=192.168.2.2
#        VALVE_PORT=5300  VALVE_DOMAIN=valve.test  override the defaults.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SHAPE="$REPO/tools/t2/net_shape.sh"
APP="$REPO/apps/reference_app"
TEST="integration_test/txt_query_lane_on_device_test.dart"
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
IFACE=${T2_IFACE:-bridge100}
PEER=${T2_PEER:-192.168.2.2}
PORT=${VALVE_PORT:-5300}
ZONE=${VALVE_DOMAIN:-valve.test}
TSV="$REPO/tools/dossier/txt_lane_phone_matrix.tsv"
LOGD="$REPO/tools/dossier/logs/txt_lane"
PROFILES=("$@")
[ ${#PROFILES[@]} -gt 0 ] || PROFILES=(clean normal latency loss10 bandwidth narrow loss60 extreme)

SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -n "$SELF" ] || { echo "ERROR: $IFACE has no address — Internet Sharing on, phone joined?" >&2; exit 1; }
RUN_ID=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$LOGD"

# The same numbers journey_run.sh hands the shaper (bw delay_ms plr).
profile_args() {
  case "$1" in
    clean)     echo "" ;;
    normal)    echo "-        40    0.0" ;;
    latency)   echo "-        900   0.0" ;;
    bandwidth) echo "32Kbit/s -     0.0" ;;
    narrow)    echo "16Kbit/s -     0.0" ;;
    loss10)    echo "-        -     0.10" ;;
    loss60)    echo "-        -     0.60" ;;
    extreme)   echo "16Kbit/s 1000  0.15" ;;
    *) echo "ERROR: unknown profile '$1'" >&2; exit 2 ;;
  esac
}
for p in "${PROFILES[@]}"; do profile_args "$p" >/dev/null; done

RESP=""
cleanup() {
  sudo -n "$SHAPE" teardown >/dev/null 2>&1 || true
  [ -n "$RESP" ] && kill "$RESP" 2>/dev/null || true
  echo "cleanup: shaping torn down, responder stopped"
}
trap 'exit 130' INT; trap 'exit 143' TERM; trap cleanup EXIT

sudo -n "$SHAPE" check || { echo "ERROR: the shaper cannot see $IFACE (net_shape.sh check)" >&2; exit 1; }

PYTHONUNBUFFERED=1 python3 "$REPO/tools/t2/txt_query_server.py" \
  --domain "$ZONE" --host "$SELF" --port "$PORT" >"$LOGD/responder.log" 2>&1 &
RESP=$!
sleep 1
kill -0 "$RESP" 2>/dev/null || { echo "ERROR: responder did not start (see $LOGD/responder.log)" >&2; exit 1; }
echo "responder $SELF:$PORT zone $ZONE (pid $RESP)   phone $PHONE   peer $PEER on $IFACE"

[ -f "$TSV" ] || printf 'run_id\tprofile\tbw\tdelay_ms\tplr\tcase\tresult\n' >"$TSV"
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RUN_ID" "$1" "$2" "$3" "$4" "$5" "$6" >>"$TSV"; }

for p in "${PROFILES[@]}"; do
  args=$(profile_args "$p")
  BW=-; DELAY=-; PLR=-
  [ -z "$args" ] || read -r BW DELAY PLR <<<"$args"
  LOG="$LOGD/$p.log"; : >"$LOG"
  echo "profile   $p   bw=$BW delay=$DELAY plr=$PLR   -> $LOG"
  started=$(date +%s)
  # The same define set for every profile, so one cached build serves all.
  ( cd "$APP" && flutter test "$TEST" -d "$PHONE" \
      --dart-define=VALVE_HOST="$SELF" --dart-define=VALVE_PORT="$PORT" \
      --dart-define=VALVE_DOMAIN="$ZONE" --dart-define=VALVE_SHAPED=true \
      --dart-define=VALVE_SETTLE_MS="${VALVE_SETTLE_MS:-8000}" >>"$LOG" 2>&1 ) &
  RUN=$!
  # Shape only once the app is up on the phone. At 60 % loss the launch
  # handshake itself never completed (2026-09-13, 22 min in "Installing and
  # launching"); the lane cases start after the test's setUpAll prints its
  # marker and holds VALVE_SETTLE_MS, which is when the shaping lands.
  if [ -n "$args" ]; then
    waited=0
    until grep -q '^TXTLANE shaped=' "$LOG" 2>/dev/null || ! kill -0 "$RUN" 2>/dev/null; do
      sleep 1; waited=$((waited + 1))
      if [ "$waited" -ge "${LAUNCH_CAP_S:-1500}" ]; then
        echo "ERROR: $p — the app did not come up within ${LAUNCH_CAP_S:-1500}s; killing the run" >&2
        kill "$RUN" 2>/dev/null || true
        break
      fi
    done
    if kill -0 "$RUN" 2>/dev/null; then
      # The script-scoped sudoers rule may refuse env for the shaper
      # (measured 2026-09-13: "not allowed to set ... T2_PEER");
      # journey_run.sh falls back the same way — all UDP on the interface,
      # which on this rig is the phone alone.
      if ! sudo -n T2_PEER="$PEER" "$SHAPE" shape "$BW" "$DELAY" "$PLR" 2>/dev/null; then
        echo "note: sudo refused env for the shaper; shaping ALL UDP on $IFACE"
        sudo -n "$SHAPE" shape "$BW" "$DELAY" "$PLR" \
          || { echo "ERROR: shaping failed for $p" >&2; kill "$RUN" 2>/dev/null; exit 1; }
      fi
      echo "shaped    $p   after ${waited}s (app up)"
    fi
  fi
  wait "$RUN" || true
  grep -E '^TXTLANE |All tests passed|Some tests failed|\[E\]$' "$LOG" | sed 's/^/  /' || true
  sudo -n "$SHAPE" teardown >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - started ))

  while IFS= read -r line; do
    kase=$(printf '%s' "$line" | sed -E 's/^TXTLANE (case=[^ ]+ )?.*/\1/' | sed -E 's/^case=//; s/ $//')
    rest=$(printf '%s' "$line" | sed -E 's/^TXTLANE (case=[^ ]+ )?//')
    row "$p" "$BW" "$DELAY" "$PLR" "${kase:-setup}" "$rest"
  done < <(grep -E '^TXTLANE ' "$LOG" || true)
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -E 's/^[0-9:]+ \+[0-9]+ -[0-9]+: (.*) \[E\]$/\1/')
    row "$p" "$BW" "$DELAY" "$PLR" "FAIL" "$name"
  done < <(grep -E '^[0-9:]+ \+[0-9]+ -[0-9]+: .*\[E\]$' "$LOG" || true)
  summary=$(grep -oE 'All tests passed!|Some tests failed\.' "$LOG" | tail -1 || true)
  row "$p" "$BW" "$DELAY" "$PLR" "summary" "${summary:-NO SUMMARY (build or launch failed)} elapsed=${elapsed}s"
  echo "verdict   $p   ${summary:-NO SUMMARY}   (${elapsed}s)"
done
echo "rows      $TSV"
