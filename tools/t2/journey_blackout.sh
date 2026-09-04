#!/usr/bin/env bash
# journey_blackout.sh — the eighth rig profile: NO path at all, for hours.
#
# The phone holds a signed 1 KB bundle in its durable store-and-forward queue
# while the link to the Mac is completely cut (every packet on the bridge
# dropped on every path the app has: UDP, ICMP, the hub and relay TCP ports). After
# a RANDOM interval the runner opens the link for a short window and closes it
# again; the phone's cheap probe (one GET every probe_s) finds the window, the
# queue flushes, the Mac verifies the Ed25519 signature made hours earlier.
# The gate is delivery with the signature intact; the measured number is the
# latency in HOURS, reported in hours in the table.
#
# There is no call, no Mac app and no screen film in this profile: the
# evidence is the phone's event stream (armed → received → ended), the bundle
# bytes the hub kept, and the signature verdict.
#
# USAGE  tools/t2/journey_blackout.sh            (journey_run.sh blackout execs this)
#   JOURNEY_BLACKOUT_MIN_M=30 JOURNEY_BLACKOUT_MAX_M=90   random blocked interval, minutes
#   JOURNEY_BLACKOUT_WINDOW_S=90                          how long the link opens
#   JOURNEY_BLACKOUT_WINDOWS=3                            windows before giving up
#   JOURNEY_BLACKOUT_BYTES=1024  JOURNEY_BLACKOUT_PROBE_S=20  JOURNEY_BLACKOUT_LIFETIME_S=21600
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROFILE=blackout
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
IFACE=${T2_IFACE:-bridge100}
PEER=${T2_PEER:-192.168.2.2}
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
HTTP_PORT=${JOURNEY_HTTP_PORT:-8765}
RELAY_PORT=${JOURNEY_RELAY_PORT:-4443}
MIN_M=${JOURNEY_BLACKOUT_MIN_M:-30}
MAX_M=${JOURNEY_BLACKOUT_MAX_M:-90}
WINDOW_S=${JOURNEY_BLACKOUT_WINDOW_S:-90}
WINDOWS=${JOURNEY_BLACKOUT_WINDOWS:-3}
BYTES=${JOURNEY_BLACKOUT_BYTES:-1024}
PROBE_S=${JOURNEY_BLACKOUT_PROBE_S:-20}
LIFETIME_S=${JOURNEY_BLACKOUT_LIFETIME_S:-21600}
KEY=${JOURNEY_KEY:-blackout$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)}
SHAPE="$REPO/tools/t2/net_shape.sh"
HUB="$REPO/tools/t2/journey_hub.py"
LOGD="$REPO/tools/dossier/logs/journey"
TSV="$REPO/tools/dossier/app_journey_results.tsv"
EVID="$REPO/tools/dossier/evidence/journey"
mkdir -p "$LOGD" "$EVID/media"
CONTAINER_TMP="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp"
mkdir -p "$CONTAINER_TMP"
RUN=$(mktemp -d "$CONTAINER_TMP/journey.XXXXXX")
EVENTS="$RUN/phone_events.jsonl"
RUN_ID=$(date -u +%Y-%m-%dT%H:%M:%SZ)

die() { echo "ERROR: $*" >&2; exit 1; }
shaper() { sudo -n "$SHAPE" "$@"; }
cleanup() {
  shaper teardown >/dev/null 2>&1 || true
  pkill -P $$ 2>/dev/null || true
  pkill -f "journey_hub.py" 2>/dev/null || true
  echo "cleanup: link restored, hub stopped"
}
trap cleanup EXIT INT TERM
caffeinate -dimsu -w $$ >/dev/null 2>&1 &
[ -n "$SELF" ] || die "$IFACE has no address — Internet Sharing on, phone joined?"
sudo -n "$SHAPE" teardown >/dev/null 2>&1 || die "net_shape.sh needs the passwordless sudoers rule"
python3 -c "from cryptography.hazmat.primitives.asymmetric import ed25519" 2>/dev/null \
  || die "python3 needs the 'cryptography' package to verify the bundle's signature"

# --- the hub ---
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
  kill "$HUB_PID" 2>/dev/null; sleep 3
done
[ -n "$hub_up" ] || die "the hub never came up on $SELF:$HTTP_PORT"
echo "profile   blackout  (no path; random blocked ${MIN_M}-${MAX_M} min, window ${WINDOW_S}s x ${WINDOWS}, bundle ${BYTES} B, probe ${PROBE_S}s)"
echo "phone     $PHONE   run $RUN_ID"

# --- the phone: fresh instance, boot (with its public key), then the job ---
launched=""
for try in 1 2 3 4 5; do
  out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1)
  if printf '%s' "$out" | grep -q 'Launched application'; then launched="try $try"; break; fi
  if printf '%s' "$out" | grep -q 'no app record'; then die "the journey peer is not installed on $PHONE"; fi
  sleep 2
done
[ -n "$launched" ] || die "the phone refused to launch $BUNDLE_ID five times"
phone_event() { grep -o "\"event\":\"$1\"[^}]*" "$EVENTS" 2>/dev/null | tail -1; }
for _ in $(seq 1 60); do [ -n "$(phone_event boot)" ] && break; sleep 1; done
[ -n "$(phone_event boot)" ] || die "the fresh peer never reported boot"
phone_event boot | grep -q '"blackout":true' || die "this peer install predates the blackout job (rebuild with journey_peer_install.sh)"
[ -s "$RUN/peer_pubkey.b64" ] || die "the boot event carried no public key"
printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"bytes":%d,"probe_s":%d,"lifetime_s":%d}}\n' \
  "$RUN_ID" "$KEY" "$LIFETIME_S" "$BYTES" "$PROBE_S" "$LIFETIME_S" >"$RUN/job.json"
for _ in $(seq 1 60); do [ -n "$(phone_event blackout_armed)" ] && break; sleep 1; done
armed=$(phone_event blackout_armed)
[ -n "$armed" ] || die "the phone never armed the bundle (see $EVENTS)"
armed_sha=$(printf '%s' "$armed" | grep -oE '"sha256":"[0-9a-f]+"' | cut -d'"' -f4)
created_ms=$(printf '%s' "$armed" | grep -oE '"created_ms":[0-9]+' | cut -d: -f2)
echo "phone     bundle armed sha256=${armed_sha:0:16}… created_ms=$created_ms — cutting the link"

# --- the blackout: total, then random windows ---
blocked_total=0
windows_used=0
received=""
for w in $(seq 1 "$WINDOWS"); do
  # Every path the app has — UDP and ICMP to the phone plus TCP to the hub
  # and the relay ports — dropped outright (plr 1.0). The scope travels as
  # the shaper's fourth argument because the sudoers rule strips environment
  # variables; the phone's unrelated system traffic is not cut, the app's is.
  sudo -n "$SHAPE" shape - - 1.0 "peer=$PEER,tcp=$HTTP_PORT+$RELAY_PORT" >/dev/null 2>&1 \
    || die "could not cut the link"
  blocked_s=$(python3 -c "import random,sys; lo,hi=int(sys.argv[1]),int(sys.argv[2]); print(random.randint(lo*60, hi*60))" "$MIN_M" "$MAX_M")
  echo "link      CUT (window $w): blocked for ${blocked_s}s ($(date -u +%H:%M:%SZ))"
  sleep "$blocked_s"
  blocked_total=$((blocked_total + blocked_s))
  shaper teardown >/dev/null 2>&1 || die "could not open the link"
  windows_used=$w
  echo "link      OPEN for ${WINDOW_S}s ($(date -u +%H:%M:%SZ))"
  for _ in $(seq 1 "$WINDOW_S"); do received=$(phone_event bundle_received); [ -n "$received" ] && break; sleep 1; done
  [ -n "$received" ] && break
  echo "link      window $w closed with nothing received"
done
if [ -n "$received" ]; then
  # Let the peer's `ended` event through before the link closes for good.
  for _ in $(seq 1 30); do [ -f "$RUN/job.done" ] && break; sleep 1; done
fi
shaper teardown >/dev/null 2>&1 || true
cp "$EVENTS" "$LOGD/$PROFILE.phone.jsonl" 2>/dev/null || true

# --- the row: latency in HOURS ---
[ -f "$TSV" ] || printf 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n' >"$TSV"
budget_h=$(python3 -c "print(round($LIFETIME_S/3600, 2))")
if [ -n "$received" ]; then
  r_sha=$(printf '%s' "$received" | grep -oE '"sha256":"[0-9a-f]+"' | cut -d'"' -f4)
  sig_ok=$(printf '%s' "$received" | grep -oE '"sig_ok":(true|false)' | cut -d: -f2)
  pk_ok=$(printf '%s' "$received" | grep -oE '"pubkey_match":(true|false)' | cut -d: -f2)
  received_ms=$(printf '%s' "$received" | grep -oE '"received_ms":[0-9]+' | cut -d: -f2)
  latency_h=$(python3 -c "print(round(($received_ms - $created_ms)/3600000, 3))")
  status=FAIL
  [ "$sig_ok" = true ] && [ "$pk_ok" = true ] && [ "$r_sha" = "$armed_sha" ] && status=PASS
  cp "$RUN/blobs/bundle-${armed_sha:0:16}.bin" "$EVID/media/blackout-bundle.bin" 2>/dev/null || true
  note="signed 1 KB bundle held in the phone's durable store-and-forward queue with no path, delivered on window $windows_used after ${blocked_total}s cut; sig_ok=$sig_ok pubkey_match=$pk_ok sha_match=$([ "$r_sha" = "$armed_sha" ] && echo true || echo false) probe_s=$PROBE_S window_s=$WINDOW_S unit=hours"
else
  latency_h="-"
  status=FAIL
  note="signed 1 KB bundle never arrived: $windows_used window(s) of ${WINDOW_S}s after ${blocked_total}s cut in total; probe_s=$PROBE_S unit=hours"
fi
printf 'blackout_message\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PROFILE" "$BYTES" "$budget_h" "$latency_h" "$status" \
  "$note run=$RUN_ID bw=- delay=- plr=1.0 scope=all on $IFACE" >>"$TSV"
echo "row       blackout_message $status latency_h=$latency_h blocked_total_s=$blocked_total windows=$windows_used"
echo "evidence  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log  $EVID/media/blackout-bundle.bin"
tail -n 1 "$TSV"
[ "$status" = PASS ]
