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
#
# V2 — THE WINDOW IS A GATE (JOURNEY_BLACKOUT_V=2; v1 above stays the default).
# The phone holds a QUEUE of signed bundles with real sizes (8 texts, 6 voice
# notes, 4 photos, 2 videos = 20 bundles, ~410 KB) and probes with a 60-byte
# GET every 2 s. Each window opens SHAPED at 16 kbit/s (2000 B/s) instead of
# unshaped, so a window of WINDOW_S seconds carries at most 2000*WINDOW_S bytes
# and utilization = bytes delivered / that budget is a real number. Bundles
# larger than chunk_bytes travel as chunks with per-chunk acks, so a window that
# closes mid-transfer keeps its progress and the next window resumes from the
# first missing chunk. The row is `blackout_gate`: wire_B = bytes delivered,
# measured = hours from arming to the LAST bundle, PASS iff every bundle arrived
# with its signature intact; the note carries per-window bytes and utilization.
#   JOURNEY_BLACKOUT_V=2                    select v2 (unset/1 = the v1 single-bundle row)
#   JOURNEY_BLACKOUT_PROBE_S=2              v2 default 2 (v1 default 20)
#   JOURNEY_BLACKOUT_CHUNK_BYTES=8192  JOURNEY_BLACKOUT_WINDOW_KBPS=16
#   JOURNEY_BLACKOUT_PLAN='[{"kind":"text","bytes":200,"n":8},...]'   the queue plan (JSON)
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
V=${JOURNEY_BLACKOUT_V:-1}
[ "$V" = 1 ] || [ "$V" = 2 ] || { echo "ERROR: JOURNEY_BLACKOUT_V must be 1 or 2 (got $V)" >&2; exit 1; }
if [ "$V" = 2 ]; then PROBE_S=${JOURNEY_BLACKOUT_PROBE_S:-2}; else PROBE_S=${JOURNEY_BLACKOUT_PROBE_S:-20}; fi
LIFETIME_S=${JOURNEY_BLACKOUT_LIFETIME_S:-21600}
CHUNK_BYTES=${JOURNEY_BLACKOUT_CHUNK_BYTES:-8192}
WINDOW_KBPS=${JOURNEY_BLACKOUT_WINDOW_KBPS:-16}
# Bytes per second the shaped window carries: kbit/s * 1000 / 8.
WINDOW_BPS=$((WINDOW_KBPS * 125))
PLAN=${JOURNEY_BLACKOUT_PLAN:-'[{"kind":"text","bytes":200,"n":8},{"kind":"voice","bytes":5000,"n":6},{"kind":"photo","bytes":45000,"n":4},{"kind":"video","bytes":100000,"n":2}]'}
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
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
# v2 accounting over the hub's event file (Mac clock throughout: received_ms is
# stamped by the hub, the window bounds by this script, so they compare).
#   armed              -> "<v> <bundles> <bytes_total> <created_ms>" of the last blackout_armed
#   delivered          -> distinct bundle ids with a bundle_received event
#   window <lo> <hi>   -> "<count> <bytes>" of bundle_received with lo <= received_ms <= hi
#   final              -> "<delivered> <bytes> <all_sig_ok> <last_received_ms>"
# acct-begin
ACCT_PY='import json,sys
mode=sys.argv[2]; ev=[]
for l in open(sys.argv[1]):
    l=l.strip()
    if l: ev.append(json.loads(l))
rec=[e for e in ev if e.get("event")=="bundle_received"]
if mode=="armed":
    a=[e for e in ev if e.get("event")=="blackout_armed"]
    e=a[-1] if a else {}
    print(e.get("v",1), e.get("bundles",0), e.get("bytes_total",0), e.get("created_ms",0))
elif mode=="delivered":
    print(len({e.get("id") for e in rec}))
elif mode=="window":
    lo,hi=int(sys.argv[3]),int(sys.argv[4])
    w=[e for e in rec if lo<=int(e.get("received_ms",0))<=hi]
    print(len(w), sum(int(e.get("bytes",0)) for e in w))
elif mode=="final":
    first={}
    for e in rec: first.setdefault(e.get("id"),e)
    ok=bool(rec) and all(e.get("sig_ok") is True and e.get("pubkey_match") is True for e in rec)
    last=max((int(e.get("received_ms",0)) for e in rec), default=0)
    print(len(first), sum(int(e.get("bytes",0)) for e in first.values()), "true" if ok else "false", last)
'
# acct-end
acct() { python3 -c "$ACCT_PY" "$EVENTS" "$@"; }
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
if [ "$V" = 2 ]; then
  echo "profile   blackout v2 gate  (no path; random blocked ${MIN_M}-${MAX_M} min, window ${WINDOW_S}s x ${WINDOWS} shaped ${WINDOW_KBPS} kbit/s, probe ${PROBE_S}s, chunk ${CHUNK_BYTES} B)"
else
  echo "profile   blackout  (no path; random blocked ${MIN_M}-${MAX_M} min, window ${WINDOW_S}s x ${WINDOWS}, bundle ${BYTES} B, probe ${PROBE_S}s)"
fi
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
if [ "$V" = 2 ]; then
  printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"v":2,"plan":%s,"probe_s":%d,"lifetime_s":%d,"chunk_bytes":%d}}\n' \
    "$RUN_ID" "$KEY" "$LIFETIME_S" "$PLAN" "$PROBE_S" "$LIFETIME_S" "$CHUNK_BYTES" >"$RUN/job.json"
else
  printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"bytes":%d,"probe_s":%d,"lifetime_s":%d}}\n' \
    "$RUN_ID" "$KEY" "$LIFETIME_S" "$BYTES" "$PROBE_S" "$LIFETIME_S" >"$RUN/job.json"
fi
for _ in $(seq 1 60); do [ -n "$(phone_event blackout_armed)" ] && break; sleep 1; done
armed=$(phone_event blackout_armed)
[ -n "$armed" ] || die "the phone never armed the bundle (see $EVENTS)"
if [ "$V" = 2 ]; then
  read -r armed_v N_BUNDLES BYTES_TOTAL created_ms <<<"$(acct armed)"
  [ "$armed_v" = 2 ] || die "the phone armed a v$armed_v bundle, not the v2 queue (rebuild the peer with journey_peer_install.sh)"
  [ "$N_BUNDLES" -gt 0 ] 2>/dev/null || die "the v2 armed event names no bundles (see $EVENTS)"
  echo "phone     queue armed: $N_BUNDLES bundles, $BYTES_TOTAL B, created_ms=$created_ms — cutting the link"
else
  armed_sha=$(printf '%s' "$armed" | grep -oE '"sha256":"[0-9a-f]+"' | cut -d'"' -f4)
  created_ms=$(printf '%s' "$armed" | grep -oE '"created_ms":[0-9]+' | cut -d: -f2)
  echo "phone     bundle armed sha256=${armed_sha:0:16}… created_ms=$created_ms — cutting the link"
fi

# --- the blackout: total, then random windows ---
blocked_total=0
windows_used=0
received=""
cut_link() {
  # Every path the app has — UDP and ICMP to the phone plus TCP to the hub
  # and the relay ports — dropped outright (plr 1.0). The scope travels as
  # the shaper's fourth argument because the sudoers rule strips environment
  # variables; the phone's unrelated system traffic is not cut, the app's is.
  sudo -n "$SHAPE" shape - - 1.0 "peer=$PEER,tcp=$HTTP_PORT+$RELAY_PORT" >/dev/null 2>&1
}
if [ "$V" = 2 ]; then
  # v2: every window is a thin gate. The link opens SHAPED at WINDOW_KBPS with
  # plr 0.0 stated explicitly (the pipe config is replaced, so the cut's plr
  # does not linger); closing is the plr 1.0 cut again; only the end of the
  # run is a teardown. Per window the hub's bundle_received events whose
  # received_ms lies inside [open_ms, close_ms] are counted and their bytes
  # summed; utilization = bytes / (WINDOW_BPS * WINDOW_S). The last window may
  # end early once every bundle has arrived, and that is written in the note.
  delivered=0
  util_list=""
  bytes_list=""
  early_end=""
  for w in $(seq 1 "$WINDOWS"); do
    cut_link || die "could not cut the link"
    blocked_s=$(python3 -c "import random,sys; lo,hi=int(sys.argv[1]),int(sys.argv[2]); print(random.randint(lo*60, hi*60))" "$MIN_M" "$MAX_M")
    echo "link      CUT (window $w): blocked for ${blocked_s}s ($(date -u +%H:%M:%SZ))"
    sleep "$blocked_s"
    blocked_total=$((blocked_total + blocked_s))
    open_ms=$(now_ms)
    sudo -n "$SHAPE" shape "${WINDOW_KBPS}Kbit/s" - 0.0 "peer=$PEER,tcp=$HTTP_PORT+$RELAY_PORT" >/dev/null 2>&1 \
      || die "could not open the shaped window"
    windows_used=$w
    echo "link      OPEN (window $w) shaped ${WINDOW_KBPS} kbit/s for ${WINDOW_S}s ($(date -u +%H:%M:%SZ))"
    for t in $(seq 1 "$WINDOW_S"); do
      delivered=$(acct delivered)
      if [ "$delivered" -ge "$N_BUNDLES" ]; then early_end="window $w ended early after ${t}s: all delivered"; break; fi
      sleep 1
    done
    close_ms=$(now_ms)
    read -r w_count w_bytes <<<"$(acct window "$open_ms" "$close_ms")"
    # Utilization over the MEASURED open time, not the nominal window: the
    # last window may end early once every bundle has arrived (refuter, 2026-09-05).
    w_open_s=$(python3 -c "print(round(($close_ms - $open_ms)/1000, 1))")
    w_util=$(python3 -c "print(round($w_bytes*100/($WINDOW_BPS*max(0.001, ($close_ms - $open_ms)/1000)), 1))")
    bytes_list="${bytes_list:+$bytes_list,}$w_bytes"
    util_list="${util_list:+$util_list,}${w_util}%@${w_open_s}s"
    echo "link      window $w closed: $w_count bundle(s) $w_bytes B util=${w_util}% delivered=$delivered/$N_BUNDLES ($(date -u +%H:%M:%SZ))"
    [ "$delivered" -ge "$N_BUNDLES" ] && break
    cut_link || die "could not close the window"
  done
  [ "$delivered" -ge "$N_BUNDLES" ] && received=all
else
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
fi
if [ -n "$received" ]; then
  # Let the peer's `ended` event through before the link closes for good.
  for _ in $(seq 1 30); do [ -f "$RUN/job.done" ] && break; sleep 1; done
fi
shaper teardown >/dev/null 2>&1 || true
cp "$EVENTS" "$LOGD/$PROFILE.phone.jsonl" 2>/dev/null || true

# --- the row: latency in HOURS ---
[ -f "$TSV" ] || printf 'feature\tprofile\twire_B\tbudget_s\tmeasured_s\tstatus\tnote\n' >"$TSV"
budget_h=$(python3 -c "print(round($LIFETIME_S/3600, 2))")
if [ "$V" = 2 ]; then
  read -r delivered wire_bytes all_ok last_ms <<<"$(acct final)"
  if [ "$last_ms" -gt 0 ] 2>/dev/null; then
    latency_h=$(python3 -c "print(round(($last_ms - $created_ms)/3600000, 3))")
  else
    latency_h="-"
  fi
  status=FAIL
  [ "$delivered" = "$N_BUNDLES" ] && [ "$all_ok" = true ] && status=PASS
  mkdir -p "$EVID/media/blackout-gate" && cp "$RUN"/blobs/bundle-*.bin "$EVID/media/blackout-gate/" 2>/dev/null || true
  note="signed queue of $N_BUNDLES bundles ($BYTES_TOTAL B) held in the phone's durable store-and-forward queue with no path, flushed through ${WINDOW_KBPS} kbit/s windows; bundles=$delivered/$N_BUNDLES windows=$windows_used util=${util_list:--} window_bytes=${bytes_list:--} cut_total_s=$blocked_total probe_s=$PROBE_S chunk_bytes=$CHUNK_BYTES window_kbps=$WINDOW_KBPS window_s=$WINDOW_S sig_all_ok=$all_ok${early_end:+ $early_end} unit=hours"
  printf 'blackout_gate\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PROFILE" "$wire_bytes" "$budget_h" "$latency_h" "$status" \
    "$note run=$RUN_ID bw=${WINDOW_KBPS}Kbit/s delay=- plr=1.0 scope=peer+tcp on $IFACE" >>"$TSV"
  echo "row       blackout_gate $status bundles=$delivered/$N_BUNDLES latency_h=$latency_h blocked_total_s=$blocked_total windows=$windows_used util=${util_list:--}"
  echo "evidence  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log  $EVID/media/blackout-gate/"
  tail -n 1 "$TSV"
  [ "$status" = PASS ]
  exit $?
fi
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
