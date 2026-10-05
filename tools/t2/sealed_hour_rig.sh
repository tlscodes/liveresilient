#!/bin/bash
# The line: an app writes and is CLOSED; the other side is switched on at
# least 45 minutes later, with the writer still off; everything opens and
# the receipts come back. Both directions, same Mac and same phone, real
# clocks. No call, no hub: the letters wait on the pair shelf of the border
# relay.
#
#   1. Phone app off. Mac app writes a text, a photo, a 30 s voice note and a
#      short video, sees them onto the relay, and exits.
#   2. GAP minutes later the phone app is launched; the Mac app is not running.
#      It opens the four, shelves its receipts, and — asked to by the Mac's
#      text — writes its own four a minute later. Then it is terminated.
#   3. GAP minutes after the phone wrote, the Mac app is started; the phone app
#      is not running. It opens the phone's four and reads its own receipts.
#   4. The phone app is launched once more to read its receipts.
#
# "Off" means the app's process is not running. The phone app is launched and
# terminated with devicectl and is never reinstalled or removed here. The
# phone's side of the record is its own event journal, copied off the device.
#
# Usage: tools/t2/sealed_hour_rig.sh <output dir>      (about 100 minutes)
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:?output directory}
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
APP=apps/reference_app
BOX="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp/sealed_rig"
GAP_MIN=${SEALED_GAP_MIN:-46}
REPLY_AFTER=60
JOURNAL=Documents/voice_call_kit_intelligence/sealed_events.jsonl
mkdir -p "$OUT" "$BOX"
LOG="$OUT/script.log"

say_() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }
phone_pid() {
  xcrun devicectl device info processes --device "$PHONE" 2>/dev/null \
    | awk '/Runner\.app\/Runner/ {print $1; exit}'
}
phone_off() {
  local pid; pid=$(phone_pid)
  [ -n "$pid" ] && xcrun devicectl device process terminate --device "$PHONE" --pid "$pid" --kill >/dev/null 2>&1
  sleep 3
  pid=$(phone_pid)
  say_ "phone app off: $([ -z "$pid" ] && echo yes || echo "NO, still pid $pid")"
}
phone_on() { # a locked phone refuses a launch, so this keeps trying
  local out
  for try in $(seq 1 60); do
    out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1)
    if echo "$out" | grep -qi 'launched application'; then
      say_ "phone app on (try $try)"
      return 0
    fi
    say_ "phone app did not launch (try $try): $(echo "$out" | grep -i 'error\|locked\|denied' | head -1 | cut -c1-140)"
    sleep 30
  done
  return 1
}
mac_off() { pgrep -f "reference_app.app/Contents/MacOS/reference_app" >/dev/null && echo "NO, a Mac app process is running" || echo yes; }
pull_journal() {
  rm -f "$OUT/phone_events_$1.jsonl"
  xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$JOURNAL" \
    --destination "$OUT/phone_events_$1.jsonl" >/dev/null 2>&1
  say_ "phone journal ($1): $([ -s "$OUT/phone_events_$1.jsonl" ] && wc -l <"$OUT/phone_events_$1.jsonl" | tr -d ' ' || echo 0) lines"
}
mac_app() { # mode, log
  ( cd "$APP" && flutter test integration_test/sealed_offline_rig_test.dart -d macos \
      --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$BOX" \
      --dart-define=SEALED_RIG_WAIT_S=300 \
      --dart-define=SEALED_RIG_REPLY_AFTER_S="$REPLY_AFTER" >"$2" 2>&1 )
}
wait_until() { # epoch seconds
  while [ "$(date +%s)" -lt "$1" ]; do sleep 30; done
}

# --- fixtures ---------------------------------------------------------------
cp tools/dossier/evidence/journey/media/bandwidth-photo.jpg "$BOX/photo.jpg"
say -o "$BOX/voice.aiff" "This is a thirty second voice note for the sealed letter test. $(printf 'One two three four five six seven eight nine ten. %.0s' 1 2 3 4 5 6 7 8 9 10)"
ffmpeg -v error -y -stream_loop 4 -i "$BOX/voice.aiff" -t 30 -ac 1 -ar 16000 -c:a aac -b:a 16k "$BOX/voice.m4a"
ffmpeg -v error -y -i tools/dossier/evidence/journey/media/bandwidth-video.mp4 -t 10 -c copy "$BOX/video.mp4"
rm -f "$BOX/voice.aiff"

# --- 1. the Mac writes and is closed ----------------------------------------
say_ "1: the Mac app writes; the phone app is off"
phone_off
mac_app write "$OUT/mac_write.log"; say_ "1: Mac app exited rc=$?"
MAC_LEFT=$(date +%s)
say_ "1: Mac app off: $(mac_off)"
grep -a "SEALED_RIG" "$OUT/mac_write.log" | tee -a "$LOG" >/dev/null

# --- 2. GAP later, the phone alone -------------------------------------------
say_ "waiting $GAP_MIN minutes with both apps off"
wait_until $((MAC_LEFT + GAP_MIN * 60))
say_ "2: switching the phone app on; Mac app off: $(mac_off); phone app off before launch: $([ -z "$(phone_pid)" ] && echo yes || echo NO)"
phone_on || say_ "2: the phone app could NOT be launched"
sleep $((REPLY_AFTER + 90))
pull_journal 2_phone_opened_and_wrote
phone_off
PHONE_LEFT=$(date +%s)

# --- 3. GAP later, the Mac alone ----------------------------------------------
say_ "waiting $GAP_MIN minutes with both apps off"
wait_until $((PHONE_LEFT + GAP_MIN * 60))
say_ "3: starting the Mac app; phone app off: $([ -z "$(phone_pid)" ] && echo yes || echo NO)"
mac_app receive "$OUT/mac_receive.log"; say_ "3: Mac app exited rc=$?"
say_ "3: Mac app off: $(mac_off)"

# --- 4. the phone reads its receipts ------------------------------------------
say_ "4: the phone app once more, for its receipts"
phone_on || say_ "4: the phone app could NOT be launched"
sleep 75
pull_journal 4_phone_final

grep -a "SEALED_RIG" "$OUT/mac_write.log" "$OUT/mac_receive.log" 2>/dev/null | sed 's/^[^:]*://' >"$OUT/mac_lines.txt"
say_ "done"
