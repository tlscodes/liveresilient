#!/usr/bin/env bash
# h2_run.sh — apply one network profile, run one device test under it, restore,
# and print a row that can be pasted into the results table.
#
# WHY THIS EXISTS. The shaper worked and the device tests passed, but nothing
# joined them: the profiles were applied by hand, the tests were run by hand,
# and in between the two the shaping was simply left on. That produced a machine
# stuck at 900 ms delay and zero measurements. A measurement procedure that
# depends on a human remembering the teardown is not a procedure.
#
# THE THREE THINGS IT REFUSES TO DO
#
#  1. Leave the host shaped. `teardown` runs from a trap, so it happens on
#     success, on failure, on a crashed test, and on Ctrl-C.
#  2. Report a number from traffic that never crossed the shaped interface.
#     This is the same trap that made the feth rig meaningless and would have
#     made an /etc/hosts blackout on the wrong machine meaningless: shaping is
#     applied to an interface, and if the test's packets go somewhere else the
#     result is a clean-network number wearing a shaped-network label. A
#     tcpdump runs for the whole test and the row is marked INVALID/UNROUTED
#     unless real traffic was seen.
#  3. Call an unshaped LAN a "normal network". The unshaped path here is
#     ~0.7 ms; asserting "text under 500 ms" against that is an assertion that
#     cannot fail. The `normal` profile therefore injects 40 ms each way
#     (RTT ~80 ms), which is what an ordinary mobile connection looks like.
#
# USAGE
#   sudo tools/t2/h2_run.sh <profile> <test-file> [device-id]
#   sudo tools/t2/h2_run.sh --list
#
# EXAMPLE
#   sudo tools/t2/h2_run.sh latency  integration_test/loopback_call_test.dart
#   sudo tools/t2/h2_run.sh normal   integration_test/loopback_call_test.dart
#
# Root is required for pf/dnctl and tcpdump. `flutter` is invoked as the
# ORIGINAL user (SUDO_USER), because a root-owned build directory breaks every
# later non-sudo build.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
APP="$REPO/apps/reference_app"
SHAPE="$HERE/net_shape.sh"
IFACE="${T2_IFACE:-bridge100}"
RESULTS="${T2_RESULTS:-$REPO/tools/t2/h2_results.tsv}"

# --- profiles -------------------------------------------------------------
# name        bw          delay  plr    what it is for
profile_args() {
  case "$1" in
    normal)   echo "-        40    0.0" ;;   # RTT ~80 ms: an ordinary link
    latency)  echo "-        900   0.0" ;;   # RTT ~1800 ms: threshold 1
    bandwidth) echo "32Kbit/s -    0.0" ;;   # threshold 3, live audio floor
    narrow)   echo "16Kbit/s -    0.0" ;;   # threshold 3, text/signalling floor
    loss10)   echo "-        -     0.10" ;;  # threshold 5, PLC / retransmit
    loss60)   echo "-        -     0.60" ;;  # threshold 2, i.i.d. (see note)
    extreme)  echo "16Kbit/s 1000  0.15" ;;  # threshold 7, everything at once
    # FULL_TEST_PLAN track 3: 2Kbps / 60% end-to-end / rtt 2000ms. Loss is
    # stated PER CROSSING at 1-sqrt(1-0.6)=0.3675 so the datagram path's
    # double crossing composes to the claimed 60% end-to-end — the datagram
    # probes' own convention ("matching, not doubling", see
    # apps/reference_app/test/datagram_lane_probe_test.dart header) and the
    # only reading under which the plan's own chat<=3s derivation holds.
    t3x)      echo "2Kbit/s  1000  0.3675" ;;
    clean)    echo "-        -     0.0" ;;   # shaped path, no impairment
    # `jitter` is deliberately absent. dummynet applies a FIXED delay; it has
    # no delay distribution, so a jitter profile could only be faked by calling
    # constant latency "jitter". The honest place to test a jitter buffer is
    # the in-process harness (H1), where the delay per packet is chosen by the
    # simulator. Approximating it here would produce a green row that means
    # nothing — the one outcome this whole harness exists to prevent.
    jitter)
      echo "PROFILE 'jitter' IS NOT SUPPORTED BY dummynet." >&2
      echo "dummynet has a fixed delay and no jitter distribution. Use the" >&2
      echo "in-process (H1) harness for jitter-buffer behaviour, or state the" >&2
      echo "limitation instead of approximating it." >&2
      return 1 ;;
    *) return 1 ;;
  esac
}

list_profiles() {
  cat <<'EOF'
profile     shaping                       threshold it serves
normal      delay 40   (RTT ~80 ms)       #4  text delivered < 500 ms
latency     delay 900  (RTT ~1800 ms)     #1  session survives high RTT
bandwidth   bw 32Kbit/s                   #3  live audio floor
narrow      bw 16Kbit/s                   #3  text/signalling floor
loss10      plr 0.10                      #5  PLC / retransmission
loss60      plr 0.60                      #2  loss tolerance (i.i.d. only)
extreme     16Kbit/s + 1000 ms + 15% loss #7  survive and recover
clean       no impairment, shaped path    control: proves the rig is neutral

jitter      NOT SUPPORTED — dummynet has a fixed delay and no distribution.
            Faking it with constant latency would be a green row that means
            nothing. Jitter belongs to the in-process (H1) harness.

NOTE on loss profiles: dummynet drops packets independently. Real loss is
bursty and HARDER at the same rate. A pass here is necessary, not sufficient;
say so in any report.

WHAT IS SHAPED: by default UDP only, excluding mDNS (5353), so the media path
is impaired and `flutter test`'s own control channel is not. Shaping everything
starved the debugger and produced two false FAILs on 2026-08-03. Override with
T2_SHAPE_ALL=1 only for a deliberate blackout.
EOF
}

die() { echo "ERROR: $*" >&2; exit 2; }

[ $# -ge 1 ] || { list_profiles; exit 2; }
[ "$1" = "--list" ] && { list_profiles; exit 0; }
[ $# -ge 2 ] || die "usage: h2_run.sh <profile> <test-file> [device-id]"

PROFILE="$1"
TEST="$2"
DEVICE="${3:-${T2_DEVICE:-}}"

ARGS=$(profile_args "$PROFILE") || die "unknown profile '$PROFILE' (try --list)"
read -r BW DELAY PLR <<<"$ARGS"

# RELAY-CROSSING CALIBRATION (deliberate double-entry, 2026-08-06).
#
# profile_args states each profile's CLAIM: a link of that capacity between
# the peers — ONE crossing. This rig forces every RTP packet through the
# Mac's TURN relay (E2E_FORCE_RELAY below), so the same packet crosses the
# shaped bridge TWICE, and an unadjusted cap tests HALF the stated claim.
# Measured 2026-08-06T18:2xZ on exactly that mistake: bandwidth (32 kbit
# shaped, force-relay) gave ack p50 1598 ms on a 43 ms path, 95% probe
# starvation, call dead mid-hold — a 16 kbit/s row wearing a 32 kbit/s
# label. Bandwidth caps are therefore DOUBLED at apply time so per-crossing
# capacity equals the claim. Same honesty rule as the stress tier's bounds:
# the claim table is never silently redefined by rig topology — the
# conversion is explicit and applies ONLY to bandwidth. Delay and loss stay
# as stated: the ack/rtt probes cross once each way, so rtt_ms in the table
# matches the claim; the media path's doubled delay and compounded loss
# under force-relay remain a KNOWN residual for the results legend, not a
# silent compensation. budget_conditions stays on CLAIM values — after this
# doubling the app-visible per-crossing capacity equals the claim, so the
# model inputs and the rig finally agree (they disagreed by 2x before).
if [ "$BW" != "-" ]; then
  _bw_num="${BW%%[A-Za-z]*}"
  _bw_unit="${BW#"$_bw_num"}"
  BW="$(( _bw_num * 2 ))$_bw_unit"
  echo "bw claim  ${_bw_num}${_bw_unit} per crossing -> shaping $BW (force-relay crosses twice)"
fi

[ "$(id -u)" -eq 0 ] || die "must run as root (pf, dnctl and tcpdump need it)"
[ -f "$APP/$TEST" ] || die "test not found: $APP/$TEST"
command -v tcpdump >/dev/null || die "tcpdump not found"

RUN_AS="${SUDO_USER:-}"
[ -n "$RUN_AS" ] || die "run through sudo, not as a root login: flutter must \
build as the normal user or the build directory becomes root-owned"

TMP=$(mktemp -d /tmp/h2run.XXXXXX)
PCAP="$TMP/traffic.txt"
LOG="$TMP/test.log"
EXC="$TMP/exception.txt"
TCPDUMP_PID=""

# A DIAGNOSTIC THAT NEEDS SUDO TO READ IS A DIAGNOSTIC NOBODY READS.
#
# `mktemp -d` under sudo produces a root-owned 0700 directory, and this script
# then prints "log /tmp/h2run.XXXX/test.log" as though that were an actionable
# next step. It is not: the operator gets "Permission denied", and the only
# record of why a one-hour matrix failed sits behind another sudo they have to
# think to use — at the exact moment they are least inclined to.
#
# The results file was already chowned. The log, the pcap and the exception
# were not, which is the half of the output that matters when something breaks.
chown "$RUN_AS" "$TMP" 2>/dev/null || true
chmod 755 "$TMP" 2>/dev/null || true

# --- lifecycle ------------------------------------------------------------
# Everything that can leave the machine altered is undone here, and this runs
# on every exit path including SIGINT. The restore is verified, not assumed.
RELAY_PID=""
TURN_PID=""
DGRAM_PID=""

cleanup() {
  local rc=$?
  [ -n "$TCPDUMP_PID" ] && kill "$TCPDUMP_PID" 2>/dev/null || true
  [ -n "${SIGDUMP_PID:-}" ] && kill "$SIGDUMP_PID" 2>/dev/null || true
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
  [ -n "$TURN_PID" ] && kill "$TURN_PID" 2>/dev/null || true
  [ -n "$DGRAM_PID" ] && kill "$DGRAM_PID" 2>/dev/null || true
  "$SHAPE" teardown >/dev/null 2>&1 || true
  local rtt
  rtt=$(ping -c 3 -i 0.2 -q "${PEER:-127.0.0.1}" 2>/dev/null \
        | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
  if [ -n "${rtt:-}" ] && [ "$(python3 -c "print(1 if ${rtt} > 100 else 0)")" = 1 ]; then
    echo "WARNING: host still looks shaped after teardown (rtt ${rtt} ms)." >&2
    echo "         Run: sudo $SHAPE restore" >&2
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# --- peer discovery -------------------------------------------------------
SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -n "$SELF" ] || die "no address on $IFACE — is Internet Sharing up?"
PEER="${T2_PEER:-}"
if [ -z "$PEER" ]; then
  PEER=$(arp -an 2>/dev/null | grep "on $IFACE" | grep -oE '\(([0-9.]+)\)' \
         | tr -d '()' | grep -v "^${SELF:-none}$" | head -1)
fi
[ -n "$PEER" ] || die "no peer on $IFACE — is the phone joined to this Mac's hotspot?"

# WIRED-ONLY GATE (2026-08-09). A 22-draw night proved the Mac Wi-Fi radio
# cannot hold the peer for even one shot (minute-scale one-way outages that
# stamp INVALID/UNROUTED). The test path must be a wire. Two refusals, both
# BEFORE shaping touches the host; T2_ALLOW_RADIO=1 overrides deliberately.
if [ "${T2_ALLOW_RADIO:-0}" != "1" ]; then
  WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
  if [ -n "$WIFI_DEV" ] && [ "$IFACE" = "$WIFI_DEV" ]; then
    die "REFUSED: $IFACE is the Wi-Fi radio — wired-only law (T2_ALLOW_RADIO=1 to override)"
  fi
  BASE=$(ping -c 20 -i 0.2 -t 8 "$PEER" 2>/dev/null | tail -2)
  BASE_LOSS=$(printf '%s' "$BASE" | awk -F'[ %]' '/packet loss/{print $7}')
  BASE_RTT=$(printf '%s' "$BASE" | awk -F'/' '/round-trip/{printf "%d", $5}')
  BASE_LOSS=${BASE_LOSS%.*}
  if [ -z "$BASE_LOSS" ] || [ "${BASE_LOSS:-100}" -ge 5 ] || [ "${BASE_RTT:-999}" -ge 20 ]; then
    die "REFUSED: baseline not wire-grade (loss=${BASE_LOSS:-?}% rtt=${BASE_RTT:-?}ms; need <5% and <20ms) — check the USB link"
  fi
  echo "wired-gate baseline ok: loss=${BASE_LOSS}% rtt=${BASE_RTT}ms on $IFACE"
fi

# Scope the impairment to the peer, and include the Mac-hosted relay's TCP
# port so the signalling path is genuinely impaired (net_shape.sh reads both).
RELAY_PORT="${T2_RELAY_PORT:-8443}"
TURN_PORT="${T2_TURN_PORT:-3478}"
export T2_PEER="$PEER"
# Both TCP control paths travel the shaped road (2026-08-08): the
# signalling relay AND the media relay's TCP listener — an ICE entry
# with transport=tcp on an unshaped port would be an unshaped metric.
export T2_SHAPE_TCP_PORT="{ $RELAY_PORT, $TURN_PORT }"

echo "profile   $PROFILE  (bw=$BW delay=$DELAY plr=$PLR)"
echo "iface     $IFACE   self $SELF   peer $PEER"
echo "rig       relay wss://$SELF:$RELAY_PORT/ (TCP shaped)  turn $SELF:$TURN_PORT (UDP shaped, media forced through it)"
echo "test      $TEST"

# --- apply ---------------------------------------------------------------
"$SHAPE" teardown >/dev/null 2>&1 || true
# E2E-HONEST LOSS (2026-08-09): the loopback path crosses this pipe TWICE
# (phone -> TURN and TURN -> phone), so a raw pipe plr P produces an
# end-to-end loss of 1-(1-P)^2 — loss60 physically ran at 84% while the
# app's budget model (E2E_LOSS) and the row label said 60%. The rtt
# column already models the double crossing (extreme: pipe 1000 ms, app
# rtt 2000 ms); loss now does the same: the pipe gets 1-sqrt(1-P) so the
# measured e2e loss equals the label. Raw single-crossing shaping is
# still available for non-loopback work via T2_RAW_PLR=1.
if [ "$PLR" != "-" ] && [ -z "${T2_RAW_PLR:-}" ]; then
  PIPE_PLR=$(python3 -c "import math; print(round(1-math.sqrt(1-float('$PLR')),4))") \
    || die "could not derive per-crossing plr from $PLR"
  echo "e2e-honest plr: pipe $PIPE_PLR per crossing -> e2e $PLR"
else
  PIPE_PLR="$PLR"
fi
"$SHAPE" shape "$BW" "$DELAY" "$PIPE_PLR" >/dev/null || die "could not apply shaping"

# Confirm the shaping is real BEFORE the test, the same way the selftest does.
# An applied-but-ineffective rule is the failure this whole harness exists for.
probe=$(ping -c 10 -i 0.2 -q "$PEER" 2>/dev/null | tail -2)
probe_rtt=$(printf '%s' "$probe" | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
probe_loss=$(printf '%s' "$probe" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+' || echo 0)
echo "verified  rtt ${probe_rtt:-?} ms  loss ${probe_loss}%"

# The probe is ICMP, so ICMP must be inside the shaped set — see the fifth
# post-mortem in net_shape.sh. When a caller narrows the scope with
# T2_SHAPE_SPEC, this check may no longer be able to observe the impairment,
# so it says so instead of failing a run that is fine.
if [ "$DELAY" != "-" ]; then
  ok=$(python3 -c "print(1 if ${probe_rtt:-0} >= ${DELAY} else 0)" 2>/dev/null || echo 0)
  if [ "$ok" != 1 ]; then
    if [ -n "${T2_SHAPE_SPEC:-}" ]; then
      echo "WARNING: could not verify shaping with an ICMP probe, because" >&2
      echo "         T2_SHAPE_SPEC narrows what is impaired. Proceeding, but" >&2
      echo "         this row is only as trustworthy as that custom scope." >&2
    else
      die "shaping did not take effect (rtt ${probe_rtt:-?} < ${DELAY})"
    fi
  fi
fi

# A loss profile deserves the same treatment: applied-but-ineffective loss
# would silently turn a hostile row into a clean one.
if [ "$PLR" != "-" ] && [ "$PLR" != "0.0" ] && [ -z "${T2_SHAPE_SPEC:-}" ]; then
  want=$(python3 -c "print(round(float('$PLR') * 100 * 0.4))" 2>/dev/null || echo 0)
  ok=$(python3 -c "print(1 if ${probe_loss:-0} >= ${want} else 0)" 2>/dev/null || echo 0)
  [ "$ok" = 1 ] || die "loss did not take effect (${probe_loss}% seen, wanted >= ${want}%)"
fi

# --- watch the wire -------------------------------------------------------
# Counting packets on the shaped interface is the only evidence that the test's
# traffic went through the impairment rather than around it — and the FILTER
# must match the pf rule's scope, or it counts the wrong traffic. The old
# filter (`host $PEER`, floor 10) counted mDNS, DNS, the Dart VM Service and
# any TCP chatter as "evidence": a passing 2026-08-05 run had 322 lines of
# which only 172 were even shape-eligible UDP, none of them media. This filter
# is the UDP scope of the pf rule verbatim; the floors are derived from the
# media design rate below.
tcpdump -i "$IFACE" -n -q "host $PEER and ((udp and not port 5353) or (tcp and port $TURN_PORT))" >"$PCAP" 2>/dev/null &  # media evidence: UDP + the shaped TCP relay leg
TCPDUMP_PID=$!
# SECOND, SEPARATE capture: the WSS signaling legs (TCP :8443). The floors
# above count MEDIA evidence and must stay UDP-only, so this never touches
# $PCAP — it exists because the 2026-08-07 loss60 investigation went four
# layers deep with the signaling path completely invisible (every send
# timing out, no wire evidence of which leg starved: frame out, relay
# forward, or the fire-and-forget ack riding back).
SIGPCAP="$TMP/signaling.txt"
tcpdump -i "$IFACE" -n -q "tcp and host $PEER and port $RELAY_PORT" \
  >"$SIGPCAP" 2>/dev/null &
SIGDUMP_PID=$!
sleep 1

# --- run ------------------------------------------------------------------
started=$(python3 -c 'import time; print(int(time.time()*1000))')
DEV_ARG=""
[ -n "$DEVICE" ] && DEV_ARG="-d $DEVICE"
# The flutter binary is resolved HERE, in the invoking shell, and passed down as
# an absolute path.
#
# Why: `bash -lc` reads bash's login files, and this user's PATH lives in
# ~/.zshrc. On this machine that difference is not cosmetic — it selects a
# DIFFERENT SDK: /usr/local/bin/flutter is 3.44.6 while
# ~/development/flutter/bin/flutter is 3.35.2, and the app requires Dart
# ^3.12.2. The harness therefore failed with
#   "Because reference_app requires SDK version ^3.12.2, version solving failed"
# which reads like a dependency problem and is really a PATH problem. Every
# profile then reported FAIL for a reason that had nothing to do with the
# network being shaped.
FLUTTER_BIN="${T2_FLUTTER:-$(command -v flutter || true)}"
if [ -z "$FLUTTER_BIN" ] && [ -n "$RUN_AS" ]; then
  FLUTTER_BIN=$(sudo -u "$RUN_AS" zsh -lc 'command -v flutter' 2>/dev/null || true)
fi
[ -n "$FLUTTER_BIN" ] || die "flutter not found; set T2_FLUTTER=/path/to/flutter"

# --- off-device rig -------------------------------------------------------
# The relay and the TURN server live on the MAC so the phone's signalling and
# media genuinely cross the shaped interface. Without these defines the suite
# is pure in-process loopback on the phone: both call stacks AND the relay in
# one process, nothing on bridge100, and every "shaped" number is a loopback
# number wearing a shaped label (2026-08-05 audit). E2E_FORCE_RELAY makes ICE
# relay-only, so RTP hairpins phone -> Mac TURN -> phone across the bridge.
DART_BIN="$(dirname "$FLUTTER_BIN")/dart"
if [ ! -x "$DART_BIN" ]; then
  DART_BIN=$(sudo -u "$RUN_AS" zsh -lc 'command -v dart' 2>/dev/null || true)
fi
[ -n "$DART_BIN" ] || die "dart not found next to $FLUTTER_BIN"

# STALE-RIG SWEEP (2026-08-06). An aborted earlier run can orphan its relay
# (dart, behnam) and its turnserver (root) with the ports still bound; the
# next run then dies on "Address already in use" / a foreign turnserver.
# These two process shapes are started ONLY by this script, so killing any
# pre-existing instance is safe and makes the runner self-healing.
pkill -f 'signaling_server.dart --port' 2>/dev/null || true
pkill -f 'datagram_relay.dart' 2>/dev/null || true
pkill -x turnserver 2>/dev/null || true
sleep 1

sudo -u "$RUN_AS" bash -c \
  "cd '$REPO/server/signaling_server' && exec '$DART_BIN' run bin/signaling_server.dart --port $RELAY_PORT --address $SELF" \
  >"$TMP/relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 60); do
  grep -q 'listening on' "$TMP/relay.log" 2>/dev/null && break
  kill -0 "$RELAY_PID" 2>/dev/null || break
  sleep 0.5
done
grep -q 'listening on' "$TMP/relay.log" 2>/dev/null \
  || die "signalling relay did not start (see $TMP/relay.log)"
# The relay MUST be reachable on the bridge address, not just loopback —
# a loopback-only bind produced calls that signalled locally and died in
# `reconnecting` with 31 UDP packets per direction (2026-08-06 root cause).
nc -z -G 3 "$SELF" "$RELAY_PORT" >/dev/null 2>&1 \
  || die "signalling relay not reachable at $SELF:$RELAY_PORT (loopback-only bind?)"

# Datagram relay for the fountain video lane (RIG_GUIDE §0.3): UDP dumb
# pipe, phone -> Mac -> phone, shaped by the default per-peer UDP rule and
# counted by the same evidence filter. Port 3737 ON PURPOSE — coturn binds
# listening-port+1 (3479) as its alt-port, and a foreign socket on our
# port would swallow the lane silently. The readiness grep alone cannot
# see that class, so the relay answers a sub-16-byte liveness echo and the
# rig refuses to run until the echo comes back from $SELF (same doctrine
# as the STUN probe: never trust a bind, prove the path).
DGRAM_PORT="${T2_DGRAM_PORT:-3737}"
sudo -u "$RUN_AS" bash -c \
  "cd '$REPO/server/signaling_server' && exec '$DART_BIN' run bin/datagram_relay.dart --port $DGRAM_PORT" \
  >"$TMP/dgram_relay.log" 2>&1 &
DGRAM_PID=$!
for _ in $(seq 1 60); do
  grep -q 'datagram relay listening on' "$TMP/dgram_relay.log" 2>/dev/null && break
  kill -0 "$DGRAM_PID" 2>/dev/null || break
  sleep 0.5
done
grep -q 'datagram relay listening on' "$TMP/dgram_relay.log" 2>/dev/null \
  || die "datagram relay did not start (see $TMP/dgram_relay.log)"
python3 - "$SELF" "$DGRAM_PORT" <<'DGRAM_PROBE' || die "datagram relay echo probe failed on $SELF:$DGRAM_PORT (foreign socket on the port?)"
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b'\x42', (sys.argv[1], int(sys.argv[2])))
assert s.recvfrom(64)[0] == b'\x42'
print('dgram-probe ok')
DGRAM_PROBE

# TURN: NATIVE coturn, not Docker. Docker Desktop's userland UDP proxy
# rewrites peer source addresses (breaking TURN permissions silently), and a
# containerised relay-ip advertises an address the phone cannot reach.
command -v turnserver >/dev/null \
  || die "coturn not installed — brew install coturn"
{
  echo "listening-port=$TURN_PORT"
  echo "min-port=49160"
  echo "max-port=49200"
  echo "lt-cred-mech"
  echo "user=dev:devpass"
  echo "realm=local.dev"
  echo "listening-ip=$SELF"
  echo "relay-ip=$SELF"
  echo "fingerprint"
  echo "no-cli"
  echo "verbose"
} >"$TMP/turn.conf"
turnserver -c "$TMP/turn.conf" --log-file="$TMP/turn.log" --simple-log \
  >/dev/null 2>&1 &
TURN_PID=$!
sleep 1
kill -0 "$TURN_PID" 2>/dev/null || die "turnserver did not start ($TMP/turn.log)"
python3 "$HERE/stun_probe.py" "$SELF" "$TURN_PORT" \
  || die "TURN server not answering STUN on $SELF:$TURN_PORT"
# Binding Success does not prove the server will ALLOCATE — probe the real
# long-term-credential Allocate path too (2026-08-06).
python3 "$HERE/turn_probe.py" "$SELF" "$TURN_PORT" dev devpass \
  || die "TURN server refused an Allocate on $SELF:$TURN_PORT (see $TMP/turn.log)"
echo "rig up    relay pid $RELAY_PID, turnserver pid $TURN_PID (STUN + Allocate verified)"

# Optional extra defines from the caller (diagnostics), e.g.
#   T2_EXTRA_DEFINES="--dart-define=E2E_MEDIA_MODE=noLocalAudio"
DEFINES="${T2_EXTRA_DEFINES:+$T2_EXTRA_DEFINES }--dart-define=E2E_RELAY_URI=wss://$SELF:$RELAY_PORT/"
DEFINES="$DEFINES --dart-define=E2E_TURN_URI=turn:$SELF:$TURN_PORT"
DEFINES="$DEFINES --dart-define=E2E_TURN_USER=dev"
DEFINES="$DEFINES --dart-define=E2E_TURN_PASS=devpass"
DEFINES="$DEFINES --dart-define=E2E_FORCE_RELAY=true"
DEFINES="$DEFINES --dart-define=E2E_DGRAM_PORT=$DGRAM_PORT"

# PER-PROFILE PROBE COUNT — more packets, never a lower floor.
#
# The SLA test's ack-probe loop is also its call-hold window. On the >= 900 ms
# delay profiles, 20 probes ended the call after ~41 s of media and only
# 256/347 packets crossed bridge100 (measured 2026-08-05, latency profile) —
# under the 300-per-direction floor. The floor is the guard against the rig
# certifying itself (a 322-"packet" PASS made of DNS and debugger chatter has
# already happened) so it does NOT move; the test moves more packets instead.
# 40 probes ≈ doubles the media window: expected ~512/694 on latency.
#
# BUDGET (re-derive before raising past 40 probes, a 300 s connect budget,
# or the stress windows): worst case per probe is the test's 15 s probe
# timeout + 250 ms spacing, so
#   connect max(CONNECT_BUDGET, STRESS_CONNECT) + 5 s + N x 15.25 s
#   + restart send + recovery wait (30 s + 60 s on the SLA tier;
#     STRESS_RECOVERY_S each on the stress tier)
# N=40 @ connect <=455 (app budget cap 450 / loss60 stress bound ~432 with
# the measured TCP-stall term) with stress recovery windows ~447 and the
# test's DERIVED probe ceilings (ack timeout capped 30 s, spacing capped
# 3 s on narrow links) → 455 + 40x33 + 447 + 447 = 2669 s, inside the
# test's 50-min @Timeout, and this script's watchdog default is 3200 s
# (T2_TEST_TIMEOUT) to leave slack for build/install/teardown. Bigger N,
# budget, windows, or probe ceilings break the @Timeout first — raise all
# of them in the same change or not at all. Measured reality is far kinder
# (~2 s/probe at RTT 1800 ms), but the budget is stated at the ceiling.
#
# T2_ACK_PROBES overrides ALL profiles uniformly (a debug lever); the
# per-profile default applies only when it is unset. Fast profiles stay at 20
# on purpose — `clean` and `normal` already clear the floor several times over
# and a blanket increase would slow every row for nothing.
if [ -n "${T2_ACK_PROBES:-}" ]; then
  ACK_PROBES="$T2_ACK_PROBES"
else
  case "$PROFILE" in
    latency|extreme|loss60) ACK_PROBES=40 ;;   # delay >= 900 ms each way, or loss >= 0.60
    *)                      ACK_PROBES=20 ;;
  esac
fi
echo "probes    $ACK_PROBES (E2E_ACK_PROBES)"
DEFINES="$DEFINES --dart-define=E2E_ACK_PROBES=$ACK_PROBES"

# PER-PROFILE CONNECT BUDGET — the window the call gets to reach `connected`.
#
# Measured 2026-08-06 (loss60 and extreme runs): both rows died with the
# anonymous outer TimeoutException at sla_thresholds_test.dart:154 after
# exactly connectBudget+5 = 125 s, while the pcap showed ICE/TURN negotiation
# STILL LIVE past the abort (allocate successes and retransmitting checks
# minutes later). The call was not terminally failed — the 120 s default
# budget cut it down mid-negotiation, so no media ever flowed and the
# per-direction packet floor (>= 300 each way) correctly stamped
# INVALID/UNROUTED. Remedy: more time on the profiles whose physics demand
# it (60% per-direction loss ≈ 16% round-trip success; ~2000 ms RTT), never
# a lower floor. The app's reconnect policy reads the same define so its
# ICE-restart recovery window matches this budget.
#
# 2026-08-06: the two hand-picked numbers (300 on the hostile rows, 120 on the
# rest) are now DERIVED from the same shaping this script already applies, by
# the same code the app runs — `AdaptiveConnectionBudget` in call_core, asked
# through `bin/connect_budget.dart`. Two hand-maintained constants in two
# languages drift; one formula with two callers cannot. If dart is unreachable
# the old constants remain as the fallback, because a missing toolchain must
# not silently shrink a budget.
budget_conditions() {
  # rtt_ms is TWICE the one-way delay this script configures; loss is the
  # per-direction rate; bandwidth is in bits/s, empty when unshaped.
  case "$1" in
    normal)    echo "80   0.00 " ;;
    latency)   echo "1800 0.00 " ;;
    bandwidth) echo "4    0.00 32000" ;;
    narrow)    echo "4    0.00 16000" ;;
    loss10)    echo "4    0.10 " ;;
    loss60)    echo "4    0.60 " ;;
    extreme)   echo "2000 0.15 16000" ;;
    clean)     echo "4    0.00 " ;;
    *)         return 1 ;;
  esac
}

# The app now derives its per-operation timeouts (e2e_support.dart) from the
# SAME conditions via `AdaptiveConnectionBudget`, so the shaping is passed
# through verbatim. Unknown profile -> no defines -> the app's pristine
# defaults, where every timeout getter floors at the old 15s/20s constants.
_rtt="" _loss="" _bw=""
read -r _rtt _loss _bw <<<"$(budget_conditions "$PROFILE")" || true
if [ -n "$_rtt" ]; then
  DEFINES="$DEFINES --dart-define=E2E_RTT_MS=$_rtt"
  DEFINES="$DEFINES --dart-define=E2E_LOSS=$_loss"
  [ -n "$_bw" ] && DEFINES="$DEFINES --dart-define=E2E_BANDWIDTH_BPS=$_bw"
  echo "conditions rtt ${_rtt}ms loss $_loss bw ${_bw:-unshaped}"
fi

if [ -n "${T2_CONNECT_BUDGET_S:-}" ]; then
  CONNECT_BUDGET_S="$T2_CONNECT_BUDGET_S"
else
  CONNECT_BUDGET_S=""
  if [ -n "$_rtt" ]; then
    _args=(--rtt-ms="$_rtt" --loss="$_loss")
    [ -n "$_bw" ] && _args+=(--bandwidth-bps="$_bw")
    CONNECT_BUDGET_S=$(cd "$REPO/packages/call_core" && \
      dart run bin/connect_budget.dart -- "${_args[@]}" --field=budget_s \
      2>/dev/null) || CONNECT_BUDGET_S=""
  fi
  if ! [[ "$CONNECT_BUDGET_S" =~ ^[0-9]+$ ]]; then
    echo "WARN: could not derive the connect budget; using the old constants" >&2
    case "$PROFILE" in
      loss60|extreme) CONNECT_BUDGET_S=300 ;;
      *)              CONNECT_BUDGET_S=120 ;;
    esac
  fi
fi
echo "connect budget ${CONNECT_BUDGET_S}s (E2E_CONNECT_BUDGET_S)"
DEFINES="$DEFINES --dart-define=E2E_CONNECT_BUDGET_S=$CONNECT_BUDGET_S"

# --- STRESS tier: independent survival bounds (user decision, 2026-08-06) --
#
# loss60 and extreme are judged by SURVIVAL (connect, media both ways,
# recover from a break), not by latency percentiles. The time bound below is
# DELIBERATE DOUBLE-ENTRY: it is computed here, from the shaper's own
# rtt/loss/bandwidth (budget_conditions above), with its own constants — it
# must NEVER read the app's configured budget (E2E_CONNECT_BUDGET_S /
# maxElapsed), because a criterion inherited from the thing under test
# passes by construction. Resemblance to the app's model is expected (both
# describe the same physics: doubling retransmit timers under loss,
# serialization on a narrow pipe); agreement is required only to within
# +/-50% per attempt — measured today: loss60 68.3 s vs the app's 77.0 s
# (-11%), extreme 63.9 s vs 44.8 s (+43%). Larger divergence means one of
# the two derivations is wrong; settle it against a packet capture.
#
# Derivation (hand-checkable; own first-principles constants):
#   s   = (1-p)^2                  round-trip success, i.i.d. loss p per dir
#   rt  = 12 * rtt / s             12 wire round trips (TCP 1, TLS 2, WS 1,
#                                  offer 1, answer 1, TURN alloc+perm 2,
#                                  ICE check 1, DTLS 2, first media 1),
#                                  each an expected 1/s tries
#   lad = 2^min(ceil(1/s),6) - 1   1 s doubling retransmit ladder (RFC 6347),
#                                  capped at 6 doublings
#   ser = 32 KiB * 8 / bw / s      handshake bytes on the narrow pipe
#   one = rt + lad + ser + 5       + fixed engine/OS cost
#   connect  = ceil(3 * one)       survival tolerates 3 full attempts
#   recovery = connect + 15        + detection allowance
#
# The two E2E_STRESS_* defines size the test's MEASUREMENT WINDOWS only —
# judging happens in the verdict section below, never in the app.
STRESS_TIER=0
STRESS_CONNECT_S=""
STRESS_RECOVERY_S=""
case "$PROFILE" in loss60|extreme) STRESS_TIER=1 ;; esac
if [ "$STRESS_TIER" = 1 ]; then
  read -r STRESS_CONNECT_S STRESS_RECOVERY_S <<<"$(python3 -c "
import math
rtt = $_rtt / 1000.0
p = $_loss
bw = ${_bw:-0}
s = (1.0 - p) ** 2
rt = 12 * rtt / s
lad = (2 ** min(math.ceil(1.0 / s), 6)) - 1
# Serialized TCP-signaling stalls (measured 2026-08-07, loss60 timeline:
# join 43s, one offer send > 141s while a single ladder promised 63s):
# a connect is 3 signaling deliveries in series, each stalling a full
# ladder with probability ~p. Same physics as the app's model, derived
# here independently as this tier requires.
stall = lad * 2 * p
ser = (32 * 1024 * 8 / bw / s) if bw > 0 else 0.0
c = math.ceil(3 * (rt + lad + stall + ser + 5.0))
print(c, c + 15)
" 2>/dev/null)" || true
  if ! [[ "$STRESS_CONNECT_S" =~ ^[0-9]+$ && "$STRESS_RECOVERY_S" =~ ^[0-9]+$ ]]; then
    echo "WARN: could not derive stress bounds; using the precomputed constants" >&2
    case "$PROFILE" in
      loss60)  STRESS_CONNECT_S=205; STRESS_RECOVERY_S=220 ;;
      extreme) STRESS_CONNECT_S=192; STRESS_RECOVERY_S=207 ;;
    esac
  fi
  echo "tier      STRESS: survive + connect<=${STRESS_CONNECT_S}s recover<=${STRESS_RECOVERY_S}s (independent of the app budget)"
  DEFINES="$DEFINES --dart-define=E2E_STRESS_CONNECT_S=$STRESS_CONNECT_S"
  DEFINES="$DEFINES --dart-define=E2E_STRESS_RECOVERY_S=$STRESS_RECOVERY_S"
else
  echo "tier      SLA (global thresholds apply)"
fi

# START FROM A KNOWN DEVICE STATE, NOT AN INHERITED ONE.
#
# `h2_matrix.sh` kills stale debuggers between rows and has since the attach
# failures of 2026-08-03. A bare `h2_run.sh` did not — so the runner was clean
# only when something else had cleaned up for it. On 2026-08-03T22:57 a run was
# interrupted with Ctrl-C, leaving `lldb-rpc-server` alive and the app holding a
# half-open peer connection; the next run inherited both and died in
# `setLocalDescription` after 15 s, and was recorded as a threshold FAIL on an
# unimpaired link.
#
# The guarantee belongs in the runner, because the runner is what people invoke
# directly. A precondition that only holds when you came through the wrapper is
# not a precondition.
killall -9 lldb debugserver lldb-rpc-server >/dev/null 2>&1 || true
sleep 1

# PRE-WARM THE LAUNCH PATH (2026-08-06 — root cause of four NODISC rows).
#
# Measured tonight, with the four failing logs and one instrumented verbose
# run: every "Dart VM Service was not discovered" row followed this chain:
#   1. `devicectl device process launch --start-stopped` was DENIED by
#      SpringBoard ("invalid code signature, inadequate entitlements or its
#      profile has not been explicitly trusted" — a transient device-side
#      denial: the identical command succeeded 16/16 times when replayed).
#   2. flutter silently fell back to launching through Xcode automation
#      (marker: "You may be prompted to give access to control Xcode").
#   3. In that fallback there is no lldb console for ProtocolDiscovery, so
#      discovery is mDNS-only — and `dns-sd -B _dartVmService._tcp` proves
#      mDNS does NOT cross bridge100 on this rig (25 s browse, zero answers,
#      app running). The run was doomed to burn ~614 s and report NODISC.
# All seven historical logs split perfectly on the marker: 4/4 failures have
# it, 3/3 successes do not.
#
# The launch denial always cleared on an immediate retry, so absorb it HERE
# with a cheap probe (~3 s/try) instead of paying a ~90 s flutter cycle to
# find out. The probe launches the already-installed app and terminates it;
# if nothing is installed yet, it skips (the matrix preflight guarantees an
# attended first install).
BUNDLE_ID="${T2_BUNDLE_ID:-com.tlscodes.referenceApp}"
prewarm="skipped (no device id)"
if [ -n "$DEVICE" ] && command -v xcrun >/dev/null; then
  prewarm="never launched"
  for try in 1 2 3 4 5; do
    pw_out=$(sudo -u "$RUN_AS" xcrun devicectl device process launch \
      --terminate-existing --device "$DEVICE" "$BUNDLE_ID" 2>&1)
    if printf '%s' "$pw_out" | grep -q 'Launched application'; then
      prewarm="ok (try $try)"
      pw_pid=$(sudo -u "$RUN_AS" xcrun devicectl device info processes \
        --device "$DEVICE" 2>/dev/null | awk '/referenceApp/{print $1; exit}')
      [ -n "$pw_pid" ] && sudo -u "$RUN_AS" xcrun devicectl device process \
        terminate --device "$DEVICE" --pid "$pw_pid" >/dev/null 2>&1 || true
      break
    fi
    if printf '%s' "$pw_out" | grep -q 'no app record'; then
      prewarm="skipped (app not installed yet — first run installs it)"
      break
    fi
    prewarm="DENIED $try times"
    sleep 2
  done
  echo "prewarm   $prewarm"
  case "$prewarm" in "DENIED"*)
    echo "WARNING: device refused to launch $BUNDLE_ID five times — the test" >&2
    echo "         will likely fall back to Xcode automation and fail to" >&2
    echo "         attach. Check the phone is awake and trusts this Mac." >&2
  esac
fi

# A HARD DEADLINE, NOT A HOPE. Every stall so far had a 30 s in-app timeout or
# a tooling error to end it, but an UNKNOWN prompt (a future permission, a trust
# dialog, a frozen lldb) ends nothing — it holds the matrix hostage overnight.
# There is no timeout(1) on stock macOS, so this is a watchdog: the test runs in
# the background and is killed if it outlives T2_TEST_TIMEOUT seconds (default
# 3200 — worst-case budget on the stress tier with the TCP-stall term:
# connect window max(app budget 450, loss60 stress bound ~432) + 5 +
# 40 probes at the derived ceilings (ack timeout capped 30 s + spacing
# capped 3 s, see the test's own budget dartdoc) + two stress recovery
# windows ~447 s each = ~2670 s, plus slack for build/install/teardown; a
# healthy profile finishes well inside that, the ceiling exists for the run
# where nothing answers). The EXIT trap still runs, so teardown and the
# packet evidence survive the kill.
TEST_TIMEOUT="${T2_TEST_TIMEOUT:-3200}"

# FAIL FAST ON THE DOOMED FALLBACK, RETRY BOUNDED AND LOGGED (2026-08-06).
#
# When the devicectl+lldb launch is denied (see the pre-warm note above),
# flutter prints "You may be prompted to give access to control Xcode" and
# continues into a path that CANNOT discover the VM service on this rig
# (mDNS-only discovery, and mDNS does not cross bridge100). Waiting for it to
# time out costs ~614 s per occurrence and produced four NODISC rows. The
# marker is printed the moment the fallback is chosen, so the watchdog kills
# the attempt right there and retries — a bounded, visible retry of a proven
# transient, not a silent slot machine: the count travels in the row's note.
ATTACH_RETRIES="${T2_ATTACH_RETRIES:-2}"
FALLBACK_MARKER='give access to control Xcode'
attach_retries_used=0
attempt=0
while :; do
  attempt=$(( attempt + 1 ))
  : >"$LOG"
  # shellcheck disable=SC2086
  sudo -u "$RUN_AS" bash -c \
    "cd '$APP' && '$FLUTTER_BIN' test --no-pub --no-uninstall $DEFINES '$TEST' $DEV_ARG" >"$LOG" 2>&1 &
  TEST_PID=$!
  fallback_hit=0
  deadline=$(( $(date +%s) + TEST_TIMEOUT ))
  while kill -0 "$TEST_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "WATCHDOG: test exceeded ${TEST_TIMEOUT}s — killing it" >&2
      echo "WATCHDOG: test exceeded ${TEST_TIMEOUT}s and was killed" >>"$LOG"
      pkill -9 -P "$TEST_PID" 2>/dev/null || true
      kill -9 "$TEST_PID" 2>/dev/null || true
      break
    fi
    if grep -q "$FALLBACK_MARKER" "$LOG" 2>/dev/null; then
      fallback_hit=1
      echo "ATTACH: devicectl launch was denied; flutter fell back to Xcode" >&2
      echo "        automation, which cannot discover the VM service on this" >&2
      echo "        rig (mDNS-only, and mDNS does not cross $IFACE)." >&2
      echo "        Killing the attempt instead of burning ~10 min." >&2
      pkill -9 -P "$TEST_PID" 2>/dev/null || true
      kill -9 "$TEST_PID" 2>/dev/null || true
      break
    fi
    sleep 2
  done
  wait "$TEST_PID" 2>/dev/null
  test_rc=$?
  if [ "$fallback_hit" = 1 ] && [ "$attempt" -le "$ATTACH_RETRIES" ]; then
    attach_retries_used=$attempt
    echo "ATTACH: retry $attempt of $ATTACH_RETRIES after settling" >&2
    killall -9 lldb debugserver lldb-rpc-server >/dev/null 2>&1 || true
    # The stopped/half-launched app instance would otherwise be inherited.
    pw_pid=$(sudo -u "$RUN_AS" xcrun devicectl device info processes \
      --device "$DEVICE" 2>/dev/null | awk '/referenceApp/{print $1; exit}')
    [ -n "$pw_pid" ] && sudo -u "$RUN_AS" xcrun devicectl device process \
      terminate --device "$DEVICE" --pid "$pw_pid" >/dev/null 2>&1 || true
    sleep 3
    continue
  fi
  break
done
ended=$(python3 -c 'import time; print(int(time.time()*1000))')
elapsed=$(( ended - started ))

kill "$TCPDUMP_PID" 2>/dev/null || true
TCPDUMP_PID=""
kill "${SIGDUMP_PID:-}" 2>/dev/null || true
SIGDUMP_PID=""
sleep 0.3

# SUSTAINED, BIDIRECTIONAL, SHAPE-ELIGIBLE — or the row is not a row.
#
# The floors are derived, not guessed: relay-forced Opus at 20 ms ptime is
# ~50 pkt/s per direction and the SLA test holds the call >= 20 s, so a real
# run puts >= 1000 packets per direction on the bridge. The worst legitimate
# case is the loss60 profile (i.i.d. 60% drop): ~40% arrives, still ~400 per
# direction. Floors of 600 total / 300 per direction pass that honestly while
# sitting 3.5x above the measured tooling chatter (172) that fooled the old
# `>= 10` guard. Direction is counted with the peer ANCHORED and the dots
# escaped, so 192.168.3.2 cannot match 192.168.3.20.
PEER_RE=$(printf '%s' "$PEER" | sed 's/\./\\./g')
pkts_from=$(grep -cE "IP ${PEER_RE}\." "$PCAP" 2>/dev/null || true)
pkts_to=$(grep -cE "> ${PEER_RE}\." "$PCAP" 2>/dev/null || true)
packets=$(( ${pkts_from:-0} + ${pkts_to:-0} ))
# Floors are PER-TEST: the 600/300 numbers are derived from the SLA test's
# audio-hold profile (~50 pkt/s for >= 20 s). The messaging test holds the
# call only as long as its deliveries need — measured 2026-08-07 on clean:
# 525 packets for a fully-delivered, byte-verified run, stamped INVALID by
# the audio floor. Its evidence requirement is that the ARTIFACTS crossed
# the shaped path: 72 KB of SCTP chunks + acks + the short audio hold is
# >= 150/direction on every legitimate run, still ~3x above the strict
# filter's tooling chatter. Env overrides win as before.
case "$TEST" in
  *messaging*) _floor_total=300; _floor_dir=150 ;;
  *)           _floor_total=600; _floor_dir=300 ;;
esac
MIN_TOTAL="${T2_MIN_PACKETS:-$_floor_total}"
MIN_DIR="${T2_MIN_PACKETS_PER_DIR:-$_floor_dir}"
routed_ok=0
if [ "$packets" -ge "$MIN_TOTAL" ] \
   && [ "${pkts_from:-0}" -ge "$MIN_DIR" ] \
   && [ "${pkts_to:-0}" -ge "$MIN_DIR" ]; then
  routed_ok=1
fi

# --- verdict --------------------------------------------------------------
# Order matters: an unrouted run is INVALID no matter what the test said,
# because a green test that never crossed the impairment proves nothing about
# the impairment.
# A verdict that means two different things is not a verdict. On 2026-08-03 two
# runs were scored FAIL when `flutter` could not attach to the device at all —
# the app never ran, so the row said nothing about the app while looking exactly
# like a threshold failure. Tooling failures now have their own class, their own
# exit code, and their own remedy.
tooling_failure() {
  # "Failed to load .*integration_test" = the harness never attached the
  # test isolate (2026-08-08: a bandwidth video row was misstamped
  # INVALID/UNROUTED when the VM-Service connect timed out before one test
  # line ran — that is rig noise, not routing evidence).
  grep -qiE \
    'mDNS query .* failed|Dart VM Service was not discovered|give access to control Xcode|No tests ran|No devices are connected|No supported devices found|Unable to Verify|version solving failed|Failed to load .*integration_test' \
    "$LOG"
}

# Lines that contain the word "error" and carry no information about this run.
# Flutter's Swift Package Manager deprecation banner is printed on EVERY build
# and says "This will become an error in a future version of Flutter" — so a
# naive `grep -i error | head -2` captured the banner, then the box-drawing line
# of the exception header, and recorded that pair as the explanation. The row in
# `h2_results.tsv` for 2026-08-03T22:57 reads:
#
#   "This will become an error in a future version of Flutter. Please contact
#    the plugin maintainers ... ══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞══"
#
# which names neither the exception nor where it was thrown. A note that
# explains nothing is worse than an empty one: it occupies the space where the
# explanation should be, so nobody opens the log.
_NOISE='will become an error in a future version|Swift Package Manager adoption|^═+$|^╞|^╡|Consider enabling the flag chain-stack-traces'

# The exception itself, if there is one; otherwise the first real error lines.
failure_note() {
  local body
  # The block a Flutter test prints is:
  #   ══╡ EXCEPTION CAUGHT BY ... ╞══
  #   The following <Type> was thrown <when>:
  #   <message>
  #   ...
  # The line AFTER the banner is the one that names the failure, so start there.
  body=$(awk '/EXCEPTION CAUGHT BY/{found=1; next} found&&n<6{print; n++}' "$LOG" \
         | grep -vE "$_NOISE" | grep -v '^[[:space:]]*$' | head -4)
  if [ -z "$body" ]; then
    body=$(grep -EI 'Exception|Error:|Failed assertion|timed out|Test failed' "$LOG" \
           | grep -vE "$_NOISE" | head -3)
  fi
  printf '%s' "$body" | tr '\n' ' ' | cut -c1-400
}

# The full exception, saved where the operator can actually open it.
save_exception() {
  [ -s "$LOG" ] || return 0
  grep -q 'EXCEPTION CAUGHT BY' "$LOG" || return 0
  awk '/EXCEPTION CAUGHT BY/{found=1} found{print}' "$LOG" | head -60 >"$EXC"
}

# THE NATIVE STACK NEVER CAME UP — A THIRD THING, NOT A THRESHOLD RESULT.
#
# On 2026-08-03T22:57 a `clean` run was scored FAIL with:
#
#   TimeoutException after 0:00:15: Timed out while attempting to set local
#   answer  ... receiver never reached connected; last phase=reconnecting
#
# That message comes from flutter_webrtc's `setLocalDescription` — the NATIVE
# WebRTC layer on the phone — not from any Dart code in this repo. The app was
# installed, the test started, and the platform peer connection wedged. Scoring
# it FAIL says "the app missed its thresholds on an unimpaired link", which is
# a claim about the product that the run did not make.
#
# It is the same defect this file already names for attach failures: a verdict
# that means two different things is not a verdict. The known trigger is stale
# device state — an interrupted run leaves the app and a debugserver alive, and
# the next run inherits a half-open peer connection. `h2_matrix.sh` already
# kills those between rows for exactly this reason; a bare `h2_run.sh` did not,
# which is why this surfaced when the runner was invoked directly.
platform_stall() {
  grep -qiE \
    'Timed out while attempting to set (local|remote) (offer|answer|description)|Failed to create PeerConnection|Unable to create RTCPeerConnection|getUserMedia.*(failed|denied)|AVAudioSession.*error' \
    "$LOG"
}

# A MEASUREMENT THAT WAS ACTUALLY TAKEN IS NOT DISCARDED BY A LATER MESSAGE.
#
# Three rows in h2_results.tsv were scored as failures while carrying COMPLETE
# measurements:
#
#   23:48  TOOLING/NO-ATTACH  connect 2572  p50 13  p95 15  loss 0  rec 30  alive True
#   00:00  PLATFORM-STALL     connect  699  p50 12  p95 14  loss 0  rec 31  alive True
#
# The test ran, measured, printed SLA_SUMMARY, and reported the call still
# connected at the end. Then `flutter` lost the VM Service while collecting
# logs, the string "Dart VM Service was not discovered" landed in the log, and
# the classifier — which greps the WHOLE log and runs before anything else —
# relabelled a finished experiment as a rig failure and threw its numbers away.
#
# The ordering was the defect. Those checks exist to catch runs where the app
# NEVER RAN; asking them first means they also catch runs where the app ran
# fine and the tooling coughed on the way out. A complete SLA_SUMMARY with
# stillConnectedAtEnd and no probe errors is proof the app ran, and no message
# printed afterwards can retract it.
#
# The guard is deliberately strict — complete summary, zero probe errors, still
# connected — because the opposite error, calling a broken run a pass, is the
# one this whole harness exists to prevent.
sla_line=$(grep -o 'SLA_SUMMARY {.*}' "$LOG" | tail -1 | sed 's/^SLA_SUMMARY //')

# THE APP'S OWN TERMINAL EVIDENCE OUTRANKS POST-HOC CLASSIFIERS (2026-08-06).
# Two rows tonight proved the gap: `extreme` died with the app's own
# "connect budget ... exhausted" line after 491 s of real ICE against the
# shaped path — and was stamped INVALID/UNROUTED because the dying call put
# 268/357 packets under the floor; `loss60` died the same way, then flutter
# coughed "Dart VM Service was not discovered" while collecting logs — and
# was stamped TOOLING/NO-ATTACH. Both rows carried a definite app-level
# measurement ("the call never connected under this impairment") and both
# were relabelled as rig noise, which pointed the next fix at the wrong
# layer. The rule the PASS side already has (a measurement actually taken is
# not discarded by a later message) applies to failures too: when the app
# demonstrably RAN and reported its outcome, tooling greps and the packet
# floor add caveats — they never overwrite. The floor still gates every
# PASS, unchanged: a green test that never crossed the impairment proves
# nothing about the impairment.
msg_line=$(grep -o 'MSG_SUMMARY {.*}' "$LOG" | tail -1 | sed 's/^MSG_SUMMARY //')
vid_line=$(grep -o 'VID_SUMMARY {.*}' "$LOG" | tail -1 | sed 's/^VID_SUMMARY //')
app_ran=0
if [ -n "$sla_line" ] || [ -n "$msg_line" ] || [ -n "$vid_line" ] \
   || grep -qE 'connect budget \([0-9]+s \+ 5s\) exhausted' "$LOG"; then
  app_ran=1
fi
measured_ok=0
if [ -n "$sla_line" ]; then
  measured_ok=$(printf '%s' "$sla_line" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
need = ('connectMs','ackRttP50Ms','ackRttP95Ms','recoveryConnectedMs')
complete = all(d.get(k) is not None for k in need)
clean = d.get('ackProbeErrors', 0) == 0 and d.get('stillConnectedAtEnd') is True
print(1 if complete and clean else 0)
" 2>/dev/null || echo 0)
fi

# --- tier judgment (user decision, 2026-08-06) ----------------------------
# loss60/extreme rows are judged by the STRESS criterion: survival within
# the INDEPENDENT bounds computed above. Latency percentiles (p50/p95, ack
# loss) are measured and recorded but deliberately NOT judged there — they
# are physics at those impairments, not product quality. All other profiles
# keep the SLA criterion unchanged. An exit code alone can never pass a
# stress row: without SLA_SUMMARY numbers the independent bounds have
# nothing to judge, and a test whose internal waits derive from the app's
# own budget would pass by construction.
stress_note=""
if [ -n "$vid_line" ]; then
  # VIDEO GATE (2026-08-08): survival criterion on every tier — the clip
  # delivered and hash-verified. Sizes/times/throughput recorded as the
  # measured baseline (proxy sizing is documented in the test header).
  if [ "${STRESS_TIER:-0}" = 1 ]; then
    pass_verdict="PASS/STRESS"; fail_verdict="FAIL/STRESS"
  else
    pass_verdict="PASS"; fail_verdict="FAIL"
  fi
  vid_eval=$(printf '%s' "$vid_line" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); print('VID_SUMMARY unparseable'); raise SystemExit
ok = d.get('sha256Ok') is True and d.get('videoMs') is not None
nums = '%sB in %sms (%s kbps, %s/%s chunks resumed)' % (
    d.get('sizeBytes'), d.get('videoMs'), d.get('throughputKbps'),
    d.get('resumedChunks'), d.get('totalChunks'))
print(1 if ok else 0)
print(('delivered sha-verified: ' + nums) if ok else ('not delivered/verified: ' + nums))
" 2>/dev/null)
  criterion_ok=$(printf '%s\n' "$vid_eval" | head -1)
  stress_note=$(printf '%s\n' "$vid_eval" | tail -1)
  stress_note="criterion=video-survival(delivered + sha256; times recorded as baseline); $stress_note"
elif [ -n "$msg_line" ]; then
  # MESSAGING GATE (2026-08-07): the criterion on EVERY tier is survival —
  # all texts delivered, both attachments byte-for-byte intact. Delivery
  # TIMES are recorded in the note as the measured baseline; independent
  # per-tier time bounds get derived once a baseline EXISTS, never invented
  # before it (a bound with no measurement behind it is theatre, and a
  # bound read from the app's own config passes by construction).
  if [ "${STRESS_TIER:-0}" = 1 ]; then
    pass_verdict="PASS/STRESS"; fail_verdict="FAIL/STRESS"
  else
    pass_verdict="PASS"; fail_verdict="FAIL"
  fi
  msg_eval=$(printf '%s' "$msg_line" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); print('MSG_SUMMARY unparseable'); raise SystemExit
why = []
if d.get('textDelivered') != d.get('textCount'): why.append(
    'text %s/%s' % (d.get('textDelivered'), d.get('textCount')))
if d.get('photoIntact') is not True: why.append('photo not intact')
if d.get('voiceIntact') is not True: why.append('voice not intact')
nums = 'text p50 %sms max %sms; photo %sB in %sms; voice %sB in %sms' % (
    d.get('textP50Ms'), d.get('textMaxMs'), d.get('photoBytes'),
    d.get('photoMs'), d.get('voiceBytes'), d.get('voiceMs'))
if why:
    print(0); print('; '.join(why) + '; ' + nums)
else:
    print(1); print('delivered intact: ' + nums)
" 2>/dev/null)
  criterion_ok=$(printf '%s\n' "$msg_eval" | head -1)
  stress_note=$(printf '%s\n' "$msg_eval" | tail -1)
  stress_note="criterion=msg-survival(all delivered + intact; times recorded as baseline); $stress_note"
elif [ "${STRESS_TIER:-0}" = 1 ]; then
  pass_verdict="PASS/STRESS"; fail_verdict="FAIL/STRESS"
  criterion_ok=0
  if [ -n "$sla_line" ]; then
    stress_eval=$(printf '%s' "$sla_line" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); print('SLA_SUMMARY unparseable'); raise SystemExit
cb = ${STRESS_CONNECT_S:-0} * 1000
rb = ${STRESS_RECOVERY_S:-0} * 1000
c = d.get('connectMs'); r = d.get('recoveryConnectedMs')
why = []
if d.get('bothConnected') is not True: why.append('never connected')
if c is None: why.append('connectMs missing')
elif c > cb: why.append('connect %dms > %dms' % (c, cb))
if r is None: why.append('recovery never reached connected')
elif r > rb: why.append('recovery %dms > %dms' % (r, rb))
if d.get('stillConnectedAtEnd') is not True: why.append('not alive at end')
if d.get('ackProbeErrors', 0) != 0: why.append('probe errors: build defect')
if why:
    print(0); print('; '.join(why))
else:
    print(1); print('survived: connect %dms, recovered %dms, alive' % (c, r))
" 2>/dev/null)
    criterion_ok=$(printf '%s\n' "$stress_eval" | head -1)
    stress_note=$(printf '%s\n' "$stress_eval" | tail -1)
  else
    stress_note="no SLA_SUMMARY: the stress criterion needs measured connect/recovery (run sla_thresholds_test.dart)"
  fi
else
  pass_verdict="PASS"; fail_verdict="FAIL"
  criterion_ok="${measured_ok:-0}"
fi

if [ "${criterion_ok:-0}" = "1" ] && [ "$routed_ok" = 1 ]; then
  verdict="$pass_verdict"
  if [ "$test_rc" -eq 0 ]; then
    note="$(grep -Eo 'All tests passed!|[0-9]+ tests? passed' "$LOG" | tail -1)"
    note="${note:-measured}"
  else
    # The numbers stand; the caveat travels with them rather than replacing
    # them. Anyone reading the table can see both.
    note="measured completely; tooling failed AFTER the test: $(failure_note)"
  fi
  [ -n "$stress_note" ] && note="$stress_note; $note"
elif grep -q 'E2E_PREREQ microphone' "$LOG"; then
  # THE PROMPT WAS ON SCREEN AND NOBODY WAS THERE. There is no supported way
  # to pre-grant the microphone on a physical iOS device (simctl privacy is
  # simulator-only), so the first run after an INSTALL (or a delete, or a
  # signing-identity change that forced a delete) prompts once. That is a
  # named human prerequisite of the install, not a threshold result and not a
  # generic timeout — its own verdict, its own exit code, its own remedy.
  verdict="PREREQ/MIC-GRANT"
  note="microphone permission prompt pending on this install — grant it once on the device, then re-run"
elif [ "$app_ran" != 1 ] && tooling_failure; then
  verdict="TOOLING/NO-ATTACH"
  if grep -q "$FALLBACK_MARKER" "$LOG" 2>/dev/null; then
    note="devicectl launch denied -> Xcode fallback (mDNS-only, dead on $IFACE); killed early after ${attach_retries_used} retr$( [ "$attach_retries_used" = 1 ] && echo y || echo ies)"
  else
    note="$(grep -oiE 'mDNS query[^.]*\.|Dart VM Service was not discovered|No tests ran|Unable to Verify|version solving failed' "$LOG" | head -1)"
    note="${note:-flutter could not attach to the device}"
  fi
elif [ "$app_ran" != 1 ] && platform_stall; then
  verdict="PLATFORM-STALL"
  note="native media stack did not come up: $(grep -oiE 'Timed out while attempting to set [a-z ]*|Failed to create PeerConnection|Unable to create RTCPeerConnection' "$LOG" | head -1)"
elif [ "$routed_ok" != 1 ] && { [ "$app_ran" != 1 ] || [ "$test_rc" -eq 0 ]; }; then
  # No app evidence, or a GREEN exit without routed media (self-certification
  # is exactly what the floor exists to refuse) — the row is invalid.
  verdict="INVALID/UNROUTED"
  note="only ${pkts_from:-0} from-peer / ${pkts_to:-0} to-peer shape-eligible UDP packets crossed $IFACE (need >= $MIN_DIR each, >= $MIN_TOTAL total) — the test did not use the shaped path"
elif [ -z "$msg_line" ] && [ -z "$vid_line" ] && [ "${STRESS_TIER:-0}" != 1 ] && [ "$test_rc" -eq 0 ]; then
  # A messaging/video row never passes on exit code alone — its criterion
  # line above is the only gate that can green it.
  verdict="PASS"
  note="$(grep -Eo 'All tests passed!|[0-9]+ tests? passed' "$LOG" | tail -1)"
else
  verdict="$fail_verdict"
  note="$(failure_note)"
  [ -n "$stress_note" ] && note="$stress_note${note:+; $note}"
  # Caveats travel with the verdict; they never replace it (mirror of the
  # PASS branch's "tooling failed AFTER the test" rule).
  if [ "$routed_ok" != 1 ]; then
    note="$note [media under floor: ${pkts_from:-0} from-peer / ${pkts_to:-0} to-peer vs $MIN_DIR/$MIN_DIR — consistent with a call that never connected; routing evidence absent, so an unshaped-path cause is not excluded]"
  fi
  if tooling_failure; then
    note="$note [tooling also coughed in this log: $(grep -oiE 'Dart VM Service was not discovered|mDNS query[^.]*\.' "$LOG" | head -1) — after the app's own outcome, not instead of it]"
  fi
fi

# A retried attach is part of the row's history, not a secret: the verdict
# stands on its own evidence, but the reader can see the rig stuttered.
if [ "${attach_retries_used:-0}" -gt 0 ] && [ "$verdict" != "TOOLING/NO-ATTACH" ]; then
  note="$note [attach retried ${attach_retries_used}x: devicectl launch transiently denied]"
fi

# Every JUDGED row names the criterion that judged it (tier label, user
# decision 2026-08-06). Rig verdicts (INVALID/TOOLING/STALL/PREREQ) are
# judged by neither criterion and stay unlabeled on purpose.
case "$verdict" in
  # Messaging/video rows carry their own criterion label inside stress_note.
  PASS|FAIL)
    [ -z "$msg_line" ] && [ -z "$vid_line" ] && note="criterion=sla; $note" ;;
  PASS/STRESS|FAIL/STRESS)
    [ -z "$msg_line" ] && [ -z "$vid_line" ] && note="criterion=stress(connect<=${STRESS_CONNECT_S}s,recovery<=${STRESS_RECOVERY_S}s,independent); $note" ;;
esac

# --- the app's own measurements ------------------------------------------
# `sla_thresholds_test.dart` prints one machine-readable line. Without it a row
# only says whether the call connected; with it the row carries the numbers the
# thresholds are actually about. Absent for other tests, and absent is fine —
# it is reported as "-" rather than invented.
SLA=$(grep -o 'SLA_SUMMARY {.*}' "$LOG" | tail -1 | sed 's/^SLA_SUMMARY //')
sla_field() {
  [ -n "$SLA" ] || { echo "-"; return; }
  printf '%s' "$SLA" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    v = d.get('$1')
    print('-' if v is None else v)
except Exception:
    print('-')
"
}
connect_ms=$(sla_field connectMs)
ack_p50=$(sla_field ackRttP50Ms)
ack_p95=$(sla_field ackRttP95Ms)
ack_loss=$(sla_field ackRttLossPct)
recovery_ms=$(sla_field recoveryConnectedMs)
alive_end=$(sla_field stillConnectedAtEnd)

echo
printf 'profile\tverdict\trtt_ms\tloss_pct\tpackets\telapsed_ms\tconnect_ms\tack_p50\tack_p95\tack_loss\trecovery_ms\talive\tnote\n'
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$PROFILE" "$verdict" "${probe_rtt:-?}" "${probe_loss}" "${packets}" "$elapsed" \
  "$connect_ms" "$ack_p50" "$ack_p95" "$ack_loss" "$recovery_ms" "$alive_end" "$note"

# Append to a durable file so a table is accumulated rather than re-derived.
if [ ! -f "$RESULTS" ]; then
  printf 'date\tprofile\ttest\tverdict\trtt_ms\tloss_pct\tpackets\telapsed_ms\tconnect_ms\tack_p50\tack_p95\tack_loss\trecovery_ms\talive\tnote\n' >"$RESULTS"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%FT%TZ)" "$PROFILE" "$(basename "$TEST")" "$verdict" \
  "${probe_rtt:-?}" "${probe_loss}" "${packets}" "$elapsed" \
  "$connect_ms" "$ack_p50" "$ack_p95" "$ack_loss" "$recovery_ms" "$alive_end" \
  "$note" >>"$RESULTS"
chown "$RUN_AS" "$RESULTS" 2>/dev/null || true

# Federate the corpus (v4 pillar 6): every run's harvest lands in the durable
# replay corpus the moment the row lands in the tsv — no run evaporates with
# /tmp anymore, and the TREND per-second series rides along. Never fatal: a
# harvest hiccup must not turn a measured row into a failed run.
python3 "$HERE/build_replay_corpus.py" --one "$TMP" || true
chown -R "$RUN_AS" "$HERE/replay_corpus" 2>/dev/null || true

save_exception
# Everything the operator might open, owned by the operator.
chown -R "$RUN_AS" "$TMP" 2>/dev/null || true
chmod -R a+r "$TMP" 2>/dev/null || true

echo
echo "log     $LOG"
echo "pcap    $PCAP"
[ -s "$EXC" ] && echo "EXCEPTION $EXC"
echo "results $RESULTS"

# Print the exception inline as well. A path is a promise that someone will
# follow it; the first twenty lines cost nothing and are read every time.
if [ -s "$EXC" ]; then
  echo
  echo "--- exception (first 20 lines; full text in $EXC) ---"
  head -20 "$EXC"
  echo "-----------------------------------------------------"
fi

# INVALID is not a pass and not a normal failure: it means the rig, not the
# app, produced the outcome. Give it its own exit code so a driver script
# cannot mistake it for either.
case "$verdict" in
  PASS|PASS/STRESS) exit 0 ;;
  FAIL|FAIL/STRESS) exit 1 ;;
  # 8 = the tooling never reached the app; 9 = the app ran off the shaped path.
  # Both describe the rig, and neither is a threshold result — a driver that
  # cannot tell them from a real FAIL will publish a table of fiction.
  # 6 = a named human prerequisite: the TCC microphone prompt was pending and
  # unattended. Not retryable by a machine — a person grants it once per
  # install, then every later run is unattended.
  PREREQ/MIC-GRANT)
    echo
    echo "PREREQUISITE: iOS is showing the microphone permission prompt for" >&2
    echo "this install and nobody answered it. Unlock the phone, run once" >&2
    echo "attended (or open the app) and tap Allow — the grant persists for" >&2
    echo "this install of com.tlscodes.referenceApp. Then re-run unattended." >&2
    echo "Note: deleting the app, or a signing change that forces a delete," >&2
    echo "wipes the grant and this prerequisite returns once." >&2
    exit 6 ;;
  TOOLING/NO-ATTACH)
    echo
    echo "This row says nothing about the app: flutter could not attach." >&2
    echo "Root cause measured 2026-08-06 on this rig: the device transiently" >&2
    echo "denies 'devicectl device process launch' (SpringBoard Security), so" >&2
    echo "flutter falls back to Xcode automation whose mDNS-only discovery is" >&2
    echo "dead across bridge100. The runner pre-warms the launch and retries" >&2
    echo "the fallback (T2_ATTACH_RETRIES, default 2). If it STILL failed:" >&2
    echo "  · phone locked/asleep, or it no longer trusts this Mac" >&2
    echo "  · the debug channel was shaped: check T2_SHAPE_ALL is not 1" >&2
    echo "  · a stale debugger: killall -9 lldb debugserver lldb-rpc-server" >&2
    exit 8 ;;
  # 7 = the app ran and the NATIVE media stack never came up. Retryable, and
  # the retry is worth taking before anyone reads it as a product result.
  PLATFORM-STALL)
    echo
    echo "This row says nothing about the thresholds: the native WebRTC stack" >&2
    echo "never reached connected. The app ran; the platform did not." >&2
    echo "Usual causes, in order:" >&2
    echo "  · an interrupted previous run left the app and a half-open peer" >&2
    echo "    connection alive on the device. Kill the app on the phone and" >&2
    echo "    run: killall -9 lldb debugserver lldb-rpc-server" >&2
    echo "  · the phone locked mid-run; iOS suspends the media session." >&2
    echo "  · microphone permission was revoked or never granted." >&2
    echo "Re-run once before treating this as a finding." >&2
    exit 7 ;;
  *) exit 9 ;;
esac
