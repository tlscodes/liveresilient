#!/bin/bash
# Section ب's line: the hour run (tools/t2/sealed_hour_rig.sh) with the phone's
# TCP to the relay cut the whole time, so every letter the phone writes or
# opens goes over the TXT lane's give gateway.
#
#   0. Narrow-lane fixtures: a photo, a 30 s voice note and a short video, each
#      small enough for one give request (the lane carries ~39 KB per request).
#   1. The give gateway on the bridge address, UDP 5300 (never 53), forwarding
#      to our own border relay; no relay is deployed, no public domain is used
#      (the zone is give.test).
#   2. The phone is whitelisted (tools/t2/net_shape.sh): it can reach only the
#      Mac, on UDP 5300 and the rig ports; TCP 443 to any other host is reset.
#   3. The hour run. The pf state is copied before and after it.
#   4. Teardown, then the tally: the hour verdict, and every relay request the
#      phone's journal says the lane carried.
#
# The phone app must have been installed with the lane compiled in:
#   SEALED_TXT_HOST=192.168.2.1 SEALED_TXT_DOMAIN=give.test tools/t2/journey_peer_install.sh
#
# Usage: tools/t2/sealed_txt_hour_rig.sh <output dir> [smoke]
#   smoke: steps 1-2, launch the phone app for 3 minutes, tally, tear down.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
MODE=${2:-hour}
. tools/t2/sealed_rig_lib.sh
LOG="$OUT/script.log"
SELF=192.168.2.1
PEER=${SEALED_TXT_PEER:-192.168.2.2}
DOMAIN=give.test
RELAY="https://voice-call-relay.tlscodes-com.workers.dev"
SHAPE=tools/t2/net_shape.sh

# --- 0. fixtures ---------------------------------------------------------------
FIX="$OUT/fixtures"
mkdir -p "$FIX"
ffmpeg -v error -y -i tools/dossier/evidence/journey/media/bandwidth-photo.jpg \
  -vf scale=480:-2 -q:v 10 "$FIX/photo.jpg"
say -o "$FIX/voice.aiff" "This is a thirty second voice note for the sealed letter test. $(printf 'One two three four five six seven eight nine ten. %.0s' 1 2 3 4 5 6 7 8 9 10)"
ffmpeg -v error -y -stream_loop 4 -i "$FIX/voice.aiff" -t 30 -ac 1 -ar 16000 -c:a libopus -b:a 6k -application voip -f mp4 "$FIX/voice.m4a"
ffmpeg -v error -y -i tools/dossier/evidence/journey/media/bandwidth-video.mp4 -t 4 -c copy "$FIX/video.mp4"
rm -f "$FIX/voice.aiff"
for f in photo.jpg voice.m4a video.mp4; do
  n=$(wc -c <"$FIX/$f" | tr -d ' ')
  say_ "fixture $f $n B $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FIX/$f" 2>/dev/null | cut -c1-5)s"
  [ "$n" -le 36000 ] || { say_ "fixture $f is too big for one give request"; exit 2; }
done

# --- 1. the give gateway -------------------------------------------------------
# The python.org build ships no CA file; without one every forward to the
# relay fails TLS verification and the gateway answers 502.
SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/cert.pem} \
python3 tools/t2/txt_give.py --domain "$DOMAIN" --host "$SELF" --port 5300 \
  --relay "$RELAY" >"$OUT/give.log" 2>&1 &
GIVE_PID=$!
sleep 2
kill -0 "$GIVE_PID" 2>/dev/null || { say_ "1: the give gateway did not start"; cat "$OUT/give.log" | tail -5; exit 2; }
say_ "1: give gateway pid $GIVE_PID on udp/$SELF:5300 zone $DOMAIN -> $RELAY"

cleanup() {
  sudo -n "$SHAPE" teardown >>"$OUT/pf.log" 2>&1 && say_ "pf: whitelist removed" || say_ "pf: teardown FAILED — run: sudo $SHAPE teardown"
  kill "$GIVE_PID" 2>/dev/null; wait "$GIVE_PID" 2>/dev/null
  say_ "give gateway stopped"
}
trap cleanup EXIT

# --- 1b. smoke: the Mac, unfiltered, puts one text in the pinned peer's box -------
RUN_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mac_smoke() { # mode, log
  ( cd apps/reference_app && flutter test integration_test/sealed_offline_rig_test.dart -d macos \
      --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$FIX" \
      --dart-define=SEALED_RIG_WAIT_S=300 --dart-define=SEALED_RIG_TEXT_ONLY=true \
      --dart-define=SEALED_RIG_PEER="${SEALED_RIG_PEER:-}" >"$2" 2>&1 )
}
if [ "$MODE" = smoke ]; then
  phone_off "$OUT" || say_ "smoke: phone app was NOT confirmed off"
  say_ "1b: the Mac app writes one text, no filter loaded yet"
  mac_smoke write "$OUT/mac_write.log"; say_ "1b: Mac app exited rc=$?"
  grep -a "SEALED_RIG" "$OUT/mac_write.log" | tee -a "$LOG" >/dev/null
fi

# --- 2. the phone may reach only the Mac ---------------------------------------
sudo -n "$SHAPE" whitelist "peer=$PEER,allow=$SELF,tcp=8765+4443,udp=5300" >"$OUT/pf.log" 2>&1 \
  || { say_ "2: whitelist did NOT load"; tail -5 "$OUT/pf.log"; exit 2; }
sudo -n "$SHAPE" status >"$OUT/pf_before.txt" 2>&1
say_ "2: phone $PEER whitelisted: $(grep -c 'return-rst' "$OUT/pf_before.txt") reset rule(s) for TCP 443 elsewhere"

# --- 3. the run ------------------------------------------------------------------
if [ "$MODE" = smoke ]; then
  # The phone opens the text over the lane and answers with its echo.
  # An idle phone is off the bridge; launched then, it bypasses the filter.
  tools/t2/sealed_bridge_wake.sh "$PEER" || { say_ "smoke: STOPPED — the phone is not on the bridge"; exit 3; }
  phone_on || say_ "smoke: the phone app could NOT be launched"
  sleep 180
  phone_journal "$OUT/phone_events_smoke.jsonl"
  phone_off "$OUT" || say_ "smoke: phone app was NOT confirmed off at the end"
  # The Mac (never filtered) reads the echo and the receipt.
  say_ "3: the Mac app reads the echo"
  mac_smoke receive "$OUT/mac_receive.log"; say_ "3: Mac app exited rc=$?"
  grep -a "SEALED_RIG" "$OUT/mac_receive.log" | tee -a "$LOG" >/dev/null
else
  SEALED_FIXTURES="$FIX" SEALED_BEFORE_PHONE="tools/t2/sealed_bridge_wake.sh $PEER" \
    tools/t2/sealed_hour_rig.sh "$OUT"
fi
sudo -n "$SHAPE" status >"$OUT/pf_after.txt" 2>&1
say_ "3: whitelist still loaded after the run: $(grep -c 'return-rst' "$OUT/pf_after.txt") reset rule(s)"

# --- 4. tally ----------------------------------------------------------------------
cat "$OUT"/phone_events_*.jsonl 2>/dev/null | grep -a '"relay_request"' | sort -u >"$OUT/phone_txt_requests.jsonl"
say_ "4: phone requests the lane carried: $(grep -c '"via":"txt"' "$OUT/phone_txt_requests.jsonl") (PUT $(grep -c '"method":"PUT"' "$OUT/phone_txt_requests.jsonl"), GET $(grep -c '"method":"GET"' "$OUT/phone_txt_requests.jsonl"))"
say_ "4: gateway forwarded: $(grep -c ' give PUT ' "$OUT/give.log") PUT, $(grep -c ' give GET ' "$OUT/give.log") GET; relay unreachable lines: $(grep -c 'relay unreachable' "$OUT/give.log")"
if [ "$MODE" = smoke ]; then
  python3 tools/t2/sealed_txt_smoke_verdict.py "$OUT" "$RUN_START" | tee "$OUT/verdict.txt" | tee -a "$LOG"
fi
[ -f "$OUT/verdict.txt" ] && tail -n 1 "$OUT/verdict.txt"
exit 0
