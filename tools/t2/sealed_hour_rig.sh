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
#   4. The phone app is launched once more to read its receipts, and closed.
#
# "Off" is not a process list: the phone app is off when it was terminated
# and its journal then stays still for longer than two of its thirty-second
# heartbeats (tools/t2/sealed_rig_lib.sh). The phone app is launched and
# terminated with devicectl and is never reinstalled or removed here. The
# phone's side of the record is its own event journal, copied off the device.
# The script ends with both apps off, and says so.
#
# Usage: tools/t2/sealed_hour_rig.sh <output dir>      (about 105 minutes)
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
. tools/t2/sealed_rig_lib.sh
APP=apps/reference_app
BOX="$HOME/Library/Containers/$MAC_BUNDLE_ID/Data/tmp/sealed_rig"
GAP_MIN=${SEALED_GAP_MIN:-46}
REPLY_AFTER=60
mkdir -p "$BOX"
LOG="$OUT/script.log"

pull_journal() {
  phone_journal "$OUT/phone_events_$1.jsonl"
  say_ "phone journal ($1): $(wc -l <"$OUT/phone_events_$1.jsonl" 2>/dev/null | tr -d ' ') lines"
}
mac_app() { # mode, log
  ( cd "$APP" && flutter test integration_test/sealed_offline_rig_test.dart -d macos \
      --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$BOX" \
      --dart-define=SEALED_RIG_WAIT_S=300 \
      --dart-define=SEALED_RIG_REPLY_AFTER_S="$REPLY_AFTER" >"$2" 2>&1 )
}

# --- fixtures ---------------------------------------------------------------
cp tools/dossier/evidence/journey/media/bandwidth-photo.jpg "$BOX/photo.jpg"
say -o "$BOX/voice.aiff" "This is a thirty second voice note for the sealed letter test. $(printf 'One two three four five six seven eight nine ten. %.0s' 1 2 3 4 5 6 7 8 9 10)"
ffmpeg -v error -y -stream_loop 4 -i "$BOX/voice.aiff" -t 30 -ac 1 -ar 16000 -c:a aac -b:a 16k "$BOX/voice.m4a"
ffmpeg -v error -y -i tools/dossier/evidence/journey/media/bandwidth-video.mp4 -t 10 -c copy "$BOX/video.mp4"
rm -f "$BOX/voice.aiff"

# --- 1. the Mac writes and is closed ----------------------------------------
say_ "1: the Mac app writes; the phone app is off"
phone_off "$OUT" || say_ "1 continues, but the phone app was NOT confirmed off"
mac_app write "$OUT/mac_write.log"; say_ "1: Mac app exited rc=$?"
MAC_LEFT=$(date +%s)
say_ "1: Mac app not running: $(mac_not_running)"
grep -a "SEALED_RIG" "$OUT/mac_write.log" | tee -a "$LOG" >/dev/null

# --- 2. GAP later, the phone alone -------------------------------------------
say_ "waiting $GAP_MIN minutes with both apps off"
wait_until $((MAC_LEFT + GAP_MIN * 60))
say_ "2: switching the phone app on; Mac app not running: $(mac_not_running)"
phone_on || say_ "2: the phone app could NOT be launched"
sleep $((REPLY_AFTER + 90))
pull_journal 2_phone_opened_and_wrote
phone_off "$OUT" || say_ "2: the phone app was NOT confirmed off"
PHONE_LEFT=$(date +%s)

# --- 3. GAP later, the Mac alone ----------------------------------------------
say_ "waiting $GAP_MIN minutes with both apps off"
wait_until $((PHONE_LEFT + GAP_MIN * 60))
pull_journal 3_phone_before_mac
say_ "3: starting the Mac app; the phone app has been off since $(date -u -r "$PHONE_LEFT" +%H:%M:%SZ)"
mac_app receive "$OUT/mac_receive.log"; say_ "3: Mac app exited rc=$?"
say_ "3: Mac app not running: $(mac_not_running)"

# --- 4. the phone reads its receipts, and everything is closed ----------------
say_ "4: the phone app once more, for its receipts"
phone_on || say_ "4: the phone app could NOT be launched"
sleep 75
pull_journal 4_phone_final
phone_off "$OUT" && PHONE_END=yes || PHONE_END=NO

grep -a "SEALED_RIG" "$OUT/mac_write.log" "$OUT/mac_receive.log" 2>/dev/null | sed 's/^[^:]*://' >"$OUT/mac_lines.txt"
python3 tools/t2/sealed_hour_verdict.py "$OUT" "$GAP_MIN" | tee "$OUT/verdict.txt" | tee -a "$LOG" >/dev/null
say_ "done — phone app off: $PHONE_END; Mac app not running: $(mac_not_running)"
tail -n 1 "$OUT/verdict.txt"
