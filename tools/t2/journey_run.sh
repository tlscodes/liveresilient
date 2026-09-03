#!/usr/bin/env bash
# journey_run.sh — one impairment profile of tools/BRIEF_matrix_app_journey.md:
# shape the phone's link, VERIFY the shaping took effect, run the reference app
# on the Mac (its own screens) against the PERSISTENT peer on the phone, record
# the Mac screen, restore, and append one TSV row per feature to
# tools/dossier/app_journey_results.tsv.
#
# Topology (decided 2026-09-03): Mac app = receiver, joins by key through its
# "Join with key" dialog against the relay at wss://localhost:4443 (unshaped
# loopback, declared in every row); phone = initiator (E2eCallStack inside
# integration_test/journey_peer_app.dart) via wss://<bridge addr>:4443/ over
# bridge100, which is what the shaper impairs. Media crosses bridge100 ONCE
# (direct host candidates), so the pipe loss is the profile loss as stated.
#
# The phone peer is INSTALLED ONCE (tools/t2/journey_peer_install.sh) and only
# LAUNCHED here (devicectl, never reinstalled), so its microphone prompt is
# answered once for the whole matrix. Its job and its evidence travel over the
# plain-HTTP hub (tools/t2/journey_hub.py) on the bridge address; the events
# land in the run directory as phone_events.jsonl, which the app-journey driver
# reads to judge every chat feature against the phone's verified sha256.
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
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
IFACE=${T2_IFACE:-bridge100}
PEER=${T2_PEER:-192.168.2.2}
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
RELAY_PORT=${JOURNEY_RELAY_PORT:-4443}
KEY=${JOURNEY_KEY:-journeyKeyAbCdEfGhIjKl}
HOLD=${JOURNEY_HOLD_S:-45}
BUDGET=${JOURNEY_CONNECT_BUDGET_S:-300}
PHOTO_BYTES=${JOURNEY_PHOTO_BYTES:-48000}
VOICE_S=${JOURNEY_VOICE_S:-6}
VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-64000}
SHAPE="$REPO/tools/t2/net_shape.sh"
HUB="$REPO/tools/t2/journey_hub.py"
EVID="$REPO/tools/dossier/evidence/journey"
LOGD="$REPO/tools/dossier/logs/journey"
TSV="$REPO/tools/dossier/app_journey_results.tsv"
APP="$REPO/apps/reference_app"
# The Mac app is sandboxed (macos/Runner/DebugProfile.entitlements), so the
# READY/GO files and the phone's event log must live inside its container —
# /tmp is "Operation not permitted" from inside the app (measured 2026-09-03).
CONTAINER_TMP="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp"
mkdir -p "$CONTAINER_TMP"
RUN=$(mktemp -d "$CONTAINER_TMP/journey.XXXXXX")
READY="$RUN/ready"; GO="$RUN/go"; EVENTS="$RUN/phone_events.jsonl"
RUN_ID=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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

# Per-feature budget, LINK-DERIVED and printed in the row: the largest item
# (the video note) at a quarter of the link's bit rate (the lane's share next
# to audio and control), doubled for ARQ overhead, plus six round trips, plus
# a 20 s floor for the UI and the receiver's verification; the loss profiles
# stretch it by 1/(1-plr)^2 (each direction loses independently). Clamped to
# 30..420 s so a dead link still fails inside the recording.
FEATURE_BUDGET=$(python3 - "$BW" "$DELAY" "$PLR" "$VIDEO_BYTES" <<'PY'
import sys
bw, delay, plr, video = sys.argv[1:5]
bps = 50_000_000 if bw == "-" else int(bw.replace("Kbit/s", "")) * 1000
rtt = 0.08 if delay == "-" else 2 * int(delay) / 1000
loss = 0.0 if plr == "-" else float(plr)
ideal = int(video) * 8 / (bps * 0.25)
budget = (2 * ideal + 6 * rtt + 20) / max(0.05, (1 - loss) ** 2)
print(int(min(420, max(30, budget))))
PY
)

[ -n "$SELF" ] || die "$IFACE has no address — Internet Sharing on, phone joined?"
[ -f "$HUB" ] || die "hub script missing: $HUB"
curl -sk --max-time 5 "https://127.0.0.1:$RELAY_PORT/" >/dev/null 2>&1 \
  || echo "note: relay on $RELAY_PORT did not answer an HTTP probe (WSS-only relays may still be fine)"

shaper() { sudo -n "$SHAPE" "$@"; }

cleanup() {
  shaper teardown >/dev/null 2>&1 || true
  pkill -P $$ 2>/dev/null || true
  # flutter test forks xcodebuild and dart VMs that outlive their parent and
  # hold the macOS build lock; kill the whole tree.
  pkill -f "integration_test/journey_driver" 2>/dev/null || true
  pkill -f "xcodebuild.*reference_app" 2>/dev/null || true
  pkill -f "macos_assemble.sh" 2>/dev/null || true
  pkill -f "journey_hub.py" 2>/dev/null || true
  echo "cleanup: shaping torn down, children stopped"
}
trap cleanup EXIT INT TERM
# Keep display and system awake for the whole run (the recorder and the app
# both stall when the display sleeps); caffeinate dies with this script.
caffeinate -dimsu -w $$ >/dev/null 2>&1 &

# --- the hub: the phone's job and evidence channel (plain HTTP on the bridge) ---
HTTP_PORT=${JOURNEY_HTTP_PORT:-8765}
python3 "$HUB" --bind "$SELF" --port "$HTTP_PORT" --dir "$RUN" >"$LOGD/$PROFILE.hub.log" 2>&1 &
for _ in $(seq 1 20); do curl -s --max-time 1 "http://$SELF:$HTTP_PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
curl -s --max-time 2 "http://$SELF:$HTTP_PORT/health" >/dev/null 2>&1 || die "the hub never came up on $SELF:$HTTP_PORT"

echo "profile   $PROFILE  (bw=$BW delay=$DELAY plr=$PLR)  feature budget ${FEATURE_BUDGET}s"
echo "iface     $IFACE   self $SELF   peer $PEER   relay wss://$SELF:$RELAY_PORT/"
echo "phone     $PHONE   key $KEY   hold ${HOLD}s   budget ${BUDGET}s   run $RUN_ID"

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
PROBE_N=10; [ "$PLR" != "-" ] && [ "$PLR" != "0.0" ] && PROBE_N=40  # 10 pings cannot verify 15% loss: 0.72^10 = 4% chance of seeing none
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

# --- the job, then the phone: launch the installed peer (never reinstall) ---
# The phone's hold is an upper bound: the app hangs up when its features are
# done, and the peer ends on that remote hangup. hold_s here only guarantees
# the call ends if the app side dies silently.
PHONE_HOLD=$((HOLD + BUDGET + 4 * FEATURE_BUDGET + 60))
printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"%s"}\n' "$RUN_ID" "$KEY" "$PHONE_HOLD" "$PROFILE" >"$RUN/job.json"
launched=""
for try in 1 2 3 4 5; do
  out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1)
  if printf '%s' "$out" | grep -q 'Launched application'; then launched="try $try"; break; fi
  if printf '%s' "$out" | grep -q 'no app record'; then
    die "the journey peer is not installed on $PHONE — run tools/t2/journey_peer_install.sh once (attended: answer the microphone prompt)"
  fi
  echo "phone     launch denied (try $try): $(printf '%s' "$out" | tail -1 | cut -c1-120)"
  sleep 2
done
[ -n "$launched" ] || die "the phone refused to launch $BUNDLE_ID five times (awake? trusts this Mac?)"
echo "phone     launched ($launched), waiting for its stack"
phone_event() { grep -o "\"event\":\"$1\"[^}]*" "$EVENTS" 2>/dev/null | tail -1; }
for _ in $(seq 1 120); do [ -n "$(phone_event stack_up)" ] && break; sleep 1; done
[ -n "$(phone_event stack_up)" ] || die "the phone stack never came up (see $EVENTS and $LOGD/$PROFILE.hub.log)"
peer_media=$(phone_event boot | grep -oE '"media":"[^"]+"' | cut -d'"' -f4)
[ -n "$peer_media" ] || peer_media=$(phone_event stack_up | grep -oE '"media":"[^"]+"' | cut -d'"' -f4)
echo "phone     stack up (media=${peer_media:-?}), waiting for go"

# --- the Mac app, on its own screen ---
# Keep the app awake and in front: an un-foregrounded app stalled ~25 s under
# App Nap (2026-09-03) and both sides fell into reconnect.
defaults write com.voicecallkit.referenceApp NSAppSleepDisabled -bool YES 2>/dev/null || true
APPLOG="$LOGD/$PROFILE.app.log"
( cd "$APP" && flutter test integration_test/journey_driver_test.dart -d macos \
    --dart-define=JOURNEY_READY_FILE="$READY" --dart-define=JOURNEY_GO_FILE="$GO" \
    --dart-define=JOURNEY_RUN_DIR="$RUN" \
    --dart-define=JOURNEY_HOLD_S="$HOLD" --dart-define=E2E_CONNECT_BUDGET_S="$BUDGET" \
    --dart-define=JOURNEY_FEATURE_BUDGET_S="$FEATURE_BUDGET" \
    --dart-define=JOURNEY_PHOTO_BYTES="$PHOTO_BYTES" --dart-define=JOURNEY_VOICE_S="$VOICE_S" \
    --dart-define=JOURNEY_VIDEO_BYTES="$VIDEO_BYTES" \
    >"$APPLOG" 2>&1 ) &
APP_PID=$!
for _ in $(seq 1 240); do [ -f "$READY" ] && break; sleep 2.5; done
[ -f "$READY" ] || die "the Mac app never reported ready (see $APPLOG)"
echo "app       on screen"
osascript -e 'tell application id "com.voicecallkit.referenceApp" to activate' >/dev/null 2>&1 || true

# --- record the Mac screen for the whole run (unedited; stopped when the run ends) ---
REC_S=$((HOLD + BUDGET + 4 * FEATURE_BUDGET + 120))
screencapture -v -V "$REC_S" "$EVID/$PROFILE.mov" >/dev/null 2>&1 &
REC_PID=$!
echo "recording $EVID/$PROFILE.mov (up to ${REC_S}s)"

printf '%s\n' "$KEY" >"$GO"
echo "go        key handed to the app"
# The app must be IN the room before the phone offers: the relay does not
# buffer an offer for a member that has not joined yet.
for _ in $(seq 1 120); do grep -q 'JOURNEY_APP joined' "$APPLOG" 2>/dev/null && break; sleep 1; done
grep -q 'JOURNEY_APP joined' "$APPLOG" 2>/dev/null || die "the app never joined (see $APPLOG)"
sleep 2
printf 'go\n' >"$RUN/go_phone"
echo "go        app in the room; phone released to offer"

wait "$APP_PID"; APP_RC=$?
# The phone ends on the app's hangup; give its `ended` event a moment to land.
for _ in $(seq 1 60); do [ -f "$RUN/job.done" ] && break; sleep 1; done
PHONE_RC=$([ -f "$RUN/job.done" ] && cat "$RUN/job.done" || echo "no-ended-event")
cp "$EVENTS" "$LOGD/$PROFILE.phone.jsonl" 2>/dev/null || true
# Stop the recorder: SIGINT ends a -v recording cleanly and writes the file;
# escalate so the run never hangs on it (the display-asleep case).
kill -INT "$REC_PID" 2>/dev/null || true
for _ in $(seq 1 15); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 1; done
kill -TERM "$REC_PID" 2>/dev/null || true; sleep 2; kill -KILL "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
shaper teardown >/dev/null 2>&1 || true
rec_bytes=$(stat -f %z "$EVID/$PROFILE.mov" 2>/dev/null || echo 0)
echo "runs      app rc=$APP_RC  phone=$PHONE_RC  recording ${rec_bytes} B"

# --- rows ---
[ -f "$TSV" ] || printf 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n' >"$TSV"
summary=$(grep -o 'JOURNEY_APP summary.*' "$APPLOG" | tail -1)
field() { printf '%s' "$summary" | grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2; }
outcome=$(field outcome); connect_ms=$(field connect_ms); rtt_min=$(field rtt_min); rtt_max=$(field rtt_max)
loss_max=$(field loss_max); chip_live=$(field chip_live); chip_demo=$(field chip_demo); reconnects=$(field reconnects); end=$(field end)
peer_end=$(phone_event ended | grep -oE '"reason":"[^"]+"' | cut -d'"' -f4)
[ -n "$peer_end" ] || peer_end=$(phone_event failed | grep -oE '"last_phase":"[^"]+"' | cut -d'"' -f4 | sed 's/^/failed:/')
shaped="run=$RUN_ID bw=$BW delay=$DELAY plr=$PLR icmp_rtt=${probe_rtt:-?} icmp_loss=${probe_loss}% scope=$SCOPE"
rec_note="recording=${rec_bytes}B"; [ "${rec_bytes:-0}" -gt 1000000 ] || rec_note="recording=MISSING(${rec_bytes}B)"

connect_s=$(python3 -c "print(round(${connect_ms:-0}/1000,1))" 2>/dev/null || echo "?")
case "$outcome" in Connected|Connected_—_survival_mode) cstat=PASS ;; *) cstat=FAIL ;; esac
printf 'call_connect\t%s\t-\t%s\t%s\t%s\t%s\n' "$PROFILE" "$BUDGET" "$connect_s" "$cstat" \
  "outcome=$outcome app_end=$end peer_end=${peer_end:-?} media=${peer_media:-?} $shaped app_relay=localhost(unshaped) $rec_note" >>"$TSV"

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

# the four chat features, judged by the driver against the phone's verified
# receipt (sha256 match); one line per feature in the app log.
for f in chat_text photo voice_note video_note; do
  line=$(grep -o "JOURNEY_APP feature=$f .*" "$APPLOG" | tail -1)
  if [ -z "$line" ]; then
    printf '%s\t%s\t-\t%s\t-\tFAIL\t%s\n' "$f" "$PROFILE" "$FEATURE_BUDGET" "no feature line in the app log (driver aborted before it) $shaped" >>"$TSV"
    continue
  fi
  ff() { printf '%s' "$line" | grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2-; }
  fstat=$(ff status); fbytes=$(ff bytes); fpeer=$(ff peer_ms); fsender=$(ff sender_ms); fsha=$(ff sha_match); fnote=$(ff note | tr '_' ' ')
  measured=$(python3 -c "print(round(${fpeer:-0}/1000,1))" 2>/dev/null || echo "-"); [ "$fpeer" = "-" ] && measured="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$PROFILE" "${fbytes:-?}" "$FEATURE_BUDGET" "$measured" "${fstat:-FAIL}" \
    "sender_ms=${fsender:-?} peer_ms=${fpeer:-?} sha_match=${fsha:-?} media=${peer_media:-?} $fnote $shaped" >>"$TSV"
done
echo "rows      appended to $TSV"
echo "evidence  $EVID/$PROFILE.mov  $APPLOG  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log"
tail -n 6 "$TSV"
