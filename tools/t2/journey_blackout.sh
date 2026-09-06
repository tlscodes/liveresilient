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
#
# V3 — THE STREAM LANE (JOURNEY_BLACKOUT_V=3). Same queue, same probe, same
# shaped windows, but the flush travels as ONE framed TCP stream on a second hub
# port (STREAM_PORT, default HTTP_PORT+1) instead of one HTTP POST per chunk:
# hello with the queued ids → the hub's per-id offsets → header + raw bytes per
# record, resumed from the hub's `have` after a cut. The hub counts the bytes it
# carried in stream_stats.json and the runner reads it: util_carried = carried
# bytes / (WINDOW_BPS × measured open seconds). The row PASSes only if every
# bundle arrived signed AND every window that closed with bundles still pending
# reached GATE_PCT utilization.
#   JOURNEY_BLACKOUT_STREAM_PORT=8766       the hub's stream port (default HTTP_PORT+1)
#   JOURNEY_BLACKOUT_STALL_S=25             the phone gives up after this long without a hub line
#   JOURNEY_BLACKOUT_PIECE_BYTES=8192  JOURNEY_BLACKOUT_INFLIGHT_BYTES=32768  JOURNEY_BLACKOUT_ACK_BYTES=8192
#   JOURNEY_BLACKOUT_GATE_PCT=90            util_carried floor per non-final window
#   JOURNEY_BLACKOUT_DRY=1                  print scope, hub argv and the job line, then exit 0
#                                           (touches nothing: no sudo, no shaper, no hub, no phone)
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
[ "$V" = 1 ] || [ "$V" = 2 ] || [ "$V" = 3 ] || { echo "ERROR: JOURNEY_BLACKOUT_V must be 1, 2 or 3 (got $V)" >&2; exit 1; }
if [ "$V" -ge 2 ]; then PROBE_S=${JOURNEY_BLACKOUT_PROBE_S:-2}; else PROBE_S=${JOURNEY_BLACKOUT_PROBE_S:-20}; fi
LIFETIME_S=${JOURNEY_BLACKOUT_LIFETIME_S:-21600}
CHUNK_BYTES=${JOURNEY_BLACKOUT_CHUNK_BYTES:-8192}
WINDOW_KBPS=${JOURNEY_BLACKOUT_WINDOW_KBPS:-16}
# Bytes per second the shaped window carries: kbit/s * 1000 / 8.
WINDOW_BPS=$((WINDOW_KBPS * 125))
PLAN=${JOURNEY_BLACKOUT_PLAN:-'[{"kind":"text","bytes":200,"n":8},{"kind":"voice","bytes":5000,"n":6},{"kind":"photo","bytes":45000,"n":4},{"kind":"video","bytes":100000,"n":2}]'}
# v3 stream lane knobs. The hub is the single source of the lane parameters
# (STREAM_DEFAULTS at the top of journey_hub.py); these travel to it as argv
# and it echoes them to the phone in the hello reply. job.json repeats them so
# the phone's plan is complete on its own. ack_interval_s has no hub argv (the
# hub's default is the only value) and is mirrored here for job.json only.
STREAM_PORT=${JOURNEY_BLACKOUT_STREAM_PORT:-$((HTTP_PORT + 1))}
STALL_S=${JOURNEY_BLACKOUT_STALL_S:-10}
PIECE_BYTES=${JOURNEY_BLACKOUT_PIECE_BYTES:-8192}
INFLIGHT_BYTES=${JOURNEY_BLACKOUT_INFLIGHT_BYTES:-32768}
ACK_BYTES=${JOURNEY_BLACKOUT_ACK_BYTES:-8192}
ACK_INTERVAL_S=2
GATE_PCT=${JOURNEY_BLACKOUT_GATE_PCT:-90}
DRY=${JOURNEY_BLACKOUT_DRY:-0}
# ONE scope string for the cut and for the open call: the phone, plus TCP to
# the hub, the relay and the stream port (net_shape.sh turns tcp=a+b+c into a
# port set). Both calls read this variable so they can never disagree.
SCOPE="peer=$PEER,tcp=$HTTP_PORT+$RELAY_PORT+$STREAM_PORT"
KEY=${JOURNEY_KEY:-blackout$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)}
SHAPE="$REPO/tools/t2/net_shape.sh"
HUB="$REPO/tools/t2/journey_hub.py"
LOGD="$REPO/tools/dossier/logs/journey"
TSV="$REPO/tools/dossier/app_journey_results.tsv"
EVID="$REPO/tools/dossier/evidence/journey"
RUN_ID=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The hub's argv. v2 keeps today's argv exactly, so a v2 run on the new hub
# exercises the old HTTP protocol; v3 adds the stream lane flags.
STREAM_ARGS=()
if [ "$V" = 3 ]; then
  STREAM_ARGS=(--stream-port "$STREAM_PORT" --stream-stall-s "$STALL_S" --stream-ack-bytes "$ACK_BYTES"
               --stream-inflight-bytes "$INFLIGHT_BYTES" --stream-piece-bytes "$PIECE_BYTES")
fi
# The `${a[@]+"${a[@]}"}` form expands an empty array under set -u on bash 3.2.
hub_argv() { printf '%s ' --bind "${SELF:-<self>}" --port "$HTTP_PORT" --dir "${RUN:-<run>}" ${STREAM_ARGS[@]+"${STREAM_ARGS[@]}"}; }
# The job.json line the phone reads, one per version (printed by the dry run,
# written into $RUN/job.json by the live run).
job_line() {
  if [ "$V" = 3 ]; then
    printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"v":3,"plan":%s,"probe_s":%d,"lifetime_s":%d,"chunk_bytes":%d,"stream":{"port":%d,"piece_bytes":%d,"ack_bytes":%d,"ack_interval_s":%d,"inflight_bytes":%d,"stall_s":%d}}}\n' \
      "$RUN_ID" "$KEY" "$LIFETIME_S" "$PLAN" "$PROBE_S" "$LIFETIME_S" "$CHUNK_BYTES" \
      "$STREAM_PORT" "$PIECE_BYTES" "$ACK_BYTES" "$ACK_INTERVAL_S" "$INFLIGHT_BYTES" "$STALL_S"
  elif [ "$V" = 2 ]; then
    printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"v":2,"plan":%s,"probe_s":%d,"lifetime_s":%d,"chunk_bytes":%d}}\n' \
      "$RUN_ID" "$KEY" "$LIFETIME_S" "$PLAN" "$PROBE_S" "$LIFETIME_S" "$CHUNK_BYTES"
  else
    printf '{"run":"%s","key":"%s","hold_s":%d,"profile":"blackout","blackout":{"bytes":%d,"probe_s":%d,"lifetime_s":%d}}\n' \
      "$RUN_ID" "$KEY" "$LIFETIME_S" "$BYTES" "$PROBE_S" "$LIFETIME_S"
  fi
}
if [ "$V" = 3 ] && [ $((2 * STALL_S)) -ge $((MIN_M * 60)) ]; then
  echo "warning   hub silence close 2*STALL_S=$((2 * STALL_S))s >= MIN_M*60=$((MIN_M * 60))s: a stale stream session can outlive the shortest cut; the next hello preempts it"
fi
if [ "$DRY" = 1 ]; then
  # Dry run: show what a live run would do and stop here, before any sudo,
  # shaper, hub, phone, run directory or bridge address is touched or required.
  echo "dry       v=$V scope=$SCOPE"
  echo "dry       hub argv: python3 $HUB $(hub_argv)"
  printf 'dry       job.json: '; job_line
  exit 0
fi
mkdir -p "$LOGD" "$EVID/media"
CONTAINER_TMP="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp"
mkdir -p "$CONTAINER_TMP"
RUN=$(mktemp -d "$CONTAINER_TMP/journey.XXXXXX")
EVENTS="$RUN/phone_events.jsonl"

die() { echo "ERROR: $*" >&2; exit 1; }
shaper() { sudo -n "$SHAPE" "$@"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
# v2/v3 accounting over the hub's event file (Mac clock throughout: received_ms is
# stamped by the hub, the window bounds by this script, so they compare).
#   armed              -> "<v> <bundles> <bytes_total> <created_ms>" of the last blackout_armed
#   delivered          -> distinct bundle ids with a bundle_received event
#   window <lo> <hi>   -> "<count> <bytes>" of bundle_received with lo <= received_ms <= hi
#   final              -> "<delivered> <bytes> <all_sig_ok> <last_received_ms>"
#   stats              -> bytes_carried from stream_stats.json next to the event file (0 if absent)
#   util <bytes> <open_ms> <close_ms> <bps>   -> bytes*100 / (bps * open seconds), 1 decimal
#   ceiling <bundles> <payload> <probe_s> <open_s> -> the per-direction-pipe ceiling model, %:
#       (1 - 52/1500) * (1 - HEADER_B*bundles/payload) * (1 - (probe_s/2 + 1.2 + 0.75)/open_s)
#       (frame overhead) * (per-record header + hello share) * (probe wait + handshake + hello per window)
#       The runner calls it once PER WINDOW with that window's records, payload and
#       MEASURED open seconds (the same denominator util_carried uses), and once for
#       the run with the mean measured open seconds — never with the nominal WINDOW_S,
#       which is ~20 s shorter than a real open and would print a ceiling 0.7 pt low.
# acct-begin
ACCT_PY='import json,os,sys
mode=sys.argv[2]; ev=[]
if os.path.exists(sys.argv[1]):
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
elif mode=="stats":
    p=os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])),"stream_stats.json")
    try: print(int(json.load(open(p)).get("bytes_carried",0)))
    except (OSError, ValueError): print(0)
elif mode=="util":
    b,lo,hi,bps=(int(x) for x in sys.argv[3:7])
    print(round(b*100/(bps*max(0.001,(hi-lo)/1000)),1))
elif mode=="ceiling":
    # HEADER_B: bytes the lane spends per record on the phone->hub pipe besides
    # the payload. The record header line {"id":<16 chars>,"off","len","total",
    # "created_ms":<13 digits>,"sig":<88 chars b64>}\n is 180 B for a 200 B text
    # (186 B for a 100 KB video); the hello names every queued id at 19 B each
    # ("<16 chars>",). Acks and done lines travel the other pipe and are not
    # charged here.
    HEADER_B=180+19
    n,payload,probe_s,open_s=(float(x) for x in sys.argv[3:7])
    c=(1-52/1500)*(1-HEADER_B*n/max(1.0,payload))*(1-(probe_s/2+1.2+0.75)/max(0.001,open_s))
    print(round(c*100,1))
'
# acct-end
acct() { python3 -c "$ACCT_PY" "$EVENTS" "$@"; }
cleanup() {
  shaper teardown >/dev/null 2>&1 || true
  pkill -P $$ 2>/dev/null || true
  pkill -f "journey_hub.py" 2>/dev/null || true
  echo "cleanup: link restored, hub stopped"
}
trap 'exit 130' INT; trap 'exit 143' TERM; trap cleanup EXIT  # signals exit; EXIT cleans up once
caffeinate -dimsu -w $$ >/dev/null 2>&1 &
[ -n "$SELF" ] || die "$IFACE has no address — Internet Sharing on, phone joined?"
sudo -n "$SHAPE" teardown >/dev/null 2>&1 || die "net_shape.sh needs the passwordless sudoers rule"
python3 -c "from cryptography.hazmat.primitives.asymmetric import ed25519" 2>/dev/null \
  || die "python3 needs the 'cryptography' package to verify the bundle's signature"

# --- the hub ---
hub_up=""
for hub_try in 1 2 3; do
  python3 "$HUB" --bind "$SELF" --port "$HTTP_PORT" --dir "$RUN" ${STREAM_ARGS[@]+"${STREAM_ARGS[@]}"} >>"$LOGD/$PROFILE.hub.log" 2>&1 &
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
if [ "$V" = 3 ]; then
  # The inflight window is the hub's: it starts at journey_hub.py's STREAM_W0
  # and every ack advertises the value in force, never above INFLIGHT_BYTES.
  W0=$(python3 -c "import sys; sys.path.insert(0, '$REPO/tools/t2'); import journey_hub as h; print(min(h.STREAM_W0, $INFLIGHT_BYTES))" 2>/dev/null || echo '?')
  echo "profile   blackout v3 stream lane  (no path; random blocked ${MIN_M}-${MAX_M} min, window ${WINDOW_S}s x ${WINDOWS} shaped ${WINDOW_KBPS} kbit/s, probe ${PROBE_S}s, stream port ${STREAM_PORT} piece ${PIECE_BYTES} B inflight ${W0}..${INFLIGHT_BYTES} B hub-advertised, stall ${STALL_S}s, gate ${GATE_PCT}%)"
elif [ "$V" = 2 ]; then
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
job_line >"$RUN/job.json"
for _ in $(seq 1 60); do [ -n "$(phone_event blackout_armed)" ] && break; sleep 1; done
armed=$(phone_event blackout_armed)
[ -n "$armed" ] || die "the phone never armed the bundle (see $EVENTS)"
if [ "$V" -ge 2 ]; then
  read -r armed_v N_BUNDLES BYTES_TOTAL created_ms <<<"$(acct armed)"
  [ "$armed_v" = "$V" ] || die "the phone armed a v$armed_v bundle, not the v$V queue (rebuild the peer with journey_peer_install.sh)"
  [ "$N_BUNDLES" -gt 0 ] 2>/dev/null || die "the v$V armed event names no bundles (see $EVENTS)"
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
  # Every path the app has — UDP and ICMP to the phone plus TCP to the hub,
  # the relay and the stream ports — dropped outright (plr 1.0). The scope
  # travels as the shaper's fourth argument because the sudoers rule strips
  # environment variables; the phone's unrelated system traffic is not cut,
  # the app's is.
  sudo -n "$SHAPE" shape - - 1.0 "$SCOPE" >/dev/null 2>&1
}
if [ "$V" -ge 2 ]; then
  # v2/v3: every window is a thin gate. The link opens SHAPED at WINDOW_KBPS with
  # plr 0.0 stated explicitly (the pipe config is replaced, so the cut's plr
  # does not linger); closing is the plr 1.0 cut again; only the end of the
  # run is a teardown. Per window the hub's bundle_received events whose
  # received_ms lies inside [open_ms, close_ms] are counted and their bytes
  # summed; utilization = bytes / (WINDOW_BPS * open seconds). v3 also reads
  # the hub's stream_stats.json before and after: util_carried = bytes the
  # stream lane carried in the window / the same budget, and every window that
  # closes with bundles still pending must reach GATE_PCT. The last window may
  # end early once every bundle has arrived, and that is written in the note.
  delivered=0
  util_list=""
  bytes_list=""
  carried_list=""
  shape_list=""
  gate_fail=""
  early_end=""
  for w in $(seq 1 "$WINDOWS"); do
    cut_link || die "could not cut the link"
    blocked_s=$(python3 -c "import random,sys; lo,hi=int(sys.argv[1]),int(sys.argv[2]); print(random.randint(lo*60, hi*60))" "$MIN_M" "$MAX_M")
    echo "link      CUT (window $w): blocked for ${blocked_s}s ($(date -u +%H:%M:%SZ))"
    sleep "$blocked_s"
    blocked_total=$((blocked_total + blocked_s))
    # open_ms is stamped AFTER the shaper returns so the window's denominator
    # does not count the shaper's own pfctl/dnctl time; that time is shape_s.
    shape_t0=$(now_ms)
    sudo -n "$SHAPE" shape "${WINDOW_KBPS}Kbit/s" - 0.0 "$SCOPE" >/dev/null 2>&1 \
      || die "could not open the shaped window"
    open_ms=$(now_ms)
    shape_s=$(python3 -c "print(round(($open_ms - $shape_t0)/1000, 2))")
    shape_list="${shape_list:+$shape_list,}$shape_s"
    c0=$(acct stats)
    windows_used=$w
    # The shaper's counters are CUMULATIVE for the life of the pipe: `shape`
    # reconfigures pipes 1/2 in place (dnctl pipe N config keeps the flow queue
    # and its Drp column), and the plr 1.0 cut counts every probe the phone
    # sent into it as a drop. So the status is logged twice per window — this
    # baseline right after the open and one at the close — and the window's
    # own drop count is the DIFFERENCE of the two pipe-1 Drp values, never the
    # close value alone.
    { echo "# window $w open run=$RUN_ID $(date -u +%H:%M:%SZ) open_ms=$open_ms  (Drp is cumulative: this window's drops = close Drp - this Drp)"; sudo -n "$SHAPE" status; } >>"$LOGD/$PROFILE.shape.log" 2>&1
    echo "link      OPEN (window $w) shaped ${WINDOW_KBPS} kbit/s for ${WINDOW_S}s shape_s=$shape_s ($(date -u +%H:%M:%SZ))"
    for t in $(seq 1 "$WINDOW_S"); do
      delivered=$(acct delivered)
      if [ "$delivered" -ge "$N_BUNDLES" ]; then early_end="window $w ended early after ${t}s: all delivered"; break; fi
      sleep 1
    done
    close_ms=$(now_ms)
    # c1 right after close_ms: the hub accounts every appended byte into
    # stream_stats.json as it lands (journey_hub.py, the record write loop), so
    # numerator and denominator end at the same instant.
    c1=$(acct stats)
    # Re-read delivered AT the close: the loop's last read precedes its final
    # sleep, and a bundle landing in that last second would otherwise make a
    # finished window look non-final — gated, not broken out of, and another
    # 30-90 min cut spent on nothing.
    delivered=$(acct delivered)
    read -r w_count w_bytes <<<"$(acct window "$open_ms" "$close_ms")"
    # Utilization over the MEASURED open time, not the nominal window: the
    # last window may end early once every bundle has arrived (refuter, 2026-09-05).
    w_open_s=$(python3 -c "print(round(($close_ms - $open_ms)/1000, 1))")
    w_util=$(acct util "$w_bytes" "$open_ms" "$close_ms" "$WINDOW_BPS")
    w_carried=$(acct util "$((c1 - c0))" "$open_ms" "$close_ms" "$WINDOW_BPS")
    # The ceiling model of THIS window: its records, its payload, its measured
    # open seconds — the per-record term differs 4x between a text/voice window
    # and a video window, so a run average would misjudge both.
    w_ceiling=$(acct ceiling "$w_count" "$w_bytes" "$PROBE_S" "$w_open_s")
    bytes_list="${bytes_list:+$bytes_list,}$w_bytes"
    util_list="${util_list:+$util_list,}${w_util}%@${w_open_s}s"
    carried_list="${carried_list:+$carried_list,}${w_carried}%@${w_open_s}s"
    ceiling_list="${ceiling_list:+$ceiling_list,}${w_ceiling}%"
    open_s_list="${open_s_list:+$open_s_list,}$w_open_s"
    # The receiver's TCP view of the live stream socket at close. rx_dupe and
    # rx_ooo are the retransmissions the pipe totals cannot separate from
    # payload (2026-09-06: rx_dupe was 50 % of bytes_in at a fixed 32 KiB
    # window; the advertised window is falsified if it stays above ~5 % or
    # rtt_avg above ~6 s).
    tcp_row=$(nettop -L 1 -n -m tcp -J bytes_in,rx_dupe,rx_ooo,re-tx,rtt_avg 2>/dev/null | grep -E ":${STREAM_PORT}<->[0-9]" | tail -n 1)
    echo "tcp       window $w stream socket ${tcp_row:-(none live)}  (name,bytes_in,rx_dupe,rx_ooo,re-tx,rtt_avg)"
    # The shaper's view at close; pipe 1's Drp minus the open baseline above
    # is the drop count that explains any gap between util_carried and ceiling.
    { echo "# window $w close run=$RUN_ID $(date -u +%H:%M:%SZ) open_ms=$open_ms close_ms=$close_ms  (this window's drops = this Drp - open Drp)"; sudo -n "$SHAPE" status; } >>"$LOGD/$PROFILE.shape.log" 2>&1
    if [ "$V" = 3 ]; then
      echo "link      window $w closed: $w_count bundle(s) $w_bytes B util=${w_util}% util_carried=${w_carried}% ceiling=${w_ceiling}% ($((c1 - c0)) B carried) delivered=$delivered/$N_BUNDLES ($(date -u +%H:%M:%SZ))"
      if [ "$delivered" -lt "$N_BUNDLES" ] && [ "$(python3 -c "print(1 if $w_carried < $GATE_PCT else 0)")" = 1 ]; then
        gate_fail="${gate_fail:+$gate_fail;}window $w util_carried=${w_carried}% < gate ${GATE_PCT}%"
        echo "gate      window $w util_carried=${w_carried}% below ${GATE_PCT}% with $((N_BUNDLES - delivered)) bundle(s) still pending"
      fi
    else
      echo "link      window $w closed: $w_count bundle(s) $w_bytes B util=${w_util}% delivered=$delivered/$N_BUNDLES ($(date -u +%H:%M:%SZ))"
    fi
    [ "$delivered" -ge "$N_BUNDLES" ] && break
    cut_link || die "could not close the window"
  done
  [ "$delivered" -ge "$N_BUNDLES" ] && received=all
else
for w in $(seq 1 "$WINDOWS"); do
  # Every path the app has — UDP and ICMP to the phone plus TCP to the hub,
  # the relay and the stream ports — dropped outright (plr 1.0). The scope
  # travels as the shaper's fourth argument because the sudoers rule strips
  # environment variables; the phone's unrelated system traffic is not cut,
  # the app's is.
  sudo -n "$SHAPE" shape - - 1.0 "$SCOPE" >/dev/null 2>&1 \
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
if [ "$V" -ge 2 ]; then
  read -r delivered wire_bytes all_ok last_ms <<<"$(acct final)"
  if [ "$last_ms" -gt 0 ] 2>/dev/null; then
    latency_h=$(python3 -c "print(round(($last_ms - $created_ms)/3600000, 3))")
  else
    latency_h="-"
  fi
  status=FAIL
  if [ "$V" = 3 ]; then
    [ "$delivered" = "$N_BUNDLES" ] && [ "$all_ok" = true ] && [ -z "$gate_fail" ] && status=PASS
  else
    [ "$delivered" = "$N_BUNDLES" ] && [ "$all_ok" = true ] && status=PASS
  fi
  mkdir -p "$EVID/media/blackout-gate" && cp "$RUN"/blobs/bundle-*.bin "$EVID/media/blackout-gate/" 2>/dev/null || true
  if [ "$V" = 3 ]; then
    # The run-level ceiling: the whole queue over the MEAN measured open time
    # (the denominator util_carried used), not the nominal WINDOW_S. The
    # per-window list `ceiling=` is the number each window is judged against.
    mean_open_s=$(python3 -c "import sys; v=[float(x) for x in sys.argv[1].split(',') if x]; print(round(sum(v)/len(v),1) if v else float(sys.argv[2]))" "$open_s_list" "$WINDOW_S")
    ceiling_model=$(acct ceiling "$N_BUNDLES" "$BYTES_TOTAL" "$PROBE_S" "$mean_open_s")
    cp "$RUN/stream_stats.json" "$LOGD/$PROFILE.stream_stats.json" 2>/dev/null || true
    note="signed queue of $N_BUNDLES bundles ($BYTES_TOTAL B) held in the phone's durable store-and-forward queue with no path, streamed through ${WINDOW_KBPS} kbit/s windows on one framed TCP lane; bundles=$delivered/$N_BUNDLES windows=$windows_used util=${util_list:--} util_carried=${carried_list:--} ceiling=${ceiling_list:--} ceiling_model=${ceiling_model}%@${mean_open_s}s gate_pct=$GATE_PCT window_bytes=${bytes_list:--} cut_total_s=$blocked_total probe_s=$PROBE_S stream_port=$STREAM_PORT stall_s=$STALL_S inflight=$INFLIGHT_BYTES piece_bytes=$PIECE_BYTES ack_bytes=$ACK_BYTES shape_s=${shape_list:--} window_kbps=$WINDOW_KBPS window_s=$WINDOW_S sig_all_ok=$all_ok${gate_fail:+ gate_fail=$gate_fail}${early_end:+ $early_end} unit=hours"
  else
    note="signed queue of $N_BUNDLES bundles ($BYTES_TOTAL B) held in the phone's durable store-and-forward queue with no path, flushed through ${WINDOW_KBPS} kbit/s windows; bundles=$delivered/$N_BUNDLES windows=$windows_used util=${util_list:--} window_bytes=${bytes_list:--} cut_total_s=$blocked_total probe_s=$PROBE_S chunk_bytes=$CHUNK_BYTES window_kbps=$WINDOW_KBPS window_s=$WINDOW_S shape_s=${shape_list:--} sig_all_ok=$all_ok${early_end:+ $early_end} unit=hours"
  fi
  printf 'blackout_gate\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PROFILE" "$wire_bytes" "$budget_h" "$latency_h" "$status" \
    "$note run=$RUN_ID bw=${WINDOW_KBPS}Kbit/s delay=- plr=1.0 scope=peer+tcp on $IFACE" >>"$TSV"
  if [ "$V" = 3 ]; then
    echo "row       blackout_gate $status bundles=$delivered/$N_BUNDLES latency_h=$latency_h blocked_total_s=$blocked_total windows=$windows_used util=${util_list:--} util_carried=${carried_list:--} ceiling=${ceiling_list:--} ceiling_model=${ceiling_model}%@${mean_open_s}s${gate_fail:+ gate_fail=$gate_fail}"
    echo "evidence  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log  $LOGD/$PROFILE.shape.log  $LOGD/$PROFILE.stream_stats.json  $EVID/media/blackout-gate/"
  else
    echo "row       blackout_gate $status bundles=$delivered/$N_BUNDLES latency_h=$latency_h blocked_total_s=$blocked_total windows=$windows_used util=${util_list:--}"
    echo "evidence  $LOGD/$PROFILE.phone.jsonl  $LOGD/$PROFILE.hub.log  $LOGD/$PROFILE.shape.log  $EVID/media/blackout-gate/"
  fi
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
