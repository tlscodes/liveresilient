#!/usr/bin/env bash
# journey_run.sh — one impairment profile of tools/BRIEF_matrix_app_journey.md:
# shape the phone's link, VERIFY the shaping took effect, run the reference app
# on the Mac (its own screens) against a headless real peer on the phone, record
# the Mac screen, restore, and append one TSV row per feature to
# tools/dossier/app_journey_results.tsv.
#
# Topology (decided 2026-09-03): Mac app = receiver, joins by key through its
# "Join with key" dialog against the relay at wss://localhost:4443 (unshaped
# loopback, declared in every row); phone = initiator (E2eCallStack) via
# wss://<bridge addr>:4443/ over bridge100, which is what the shaper impairs.
# Media crosses bridge100 ONCE (direct host candidates), so the pipe loss is
# the profile loss as stated — not the per-crossing derivation h2_run.sh uses
# for the relayed datagram path.
#
# The shaper is the only privileged step and runs through the script-scoped
# sudoers rule (`sudo -n tools/t2/net_shape.sh …`); nothing else needs root.
#
# USAGE  tools/t2/journey_run.sh <profile>      (normal|latency|loss10|bandwidth|narrow|loss60|extreme)
#        JOURNEY_PHONE=<udid> JOURNEY_HOLD_S=45 JOURNEY_KEY=<22 chars> override defaults.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROFILE=${1:?profile}
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
IFACE=${T2_IFACE:-bridge100}
PEER=${T2_PEER:-192.168.2.2}
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
RELAY_PORT=${JOURNEY_RELAY_PORT:-4443}
KEY=${JOURNEY_KEY:-journeyKeyAbCdEfGhIjKl}
HOLD=${JOURNEY_HOLD_S:-45}
BUDGET=${JOURNEY_CONNECT_BUDGET_S:-300}
SHAPE="$REPO/tools/t2/net_shape.sh"
EVID="$REPO/tools/dossier/evidence/journey"
LOGD="$REPO/tools/dossier/logs/journey"
TSV="$REPO/tools/dossier/app_journey_results.tsv"
APP="$REPO/apps/reference_app"
# The Mac app is sandboxed (macos/Runner/DebugProfile.entitlements), so the
# READY/GO files must live inside its container — /tmp is "Operation not
# permitted" from inside the app (measured 2026-09-03, first run).
CONTAINER_TMP="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp"
mkdir -p "$CONTAINER_TMP"
RUN=$(mktemp -d "$CONTAINER_TMP/journey.XXXXXX")
READY="$RUN/ready"; GO="$RUN/go"
mkdir -p "$EVID" "$LOGD"

die() { echo "ERROR: $*" >&2; exit 1; }

profile_args() {
  case "$1" in
    normal)    echo "-        40    0.0" ;;
    latency)   echo "-        900   0.0" ;;
    bandwidth) echo "32Kbit/s -     0.0" ;;
    narrow)    echo "16Kbit/s -     0.0" ;;
    loss10)    echo "-        -     0.10" ;;
    loss60)    echo "-        -     0.60" ;;
    extreme)   echo "16Kbit/s 1000  0.15" ;;
    *) die "unknown profile $1" ;;
  esac
}
read -r BW DELAY PLR <<<"$(profile_args "$PROFILE")"

[ -n "$SELF" ] || die "$IFACE has no address — Internet Sharing on, phone joined?"
curl -sk --max-time 5 "https://127.0.0.1:$RELAY_PORT/" >/dev/null 2>&1 \
  || echo "note: relay on $RELAY_PORT did not answer an HTTP probe (WSS-only relays may still be fine)"

shaper() { sudo -n "$SHAPE" "$@"; }

cleanup() {
  shaper teardown >/dev/null 2>&1 || true
  pkill -P $$ 2>/dev/null || true
  # flutter test forks xcodebuild and dart VMs that outlive their parent and
  # hold the build lock (loss60 and extreme, 2026-09-03: every later macOS
  # build hung at "Building macOS application..."). Kill the whole tree.
  pkill -f "integration_test/journey_" 2>/dev/null || true
  pkill -f "xcodebuild.*reference_app" 2>/dev/null || true
  pkill -f "macos_assemble.sh" 2>/dev/null || true
  echo "cleanup: shaping torn down, children stopped"
}
trap cleanup EXIT INT TERM
# Keep display and system awake for the whole run (the recorder and the app
# both stall when the display sleeps); caffeinate dies with this script.
caffeinate -dimsu -w $$ >/dev/null 2>&1 &

# The phone polls this over plain HTTP on the bridge address before it offers
# (dart:io is not subject to App Transport Security). Served from $RUN.
HTTP_PORT=${JOURNEY_HTTP_PORT:-8765}
( cd "$RUN" && exec python3 -m http.server "$HTTP_PORT" --bind "$SELF" ) >/dev/null 2>&1 &
# The phone's microphone prompt is pending on this install (measured
# 2026-09-03: getUserMedia timed out after 30 s). noLocalAudio keeps the run
# honest and recorded as such; set JOURNEY_PHONE_MEDIA=realAudio once granted.
PHONE_MEDIA=${JOURNEY_PHONE_MEDIA:-noLocalAudio}

echo "profile   $PROFILE  (bw=$BW delay=$DELAY plr=$PLR)"
echo "iface     $IFACE   self $SELF   peer $PEER   relay wss://$SELF:$RELAY_PORT/"
echo "phone     $PHONE   key $KEY   hold ${HOLD}s   budget ${BUDGET}s"

# --- shape and VERIFY (rows under unverified shaping are worse than no row) ---
shaper teardown >/dev/null 2>&1 || true
if ! sudo -n T2_PEER="$PEER" T2_SHAPE_TCP_PORT="{ $RELAY_PORT }" "$SHAPE" shape "$BW" "$DELAY" "$PLR" 2>/dev/null; then
  echo "note: sudo refused env for the shaper; shaping ALL UDP+ICMP on $IFACE (relay TCP leg unshaped)"
  SCOPE="udp+icmp on $IFACE, relay TCP unshaped"
  shaper shape "$BW" "$DELAY" "$PLR" || die "could not apply shaping"
else
  SCOPE="udp+icmp+tcp:$RELAY_PORT to $PEER"
fi
shaper status | sed 's/^/  status: /' | head -12
PROBE_N=10; [ "$PLR" != "-" ] && [ "$PLR" != "0.0" ] && PROBE_N=40  # 10 pings cannot verify 15% loss: 0.72^10 = 4% chance of seeing none (extreme rerun, 2026-09-03)
probe=$(ping -c "$PROBE_N" -i 0.2 -q "$PEER" 2>/dev/null | tail -2)
probe_rtt=$(printf '%s' "$probe" | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
probe_loss=$(printf '%s' "$probe" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+' || echo 0)
echo "verified  icmp rtt ${probe_rtt:-?} ms  loss ${probe_loss}%"
if [ "$DELAY" != "-" ]; then
  ok=$(python3 -c "print(1 if ${probe_rtt:-0} >= ${DELAY} else 0)" 2>/dev/null || echo 0)
  [ "$ok" = 1 ] || die "shaping did not take effect (rtt ${probe_rtt:-?} < ${DELAY})"
fi
if [ "$PLR" != "-" ] && [ "$PLR" != "0.0" ]; then
  want=$(python3 -c "print(round(float('$PLR') * 100 * 0.4))" 2>/dev/null || echo 0)
  ok=$(python3 -c "print(1 if ${probe_loss:-0} >= ${want} else 0)" 2>/dev/null || echo 0)
  [ "$ok" = 1 ] || die "loss did not take effect (${probe_loss}% seen, wanted >= ${want}%)"
fi

# --- the phone first: its build is the long pole (2-7 min after a define
# change), the Mac app comes up in about a minute and must not idle for the
# whole build — on the first real-audio run the harness connection to the app
# dropped at 6:54 while it was still waiting for its key. ---
APPLOG="$LOGD/$PROFILE.app.log"; PHONELOG="$LOGD/$PROFILE.phone.log"
( cd "$APP" && flutter test integration_test/journey_peer_test.dart -d "$PHONE" \
    --dart-define=E2E_RELAY_URI="wss://$SELF:$RELAY_PORT/" --dart-define=JOURNEY_CALL_KEY="$KEY" \
    --dart-define=JOURNEY_HOLD_S="$HOLD" --dart-define=E2E_CONNECT_BUDGET_S="$BUDGET" \
    --dart-define=JOURNEY_GO_URL="http://$SELF:$HTTP_PORT/go_phone" --dart-define=E2E_MEDIA_MODE="$PHONE_MEDIA" \
    >"$PHONELOG" 2>&1 ) &
PHONE_PID=$!
for _ in $(seq 1 360); do grep -q 'JOURNEY_PEER key=' "$PHONELOG" 2>/dev/null && break; sleep 2.5; done
grep -q 'JOURNEY_PEER key=' "$PHONELOG" 2>/dev/null || die "the phone stack never came up (see $PHONELOG)"
echo "phone     stack up, waiting for go"

# --- the Mac app, on its own screen ---
# Keep the app awake and in front: run 3 (normal) showed a ~25 s stall of the
# app isolate at 30-56 s with the window never foregrounded, after which its
# signaling acks stopped and both sides fell into reconnect — App Nap.
defaults write com.voicecallkit.referenceApp NSAppSleepDisabled -bool YES 2>/dev/null || true
( cd "$APP" && flutter test integration_test/journey_driver_test.dart -d macos \
    --dart-define=JOURNEY_READY_FILE="$READY" --dart-define=JOURNEY_GO_FILE="$GO" \
    --dart-define=JOURNEY_HOLD_S="$HOLD" --dart-define=E2E_CONNECT_BUDGET_S="$BUDGET" \
    >"$APPLOG" 2>&1 ) &
APP_PID=$!
for _ in $(seq 1 240); do [ -f "$READY" ] && break; sleep 2.5; done
[ -f "$READY" ] || die "the Mac app never reported ready (see $APPLOG)"
echo "app       on screen"
osascript -e 'tell application id "com.voicecallkit.referenceApp" to activate' >/dev/null 2>&1 || true

# --- record the Mac screen for the whole run (unedited, fixed length) ---
REC_S=$((HOLD + BUDGET + 60))
screencapture -v -V "$REC_S" "$EVID/$PROFILE.mov" >/dev/null 2>&1 &
REC_PID=$!
echo "recording $EVID/$PROFILE.mov for ${REC_S}s"

printf '%s\n' "$KEY" >"$GO"
echo "go        key handed to the app"
# The app must be IN the room before the phone offers: the relay does not
# buffer an offer for a member that has not joined yet (normal run 1: offer at
# 0 s, app joined ~3 s later, neither side ever saw the other).
for _ in $(seq 1 120); do grep -q 'JOURNEY_APP joined' "$APPLOG" 2>/dev/null && break; sleep 1; done
grep -q 'JOURNEY_APP joined' "$APPLOG" 2>/dev/null || die "the app never joined (see $APPLOG)"
sleep 2
printf 'go\n' >"$RUN/go_phone"
echo "go        app in the room; phone released to offer"

wait "$APP_PID"; APP_RC=$?
wait "$PHONE_PID"; PHONE_RC=$?
# Give the recorder a moment to end on its own timer, then stop it: with the
# display asleep it never returns (latency run, 2026-09-03: an hour past its
# 405 s). SIGINT ends a -v recording cleanly and writes the file.
for _ in $(seq 1 30); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 1; done
kill -INT "$REC_PID" 2>/dev/null || true
for _ in $(seq 1 10); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 1; done
# screencapture ignored SIGINT on the latency run; escalate so the run never hangs on it.
kill -TERM "$REC_PID" 2>/dev/null || true; sleep 2; kill -KILL "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
shaper teardown >/dev/null 2>&1 || true
echo "runs      app rc=$APP_RC  phone rc=$PHONE_RC"

# --- rows ---
[ -f "$TSV" ] || printf 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n' >"$TSV"
summary=$(grep -o 'JOURNEY_APP summary.*' "$APPLOG" | tail -1)
field() { printf '%s' "$summary" | grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2; }
outcome=$(field outcome); connect_ms=$(field connect_ms); rtt_min=$(field rtt_min); rtt_max=$(field rtt_max)
loss_max=$(field loss_max); chip_live=$(field chip_live); chip_demo=$(field chip_demo); reconnects=$(field reconnects); end=$(field end)
peer_end=$(grep -o 'JOURNEY_PEER ended.*' "$PHONELOG" | tail -1 | grep -oE 'reason=[^ ]+' | cut -d= -f2)
peer_media=$(grep -o 'JOURNEY_PEER key=.*' "$PHONELOG" | head -1 | grep -oE 'media=[^ ]+' | cut -d= -f2)
shaped="run=$(date -u +%Y-%m-%dT%H:%M:%SZ) bw=$BW delay=$DELAY plr=$PLR icmp_rtt=${probe_rtt:-?} icmp_loss=${probe_loss}% scope=$SCOPE"

connect_s=$(python3 -c "print(round(${connect_ms:-0}/1000,1))" 2>/dev/null || echo "?")
case "$outcome" in Connected|Connected_—_survival_mode) cstat=PASS ;; *) cstat=FAIL ;; esac
printf 'call_connect\t%s\t-\t%s\t%s\t%s\t%s\n' "$PROFILE" "$BUDGET" "$connect_s" "$cstat" \
  "outcome=$outcome app_end=$end peer_end=${peer_end:-?} media=${peer_media:-?} $shaped app_relay=localhost(unshaped)" >>"$TSV"

# monitor bar: the bar must be LIVE (chip) and, under a delay profile, must read
# at least the one-way delay — a 40 ms reading under 1000 ms is a defect.
bstat=INFO; bnote="chip_live=$chip_live chip_demo=$chip_demo rtt=${rtt_min:-?}..${rtt_max:-?}ms loss_max=${loss_max:-?}% reconnects=${reconnects:-?}"
if [ "${chip_live:-0}" = 0 ] || [ "${chip_demo:-0}" != 0 ]; then bstat=FAIL; bnote="$bnote (bar not live)"; fi
if [ "$DELAY" != "-" ] && [ "$bstat" != FAIL ]; then
  ok=$(python3 -c "print(1 if ${rtt_max:-0} >= ${DELAY} else 0)" 2>/dev/null || echo 0)
  if [ "$ok" = 1 ]; then bstat=PASS; else bstat=FAIL; bnote="$bnote (bar rtt below shaped delay $DELAY ms)"; fi
fi
[ "$cstat" = PASS ] || { bstat=FAIL; bnote="$bnote (no connected call to measure)"; }
printf 'monitor_bar\t%s\t-\t%s\t%s\t%s\t%s\n' "$PROFILE" "${DELAY}" "${rtt_max:-?}" "$bstat" "$bnote $shaped" >>"$TSV"

# features the app's screens cannot send over the live call today
for f in chat_text photo video_note voice_note; do
  printf '%s\t%s\t-\t-\t-\tNOT_WIRED\t%s\n' "$f" "$PROFILE" \
    "chat tab is the loopback demo thread (ChatDemoController), not bound to the live call; see tools/dossier/LANE_TABLE.md" >>"$TSV"
done
echo "rows      appended to $TSV"
echo "evidence  $EVID/$PROFILE.mov  $APPLOG  $PHONELOG"
tail -n 6 "$TSV"
