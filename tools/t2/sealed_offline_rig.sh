#!/bin/bash
# Sealed letters with one side OFF at the moment of sending, both directions,
# on the same Mac and the same phone. No call, no hub, no shaping: the letters
# wait on the pair shelf of the border relay and are found by looking.
#
#   A. Mac -> phone. The phone app is terminated. The Mac app writes a text, a
#      photo, a 30 s voice note and a short video; the script waits until the
#      app has said where each letter is, then launches the phone app.
#   B. Phone -> Mac. The Mac app is not running. The phone writes on its own,
#      asked to by the Mac's text a minute earlier; later the Mac app is started.
#
# "Off" is not a process list: the phone app is off when it was terminated
# and its journal then stays still for longer than two of its thirty-second
# heartbeats (tools/t2/sealed_rig_lib.sh). The phone app is launched and
# terminated with devicectl and is never reinstalled or removed here. The
# phone's side of the record is its own event journal, copied off the device.
# The script ends with both apps off, and says so.
#
# Usage: tools/t2/sealed_offline_rig.sh <output dir>
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
. tools/t2/sealed_rig_lib.sh
APP=apps/reference_app
BOX="$HOME/Library/Containers/$MAC_BUNDLE_ID/Data/tmp/sealed_rig"
WAIT=${SEALED_RIG_WAIT_S:-240}
# The Mac's text asks the rig peer to write back this many seconds after it
# opens it; by then the Mac app has exited. (A launch-time switch was tried
# first and never reached the app: the phone's journal showed no write.)
REPLY_AFTER=${SEALED_RIG_REPLY_AFTER_S:-60}
mkdir -p "$BOX"
rm -f "$BOX/peer_may_start"
LOG="$OUT/script.log"

pull_journal() { # tag
  phone_journal "$OUT/phone_events_$1.jsonl"
  say_ "phone journal ($1): $(wc -l <"$OUT/phone_events_$1.jsonl" 2>/dev/null | tr -d ' ') lines"
}
mac_app() { # mode, log
  ( cd "$APP" && flutter test integration_test/sealed_offline_rig_test.dart -d macos \
      --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$BOX" \
      --dart-define=SEALED_RIG_WAIT_S="$WAIT" \
      --dart-define=SEALED_RIG_REPLY_AFTER_S="$REPLY_AFTER" >"$2" 2>&1 )
}

# --- fixtures: real files of each kind, inside the app's sandbox -------------
cp tools/dossier/evidence/journey/media/bandwidth-photo.jpg "$BOX/photo.jpg"
say -o "$BOX/voice.aiff" "This is a thirty second voice note for the sealed letter test. $(printf 'One two three four five six seven eight nine ten. %.0s' 1 2 3 4 5 6 7 8 9 10)"
ffmpeg -v error -y -stream_loop 4 -i "$BOX/voice.aiff" -t 30 -ac 1 -ar 16000 -c:a aac -b:a 16k "$BOX/voice.m4a"
ffmpeg -v error -y -i tools/dossier/evidence/journey/media/bandwidth-video.mp4 -t 10 -c copy "$BOX/video.mp4"
rm -f "$BOX/voice.aiff"
for f in photo.jpg voice.m4a video.mp4; do
  say_ "fixture $f $(wc -c <"$BOX/$f" | tr -d ' ') B $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BOX/$f" 2>/dev/null | cut -c1-5)s"
done

# --- A. Mac -> phone, phone off ---------------------------------------------
say_ "A: Mac writes while the phone app is off"
phone_off "$OUT" || say_ "A continues, but the phone app was NOT confirmed off"
mac_app send "$OUT/mac_send.log" &
MAC_PID=$!
for _ in $(seq 1 360); do
  [ -f "$BOX/peer_may_start" ] && break
  kill -0 "$MAC_PID" 2>/dev/null || break
  sleep 2
done
if [ -f "$BOX/peer_may_start" ]; then
  say_ "A: the Mac app has said where its letters are; switching the phone on"
  phone_on || say_ "A: the phone app could NOT be launched"
else
  say_ "A: the Mac app never reached its queue report"
fi
wait "$MAC_PID"; say_ "A: Mac app exited rc=$?"
sleep 6
pull_journal A

# --- B. phone -> Mac, Mac app off -------------------------------------------
say_ "B: phone writes while the Mac app is not running: $(mac_not_running)"
say_ "B: the phone was asked to write ${REPLY_AFTER}s after opening the Mac's text; waiting for it to try with the Mac off"
sleep $((REPLY_AFTER + 45))
pull_journal B_before_mac
say_ "B: starting the Mac app"
mac_app receive "$OUT/mac_receive.log"; say_ "B: Mac app exited rc=$?"
sleep 8
pull_journal B_after_mac

# --- the end: everything this script opened is closed -------------------------
phone_off "$OUT" && PHONE_END=yes || PHONE_END=NO
grep -a "SEALED_RIG" "$OUT/mac_send.log" "$OUT/mac_receive.log" 2>/dev/null | sed 's/^[^:]*://' >"$OUT/mac_lines.txt"
say_ "done: $(grep -c 'row dir=' "$OUT/mac_lines.txt") Mac rows in $OUT/mac_lines.txt — phone app off: $PHONE_END; Mac app not running: $(mac_not_running)"
