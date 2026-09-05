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
# USAGE  tools/t2/journey_run.sh <profile>
#          normal|latency|loss10|bandwidth|narrow|loss60|extreme|blackout|whitelist
#        JOURNEY_PHONE=<udid> JOURNEY_HOLD_S=45 JOURNEY_KEY=<22 chars> override defaults.
#        JOURNEY_DRY=1 tools/t2/journey_run.sh whitelist prints what that profile
#        would do — the shaper argument, the turnserver argv, the job JSON and the
#        two row templates — and exits before any sudo, hub, app or phone action.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROFILE=${1:?profile}
# The eighth profile has no call, no Mac app and no film: its own runner.
[ "$PROFILE" = blackout ] && exec "$REPO/tools/t2/journey_blackout.sh"
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
IFACE=${T2_IFACE:-bridge100}
PEER=${T2_PEER:-192.168.2.2}
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
RELAY_PORT=${JOURNEY_RELAY_PORT:-4443}
# The hub's port is declared here rather than beside the hub below, because the
# whitelist profile's filter argument names it before the hub is started.
HTTP_PORT=${JOURNEY_HTTP_PORT:-8765}
# A FRESH key per run. The relay keeps a room's replay ring for a grace after
# it empties and replays it to every fresh joiner (so a peer's hangup is
# never lost); with one fixed key across runs the NEXT run's app joined the
# previous run's room and answered a stale offer (latency, 2026-09-04
# 08:08Z: Negotiating at 1 s before the phone had GO, then Call failed).
KEY=${JOURNEY_KEY:-journey$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 15)}
HOLD=${JOURNEY_HOLD_S:-45}
BUDGET=${JOURNEY_CONNECT_BUDGET_S:-300}
PHOTO_BYTES=${JOURNEY_PHOTO_BYTES:-48000}
VOICE_S=${JOURNEY_VOICE_S:-6}
# CAPS on the REAL fixture files (tools/t2/journey_fixtures.sh: a spoken
# voice note and an H.264 clip made once per run), not sizes: the row's
# wire_B column is the length the app printed. Measured 2026-09-04:
# voice.wav 20,574 B for 5.1 s, video.mp4 73,780 B for 48 frames.
VOICE_BYTES=${JOURNEY_VOICE_BYTES:-24000}
# VIDEO_BYTES / PHOTO_PX are set per link once the profile is known (below).
SHAPE="$REPO/tools/t2/net_shape.sh"
HUB="$REPO/tools/t2/journey_hub.py"
FIXTURES="$REPO/tools/t2/journey_fixtures.sh"
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
RUN_EPOCH=$(date -u +%s)   # the same instant in seconds: the rows measure from it
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
    # whitelist shapes nothing: it loads a FILTER instead of a pipe (see the
    # whitelist block below), so all three impairment fields stay unset and the
    # bandwidth-derived fixture sizes fall to the unshaped lane.
    whitelist) echo "-        -     0.0" ;;
    *) die "unknown profile $1" ;;
  esac
}
read -r BW DELAY PLR <<<"$(profile_args "$PROFILE")"

# --- the whitelist profile: a filtered network, not an impaired one ---
# It stays inside this runner (unlike blackout, which execs its own script)
# because it must place a REAL call: one host and one port serve the ordinary
# HTTPS request and the rendezvous. What it replaces is the shaper call and the
# ICMP verification, both further down.
TURN_TCP_PORT=${JOURNEY_TURN_TCP_PORT:-3478}
WHITELIST_TCP=${JOURNEY_WHITELIST_TCP:-$RELAY_PORT+$TURN_TCP_PORT+$HTTP_PORT}
# The literal port 443, used three times for one reason: it needs no listener
# on this Mac, so both negative controls are real — the phone's TLS to a
# non-allowed host is reset, and its QUIC datagram to UDP 443 gets nothing.
# Single source for the shaper's rst=, the job's rst_port and its quic_port.
WHITELIST_PORT_443=443
WHITELIST_BLOCKED_HOST=${JOURNEY_WHITELIST_BLOCKED_HOST:-192.168.2.9}
# A TCP port outside the allow list, for the Mac-side door probe below.
WHITELIST_BLOCKED_TCP=${JOURNEY_WHITELIST_BLOCKED_TCP:-12345}
WHITELIST_QUIC_TIMEOUT_MS=${JOURNEY_WHITELIST_QUIC_TIMEOUT_MS:-3000}
WHITELIST_DOOR_INTERVAL_S=${JOURNEY_WHITELIST_DOOR_INTERVAL_S:-1}
# One budget for both rows: the window the door and the rendezvous must share,
# and the gap allowed between them.
WHITELIST_WINDOW_S=${JOURNEY_WHITELIST_WINDOW_S:-120}
TURN_BIN=${JOURNEY_TURN_BIN:-/usr/local/bin/turnserver}
TURN_CONF="$REPO/infra/turn/turnserver.conf"
TURN_PID=""
DOOR_PROBE="$REPO/tools/t2/tcp_door_probe.py"
WL_ROWS="$REPO/tools/t2/journey_whitelist_rows.py"
# tools/t2/relay_restart.sh writes exactly this path; the rendezvous instant is
# read off that log, so the two must not drift apart.
RELAY_LOG=${RELAY_LOG:-${TMPDIR:-/tmp}/signaling_relay_$RELAY_PORT.log}
# The dry print and the real run take the allowed address from one place. With
# bridge100 down there is no address to take, so the dry print says which of
# the two it used.
WL_SELF=${SELF:-192.168.2.1}
WHITELIST_ARG="peer=$PEER,allow=$WL_SELF,tcp=$WHITELIST_TCP,rst=$WHITELIST_PORT_443"
TURN_ARGV=("$TURN_BIN" -c "$TURN_CONF" --listening-port="$TURN_TCP_PORT"
           --listening-ip="$WL_SELF" --no-udp --no-tls --no-dtls --log-file=stdout)
# Stated in both rows, never hidden: the filter SHAPE is faithful, the allowed
# port NUMBERS are the ones a service can bind without root on this Mac.
WHITELIST_FIDELITY="ports $RELAY_PORT/$TURN_TCP_PORT stand in for 443/80 (ports <1024 need root; rdr-anchor absent)"

# The job the phone reads. For the whitelist profile it carries the map that
# profile's peer needs: where the ordinary HTTPS loop knocks and how often,
# which host and port must stay shut, and that ICE may use nothing but the TURN
# relay. No `blackout` key is ever added, which is why the phone's
# store-and-forward branch cannot be taken on this row.
job_json() {  # <hold_s>
  local hold=$1 wl=""
  if [ "$PROFILE" = whitelist ]; then
    wl=$(printf ',"whitelist":{"url":"https://%s:%s/","interval_s":%s,"blocked_host":"%s","rst_port":%s,"quic_port":%s,"quic_timeout_ms":%s,"relay_only":true}' \
      "$WL_SELF" "$RELAY_PORT" "$WHITELIST_DOOR_INTERVAL_S" "$WHITELIST_BLOCKED_HOST" \
      "$WHITELIST_PORT_443" "$WHITELIST_PORT_443" "$WHITELIST_QUIC_TIMEOUT_MS")
  fi
  printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"%s"%s}\n' \
    "$RUN_ID" "$KEY" "$hold" "$PROFILE" "$wl"
}

# --- JOURNEY_DRY=1: print what this profile would do, touch nothing ---
# Deliberately BEFORE the fixtures, the hub, the shaper, the app and the phone,
# so it runs on any machine, needs no sudo and asks for no password.
if [ "${JOURNEY_DRY:-0}" = 1 ]; then
  [ "$PROFILE" = whitelist ] || die "JOURNEY_DRY=1 is implemented for the whitelist profile only (got $PROFILE)"
  if [ -n "$SELF" ]; then echo "dry       allowed address $WL_SELF (read from $IFACE)"
  else echo "dry       $IFACE has no address; the lines below use the design's default $WL_SELF"; fi
  echo "dry       whitelist loads a filter; ICMP is dropped by it, so a TCP probe replaces the ping check"
  echo "shaper    sudo -n $SHAPE whitelist \"$WHITELIST_ARG\""
  echo "turn      ${TURN_ARGV[*]}"
  # The real hold_s follows the media fixtures; 30 s is this runner's own
  # documented feature-budget floor, so the line shows the shape of the JSON
  # with a stated placeholder, not a promise about the number.
  echo "job       $(job_json $((HOLD + BUDGET + 4 * 30 + 60)))   (hold_s uses the 30 s feature-budget floor)"
  printf 'row       '
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' whitelist_door whitelist '<door_bytes>' \
    "$WHITELIST_WINDOW_S" '<t_allowed_s>' 'PASS|FAIL' \
    "first ordinary HTTPS 200 t_allowed_source=door_open.at ... $WHITELIST_FIDELITY run=$RUN_ID"
  printf 'row       '
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' whitelist_rendezvous whitelist 0 \
    "$WHITELIST_WINDOW_S" '<t_rendezvous_s>' 'PASS|FAIL' \
    "gap_s=<t_rendezvous-t_allowed> t_rendezvous_source=relay_log.room_rendezvous_complete ... $WHITELIST_FIDELITY run=$RUN_ID"
  echo "dry       the rows are built by $WL_ROWS from $EVENTS and $RELAY_LOG"
  exit 0
fi

# Fixture sizes follow the link, the way a real app's encoder would: the
# video cap and the photo's long edge come from the profile's bandwidth
# (JOURNEY_VIDEO_BYTES / JOURNEY_PHOTO_PX override). Measured lanes
# 2026-09-04: 74 KB of video took 0.9 s unshaped, 43-52 s at 32 kbit/s,
# 116 s at 16 kbit/s; the feature budget below scales with the file.
case "$BW" in
  -)         VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-1600000}; PHOTO_PX=${JOURNEY_PHOTO_PX:-1280} ;;
  32Kbit/s)  VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-260000};  PHOTO_PX=${JOURNEY_PHOTO_PX:-800} ;;
  16Kbit/s)  if [ "$DELAY" != "-" ] || [ "$PLR" != "0.0" ]; then VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-110000}; else VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-110000}; fi
             PHOTO_PX=${JOURNEY_PHOTO_PX:-512} ;;
  *)         VIDEO_BYTES=${JOURNEY_VIDEO_BYTES:-260000};  PHOTO_PX=${JOURNEY_PHOTO_PX:-800} ;;
esac

# --- tools and fixtures, BEFORE any shaping or hub start ---
# The fixtures are made by `say` and ffmpeg; the media evidence after the
# call is decoded by sips, afinfo, ffprobe and ffmpeg and chained by shasum.
# A missing tool fails here, with nothing to tear down yet.
for tool in say ffmpeg ffprobe afinfo sips shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool $tool (needed for the fixtures and the media probes)"
done
[ -x "$FIXTURES" ] || die "fixture script missing or not executable: $FIXTURES"
# $RUN/fixtures/voice.wav and video.mp4 live in the app's container so the
# sandboxed driver can read and send them; the driver writes photo.jpg there.
fx_out=$(JOURNEY_VOICE_BYTES="$VOICE_BYTES" JOURNEY_VIDEO_BYTES="$VIDEO_BYTES" JOURNEY_PHOTO_PX="$PHOTO_PX" "$FIXTURES" "$RUN" "$RUN_ID" "$PROFILE") \
  || die "the media fixtures could not be made (caps voice ${VOICE_BYTES} B, video ${VIDEO_BYTES} B)"
printf '%s\n' "$fx_out" | sed 's/^fixture /fixtures  /'

# Per-feature budget, LINK-DERIVED and printed in the row: the largest item
# (the video note) at a quarter of the link's bit rate (the lane's share next
# to audio and control), doubled for ARQ overhead, plus six round trips, plus
# a 20 s floor for the UI and the receiver's verification; the loss profiles
# stretch it by 1/(1-plr)^2 (each direction loses independently). Clamped to
# 30..420 s so a dead link still fails inside the recording.
FEATURE_BUDGET=$(python3 - "$BW" "$DELAY" "$PLR" "$(stat -f %z "$RUN/fixtures/video.mp4")" <<'PY'
import sys
bw, delay, plr, video = sys.argv[1:5]
# Unshaped: the video lane measured ~640 kbit/s (74 KB in 0.9 s, 2026-09-04);
# 1 Mbit/s keeps the budget honest for a 1.3 MB clip instead of a 20 s guess.
bps = 1_000_000 if bw == "-" else int(bw.replace("Kbit/s", "")) * 1000
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
  # coturn belongs to this run alone: the whitelist profile starts it, and the
  # next profile's TURN port must not still be held when it does.
  [ -n "$TURN_PID" ] && kill "$TURN_PID" 2>/dev/null
  pkill -f "turnserver -c $TURN_CONF" 2>/dev/null || true
  touch "$RUN/rec_stop" 2>/dev/null || true
  echo "cleanup: shaping torn down, children stopped"
}
trap 'exit 130' INT; trap 'exit 143' TERM; trap cleanup EXIT  # signals exit; EXIT cleans up once
# Keep display and system awake for the whole run (the recorder and the app
# both stall when the display sleeps); caffeinate dies with this script.
caffeinate -dimsu -w $$ >/dev/null 2>&1 &

# --- the hub: the phone's job and evidence channel (plain HTTP on the bridge) ---
# HTTP_PORT is declared with the other ports at the top of this script.
# The previous run's hub may still be releasing the port (two of one
# night's twenty-one starts lost that race and the profile died before
# shaping): start, wait up to 20 s, and try three times, logging each.
hub_up=""
for hub_try in 1 2 3; do
  python3 "$HUB" --bind "$SELF" --port "$HTTP_PORT" --dir "$RUN" >>"$LOGD/$PROFILE.hub.log" 2>&1 &
  HUB_PID=$!
  for _ in $(seq 1 40); do
    curl -s --max-time 1 "http://$SELF:$HTTP_PORT/health" >/dev/null 2>&1 && { hub_up="try $hub_try"; break; }
    kill -0 "$HUB_PID" 2>/dev/null || break
    sleep 0.5
  done
  [ -n "$hub_up" ] && break
  echo "hub       not up (try $hub_try): $(tail -1 "$LOGD/$PROFILE.hub.log" 2>/dev/null | cut -c1-100)"
  kill "$HUB_PID" 2>/dev/null; sleep 3
done
[ -n "$hub_up" ] || die "the hub never came up on $SELF:$HTTP_PORT (see $LOGD/$PROFILE.hub.log)"

echo "profile   $PROFILE  (bw=$BW delay=$DELAY plr=$PLR)  feature budget ${FEATURE_BUDGET}s"
echo "iface     $IFACE   self $SELF   peer $PEER   relay wss://$SELF:$RELAY_PORT/"
echo "phone     $PHONE   key $KEY   hold ${HOLD}s   budget ${BUDGET}s   run $RUN_ID"

# --- shape or filter, and VERIFY (rows under unverified shaping are worse than no row) ---
shaper teardown >/dev/null 2>&1 || true
if [ "$PROFILE" = whitelist ]; then
  # coturn first: a missing binary must stop the run before pf is touched.
  [ -x "$TURN_BIN" ] || die "the whitelist profile needs coturn — $TURN_BIN not found (install it with: brew install coturn)"
  [ -f "$TURN_CONF" ] || die "the TURN config is missing: $TURN_CONF"
  TURNLOG="$LOGD/$PROFILE.turn.log"
  # The config file stays untouched; the listening address and port are
  # overridden on the command line, and the UDP and TLS listeners are refused,
  # so the phone can reach TURN only over the one allowed TCP port.
  "${TURN_ARGV[@]}" >"$TURNLOG" 2>&1 &
  TURN_PID=$!
  turn_up=""
  for _ in $(seq 1 20); do
    python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 1).close()' \
      "$WL_SELF" "$TURN_TCP_PORT" 2>/dev/null && { turn_up=yes; break; }
    kill -0 "$TURN_PID" 2>/dev/null || break
    sleep 0.5
  done
  [ -n "$turn_up" ] || die "coturn did not accept TCP on $WL_SELF:$TURN_TCP_PORT (see $TURNLOG)"
  echo "turn      ${TURN_ARGV[*]}"
  echo "turn      accepting tcp on $WL_SELF:$TURN_TCP_PORT (pid $TURN_PID, log $TURNLOG)"
  sudo -n "$SHAPE" whitelist "$WHITELIST_ARG" || die "could not load the whitelist filter ($WHITELIST_ARG)"
  SCOPE="whitelist on $IFACE: tcp {$WHITELIST_TCP} + udp 53 to $WL_SELF, tcp $WHITELIST_PORT_443 elsewhere reset, all else from $PEER dropped"
  shaper status | sed 's/^/  status: /' | head -12
  # ICMP is dropped by this filter BY DESIGN, so the ping check the other
  # profiles use would kill the run here. The TCP probe asserts BOTH halves of
  # the claim — a definite answer on an allowed port, silence on a blocked one
  # — because a check that only proves the allowed port works cannot tell a
  # whitelist from an open network.
  probe_rtt=""; probe_loss="-"
  door_probe=$(python3 "$DOOR_PROBE" "$PEER" "$RELAY_PORT" "$WHITELIST_BLOCKED_TCP" 3)
  door_rc=$?
  echo "verified  tcp $door_probe  (allowed $RELAY_PORT, blocked $WHITELIST_BLOCKED_TCP, host $PEER)"
  [ "$door_rc" = 0 ] || die "the filter is not what the rows would claim: $door_probe — the allowed port must answer (refused|open) and the blocked port must time out"
  SCOPE="$SCOPE; tcp_probe($door_probe)"
elif ! sudo -n T2_PEER="$PEER" T2_SHAPE_TCP_PORT="{ $RELAY_PORT }" "$SHAPE" shape "$BW" "$DELAY" "$PLR" 2>/dev/null; then
  echo "note: sudo refused env for the shaper; shaping ALL UDP+ICMP on $IFACE (relay TCP leg unshaped)"
  SCOPE="udp+icmp on $IFACE, relay TCP unshaped"
  shaper shape "$BW" "$DELAY" "$PLR" || die "could not apply shaping"
else
  SCOPE="udp+icmp+tcp:$RELAY_PORT to $PEER"
fi
if [ "$PROFILE" != whitelist ]; then
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
fi

# --- the Mac app, on its own screen (built and ready BEFORE the phone) ---
# Keep the app awake and in front: an un-foregrounded app stalled ~25 s under
# App Nap (2026-09-03) and both sides fell into reconnect.
defaults write com.voicecallkit.referenceApp NSAppSleepDisabled -bool YES 2>/dev/null || true
APPLOG="$LOGD/$PROFILE.app.log"
( cd "$APP" && flutter test integration_test/journey_driver_test.dart -d macos \
    --dart-define=JOURNEY_READY_FILE="$READY" --dart-define=JOURNEY_GO_FILE="$GO" \
    --dart-define=JOURNEY_RUN_DIR="$RUN" \
    --dart-define=JOURNEY_HOLD_S="$HOLD" --dart-define=E2E_CONNECT_BUDGET_S="$BUDGET" \
    --dart-define=JOURNEY_FEATURE_BUDGET_S="$FEATURE_BUDGET" \
    --dart-define=JOURNEY_PROFILE="$PROFILE" --dart-define=JOURNEY_RUN_ID="$RUN_ID" \
    --dart-define=JOURNEY_PHOTO_FILE="$RUN/fixtures/photo_src.jpg" \
    --dart-define=JOURNEY_PHOTO_BYTES="$PHOTO_BYTES" --dart-define=JOURNEY_VOICE_S="$VOICE_S" \
    --dart-define=JOURNEY_VIDEO_BYTES="$VIDEO_BYTES" \
    --dart-define=JOURNEY_VOICE_FILE="$RUN/fixtures/voice.wav" \
    --dart-define=JOURNEY_VIDEO_FILE="$RUN/fixtures/video.mp4" \
    >"$APPLOG" 2>&1 ) &
APP_PID=$!
# Up to 20 min: a cold macOS build took >10 min under the matrix on
# 2026-09-04 (bandwidth: BUILD INTERRUPTED by the old 10-min wait). A dead
# flutter process ends the wait at once.
for _ in $(seq 1 480); do [ -f "$READY" ] && break; kill -0 "$APP_PID" 2>/dev/null || break; sleep 2.5; done
[ -f "$READY" ] || die "the Mac app never reported ready (flutter alive: $(kill -0 "$APP_PID" 2>/dev/null && echo yes || echo no); see $APPLOG)"
echo "app       on screen"
osascript -e 'tell application id "com.voicecallkit.referenceApp" to activate' >/dev/null 2>&1 || true

# --- the phone: launch the installed peer (never reinstall), then the job ---
# Order matters twice. The Mac app is already on screen (above), so the
# phone's 10-minute GO clock, started at stack_up, never contains a Mac
# build. And the job is posted only after the FRESH instance reported
# `boot` to THIS run's hub: the previous profile's instance keeps polling
# the hub port until the launch terminates it, and posting first let it
# take the job, offer, and die mid-negotiation (loss10, 2026-09-04 13:04Z:
# two stack_up events, the app negotiating with a terminated peer).
# The phone's hold is an upper bound: the app hangs up when its features are
# done, and the peer ends on that remote hangup. hold_s here only guarantees
# the call ends if the app side dies silently.
PHONE_HOLD=$((HOLD + BUDGET + 4 * FEATURE_BUDGET + 60))
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
echo "phone     launched ($launched), waiting for it to boot"
phone_event() { grep -o "\"event\":\"$1\"[^}]*" "$EVENTS" 2>/dev/null | tail -1; }
# A `boot` line in this run's fresh events file can only come from a process
# started after this hub came up, and proves the new instance reaches it.
for _ in $(seq 1 60); do [ -n "$(phone_event boot)" ] && break; sleep 1; done
[ -n "$(phone_event boot)" ] || die "the fresh peer never reported boot to this hub (see $EVENTS and $LOGD/$PROFILE.hub.log)"
job_json "$PHONE_HOLD" >"$RUN/job.json"
echo "phone     booted, job posted, waiting for its stack"
for _ in $(seq 1 120); do [ -n "$(phone_event stack_up)" ] && break; sleep 1; done
[ -n "$(phone_event stack_up)" ] || die "the phone stack never came up (see $EVENTS and $LOGD/$PROFILE.hub.log)"
peer_media=$(phone_event boot | grep -oE '"media":"[^"]+"' | cut -d'"' -f4)
[ -n "$peer_media" ] || peer_media=$(phone_event stack_up | grep -oE '"media":"[^"]+"' | cut -d'"' -f4)
# A peer built after 2026-09-04 says "blob":true in its boot event: it will
# return every received media item's bytes through the hub (/blob). An older
# peer cannot, and every media row of this run then fails as no-blob.
peer_blob=no; phone_event boot | grep -q '"blob":true' && peer_blob=yes
echo "phone     stack up (media=${peer_media:-?} blob=$peer_blob), waiting for go"

# --- record the Mac screen for the whole run, unedited, in fixed segments ---
# `screencapture -v` writes its file ONLY when its own -V timer ends: SIGINT
# is ignored (measured 2026-09-04: a 60 s recording interrupted at 6 s ran
# the full 60 s and then wrote 55 MB; a longer one killed early wrote
# nothing, and every row of the night carried the size of the PREVIOUS
# day's file). So the run is filmed as back-to-back 120 s segments that
# each end on their own timer; the last one is awaited, never killed.
# Earlier recordings of the profile are kept aside, not overwritten.
REC_SEG_S=${JOURNEY_REC_SEGMENT_S:-120}
if ls "$EVID/$PROFILE"*.mov >/dev/null 2>&1; then
  mkdir -p "$EVID/superseded"
  for old in "$EVID/$PROFILE"*.mov; do
    mv "$old" "$EVID/superseded/$(basename "${old%.mov}").$(date -r "$old" -u +%Y-%m-%dT%H%M%SZ).mov"
  done
fi
REC_STOP="$RUN/rec_stop"
( seg=0
  while [ ! -f "$REC_STOP" ]; do
    seg=$((seg + 1))
    screencapture -v -V "$REC_SEG_S" "$EVID/$PROFILE-$(printf '%02d' "$seg").mov" >/dev/null 2>&1
  done ) &
REC_PID=$!
echo "recording $EVID/$PROFILE-NN.mov in ${REC_SEG_S}s segments"

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
# The peer posts each received item's bytes (/blob) before `ended`, but the
# hub may still be writing when job.done appears: wait up to 5 s for one
# blob event per media feature the app reported PASS.
want_blobs=$(grep -cE 'JOURNEY_APP feature=(photo|voice_note|video_note) status=PASS' "$APPLOG" 2>/dev/null || true)
if [ "$peer_blob" = yes ] && [ "${want_blobs:-0}" -gt 0 ]; then
  for _ in $(seq 1 10); do
    have_blobs=$(grep -c '"event":"blob"' "$EVENTS" 2>/dev/null || true)
    [ "${have_blobs:-0}" -ge "$want_blobs" ] && break
    sleep 0.5
  done
fi
cp "$EVENTS" "$LOGD/$PROFILE.phone.jsonl" 2>/dev/null || true
# Stop filming: no new segment starts, the current one ends on its own
# timer (at most REC_SEG_S more seconds) and writes itself.
touch "$REC_STOP"
for _ in $(seq 1 $((REC_SEG_S + 30))); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 1; done
wait "$REC_PID" 2>/dev/null || true
shaper teardown >/dev/null 2>&1 || true
rec_parts=$(ls "$EVID/$PROFILE"-[0-9][0-9].mov 2>/dev/null | wc -l | tr -d ' ')
rec_bytes=$(cat "$EVID/$PROFILE"-[0-9][0-9].mov 2>/dev/null | wc -c | tr -d ' ')
echo "runs      app rc=$APP_RC  phone=$PHONE_RC  recording ${rec_parts} segment(s), ${rec_bytes} B"

# --- media evidence: the bytes the phone RECEIVED, back on the Mac ---
# The peer returns each received item through the hub (/blob). A media row
# can PASS only when the chain holds — fixture file == returned blob == the
# sha256 the app printed — AND Mac tools decode the returned file: sips for
# the photo, afinfo plus ffmpeg volumedetect for the voice note, ffprobe plus
# a frame grabbed at 2 s for the video note. The decoded files sit next to
# the recordings (collect_evidence.sh puts every non-.mov file under
# evidence/ into the manifest); earlier files of the profile are kept aside.
MEDIA="$EVID/media"; mkdir -p "$MEDIA"
if ls "$MEDIA/$PROFILE"-* >/dev/null 2>&1; then
  mkdir -p "$MEDIA/superseded"
  for old in "$MEDIA/$PROFILE"-*; do
    [ -f "$old" ] || continue
    mv "$old" "$MEDIA/superseded/$(basename "${old%.*}").$(date -r "$old" -u +%Y-%m-%dT%H%M%SZ).${old##*.}"
  done
fi
probe_media() {  # <photo|voice|video> <file> <fixture> → ok(<detail>) or the check that failed
  # The fixture is the reference: the returned file must decode to the SAME
  # picture size / clip length the runner made for this link (sizes follow
  # the profile, so a fixed floor would reject the thin-link clips).
  local kind=$1 f=$2 fx=$3
  case "$kind" in
    photo)
      local w h
      local fw fh
      w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')
      h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/{print $2}')
      fw=$(sips -g pixelWidth "$fx" 2>/dev/null | awk '/pixelWidth/{print $2}')
      fh=$(sips -g pixelHeight "$fx" 2>/dev/null | awk '/pixelHeight/{print $2}')
      if [ "${w:-0}" -ge 160 ] 2>/dev/null && [ "${h:-0}" -ge 90 ] 2>/dev/null && [ "$w" = "$fw" ] && [ "$h" = "$fh" ]; then echo "ok(${w}x${h})"
      else echo "photo-probe(${w:-?}x${h:-?},fixture=${fw:-?}x${fh:-?})"; fi ;;
    voice)
      local dur peak
      dur=$(afinfo "$f" 2>/dev/null | sed -nE 's/.*estimated duration: ([0-9.]+) sec.*/\1/p' | head -1)
      peak=$(ffmpeg -hide_banner -nostats -i "$f" -af volumedetect -f null - 2>&1 | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1/p' | head -1)
      python3 -c "import sys; d=float(sys.argv[1] or 0); m=float(sys.argv[2] or -99); print(('ok' if 3.0 <= d <= 8.0 and m > -20 else 'voice-probe') + '(%.1fs,max%.1fdB)' % (d, m))" "$dur" "$peak" 2>/dev/null \
        || echo "voice-probe(dur=${dur:-?},max=${peak:-?})" ;;
    video)
      local info codec w h fr frame fbytes fxinfo fxcodec fxw fxh fxfr fxdur
      info=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames -of csv=p=0 "$f" 2>/dev/null | head -1)
      IFS=, read -r codec w h fr <<<"$info"
      local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | head -1 | cut -c1-5)
      fxinfo=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames -of csv=p=0 "$fx" 2>/dev/null | head -1)
      IFS=, read -r fxcodec fxw fxh fxfr <<<"$fxinfo"
      fxdur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$fx" 2>/dev/null | head -1 | cut -c1-5)
      frame="$MEDIA/$PROFILE-video-2s.jpg"
      ffmpeg -v error -y -ss 2 -i "$f" -frames:v 1 "$frame" >/dev/null 2>&1
      fbytes=$(stat -f %z "$frame" 2>/dev/null || echo 0)
      if [ "${codec:-}" = h264 ] && [ "$w" = "$fxw" ] && [ "$h" = "$fxh" ] && [ "${fr:-0}" -ge 24 ] 2>/dev/null && [ "$dur" = "$fxdur" ] && [ "$fbytes" -gt 2000 ]; then
        echo "ok(h264,${w}x${h},${fr}f,${dur:-?}s)"
      else echo "video-probe(${codec:-?},${w:-?}x${h:-?},${fr:-?}f,${dur:-?}s,frame2s=${fbytes}B,fixture=${fxcodec:-?},${fxw:-?}x${fxh:-?},${fxdur:-?}s)"; fi ;;
    *) echo "probe(unknown_kind_$kind)" ;;
  esac
}
for mf in photo voice_note video_note; do
  case "$mf" in
    photo)      mk=photo; fx="$RUN/fixtures/photo.jpg"; ext=jpg ;;
    voice_note) mk=voice; fx="$RUN/fixtures/voice.wav"; ext=wav ;;
    *)          mk=video; fx="$RUN/fixtures/video.mp4"; ext=mp4 ;;
  esac
  mline=$(grep -o "JOURNEY_APP feature=$mf .*" "$APPLOG" 2>/dev/null | tail -1)
  msha=$(printf '%s' "$mline" | grep -oE 'sha256=[0-9a-f]{64}' | head -1 | cut -d= -f2-)
  ev=""; [ -n "$msha" ] && ev=$(grep -o '"event":"blob"[^}]*' "$EVENTS" 2>/dev/null | grep "\"sha256\":\"$msha\"" | tail -1)
  ekind=$(printf '%s' "$ev" | grep -oE '"kind":"[^"]+"' | cut -d'"' -f4)
  eid=$(printf '%s' "$ev" | grep -oE '"id":"[^"]+"' | cut -d'"' -f4)
  blob="$RUN/blobs/$ekind-$eid.bin"
  if [ -z "$mline" ]; then result="no-feature-line"
  elif [ "$peer_blob" != yes ]; then result="no-blob(peer_predates_blob_posting)"
  elif [ -z "$msha" ]; then result="no-sha(app_line_lacks_sha256)"
  elif [ -z "$ev" ]; then result="no-blob(no_blob_event_for_sha)"
  elif [ "$ekind" != "$mk" ]; then result="no-blob(event_kind_${ekind}_not_${mk})"
  elif [ ! -s "$blob" ]; then result="no-blob(file_missing)"
  else
    bsha=$(shasum -a 256 "$blob" | awk '{print $1}')
    fsha=""; [ -s "$fx" ] && fsha=$(shasum -a 256 "$fx" | awk '{print $1}')
    if [ "$bsha" != "$msha" ]; then result="sha-chain(blob!=app)"
    elif [ -z "$fsha" ]; then result="sha-chain(fixture_missing)"
    elif [ "$fsha" != "$bsha" ]; then result="sha-chain(fixture!=blob)"
    else
      cp "$blob" "$MEDIA/$PROFILE-$mk.$ext"
      result=$(probe_media "$mk" "$MEDIA/$PROFILE-$mk.$ext" "$fx")
    fi
  fi
  printf -v "decoded_$mf" '%s' "$result"
  echo "media     $mf decoded=$result"
done

# --- rows ---
[ -f "$TSV" ] || printf 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n' >"$TSV"
summary=$(grep -o 'JOURNEY_APP summary.*' "$APPLOG" | tail -1)
field() { printf '%s' "$summary" | grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2; }
outcome=$(field outcome); connect_ms=$(field connect_ms); rtt_min=$(field rtt_min); rtt_max=$(field rtt_max)
loss_max=$(field loss_max); chip_live=$(field chip_live); chip_demo=$(field chip_demo); reconnects=$(field reconnects); end=$(field end)
peer_end=$(phone_event ended | grep -oE '"reason":"[^"]+"' | cut -d'"' -f4)
[ -n "$peer_end" ] || peer_end=$(phone_event failed | grep -oE '"last_phase":"[^"]+"' | cut -d'"' -f4 | sed 's/^/failed:/')
shaped="run=$RUN_ID bw=$BW delay=$DELAY plr=$PLR icmp_rtt=${probe_rtt:-?} icmp_loss=${probe_loss}% scope=$SCOPE"
rec_note="recording=${rec_parts}x${REC_SEG_S}s,${rec_bytes}B"; [ "${rec_bytes:-0}" -gt 1000000 ] || rec_note="recording=MISSING(${rec_parts}parts,${rec_bytes}B)"

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
  # Media rows: the driver's PASS is necessary, the runner's decode (above)
  # is the last word — a broken sha chain, a missing blob or a file the Mac
  # cannot decode turns the row into FAIL, with decoded= naming the check.
  case "$f" in photo|voice_note|video_note)
    dvar="decoded_$f"; decoded=${!dvar:-unchecked}
    fnote="$fnote decoded=$decoded"
    case "$decoded" in ok\(*\)) ;; *) fstat=FAIL ;; esac ;;
  esac
  measured=$(python3 -c "print(round(${fpeer:-0}/1000,1))" 2>/dev/null || echo "-"); [ "$fpeer" = "-" ] && measured="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$PROFILE" "${fbytes:-?}" "$FEATURE_BUDGET" "$measured" "${fstat:-FAIL}" \
    "sender_ms=${fsender:-?} peer_ms=${fpeer:-?} sha_match=${fsha:-?} media=${peer_media:-?} $fnote $shaped" >>"$TSV"
done
# The whitelist profile's own two rows: the moment ordinary allowed traffic
# succeeded, the moment the rendezvous completed, and the gap between them.
# The judging lives in journey_whitelist_rows.py, which has a unit test — the
# PASS rule is the part no rig run should be spent discovering is wrong.
if [ "$PROFILE" = whitelist ]; then
  python3 "$WL_ROWS" --events "$EVENTS" --relay-log "$RELAY_LOG" --key "$KEY" \
    --run-epoch "$RUN_EPOCH" --window-s "$WHITELIST_WINDOW_S" --summary "$summary" \
    --shaped "$shaped" --fidelity "$WHITELIST_FIDELITY" >>"$TSV" \
    || echo "note: the whitelist rows could not be built (see $EVENTS and $RELAY_LOG)"
fi
echo "rows      appended to $TSV"
echo "evidence  $EVID/$PROFILE-NN.mov  $EVID/media/$PROFILE-*  $APPLOG  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log"
tail -n 6 "$TSV"
