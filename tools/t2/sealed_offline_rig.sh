#!/bin/bash
# Sealed letters with one side OFF at the moment of sending, both directions,
# on the same Mac and the same phone. No call, no hub, no shaping: the letters
# cross the two installs' mailboxes on the border relay over the internet.
#
#   A. Mac -> phone. The phone app is terminated. The Mac app writes a text, a
#      photo, a 30 s voice note and a short video; the script waits until the
#      app has said where each letter is, then launches the phone app.
#   B. Phone -> Mac. The Mac app is not running. The phone app is launched with
#      SEALED_AUTOSEND=1 and writes; later the Mac app is started.
#
# "Off" means the app's process is not running. The phone app is launched and
# terminated with devicectl and is never reinstalled or removed here. The
# phone's side of the record is its own event journal, copied off the device.
#
# Usage: tools/t2/sealed_offline_rig.sh <output dir>
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:?output directory}
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
APP=apps/reference_app
BOX="$HOME/Library/Containers/com.voicecallkit.referenceApp/Data/tmp/sealed_rig"
WAIT=${SEALED_RIG_WAIT_S:-240}
JOURNAL=Documents/voice_call_kit_intelligence/sealed_events.jsonl
mkdir -p "$OUT" "$BOX"
rm -f "$BOX/peer_may_start"

say_() { echo "[$(date -u +%H:%M:%S)] $*"; }

phone_pid() {
  xcrun devicectl device info processes --device "$PHONE" 2>/dev/null \
    | awk '/Runner\.app\/Runner/ {print $1; exit}'
}
phone_off() {
  local pid; pid=$(phone_pid)
  if [ -n "$pid" ]; then
    xcrun devicectl device process terminate --device "$PHONE" --pid "$pid" --kill >/dev/null 2>&1
    sleep 2
  fi
  pid=$(phone_pid)
  say_ "phone app off: $([ -z "$pid" ] && echo yes || echo "NO, still pid $pid")"
  [ -z "$pid" ]
}
phone_on() { # optional JSON of environment variables
  local out
  if [ -n "${1:-}" ]; then
    out=$(xcrun devicectl device process launch --terminate-existing -e "$1" --device "$PHONE" "$BUNDLE_ID" 2>&1)
  else
    out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1)
  fi
  say_ "phone app on: $(echo "$out" | grep -qi 'launched application' && echo yes || echo "? $(echo "$out" | tail -1)")"
}
pull_journal() { # tag
  rm -f "$OUT/phone_events_$1.jsonl"
  xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$JOURNAL" \
    --destination "$OUT/phone_events_$1.jsonl" >/dev/null 2>&1
  say_ "phone journal ($1): $([ -s "$OUT/phone_events_$1.jsonl" ] && wc -l <"$OUT/phone_events_$1.jsonl" | tr -d ' ' || echo 0) lines"
}
mac_app() { # mode, log
  ( cd "$APP" && flutter test integration_test/sealed_offline_rig_test.dart -d macos \
      --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$BOX" \
      --dart-define=SEALED_RIG_WAIT_S="$WAIT" >"$2" 2>&1 )
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
phone_off || say_ "A continues, but the phone was NOT off"
mac_app send "$OUT/mac_send.log" &
MAC_PID=$!
for _ in $(seq 1 360); do
  [ -f "$BOX/peer_may_start" ] && break
  kill -0 "$MAC_PID" 2>/dev/null || break
  sleep 2
done
if [ -f "$BOX/peer_may_start" ]; then
  say_ "A: the Mac app has said where its letters are; switching the phone on"
  phone_on
else
  say_ "A: the Mac app never reached its queue report"
fi
wait "$MAC_PID"; say_ "A: Mac app exited rc=$?"
sleep 6
pull_journal A

# --- B. phone -> Mac, Mac app off -------------------------------------------
say_ "B: phone writes while the Mac app is not running"
pgrep -f "reference_app.app/Contents/MacOS/reference_app" >/dev/null && say_ "B: a Mac app process is STILL running" || say_ "B: Mac app off: yes"
phone_off
phone_on '{"SEALED_AUTOSEND":"1"}'
sleep 50
pull_journal B_before_mac
say_ "B: starting the Mac app"
mac_app receive "$OUT/mac_receive.log"; say_ "B: Mac app exited rc=$?"
sleep 8
pull_journal B_after_mac

grep -a "SEALED_RIG" "$OUT/mac_send.log" "$OUT/mac_receive.log" 2>/dev/null | sed 's/^[^:]*://' >"$OUT/mac_lines.txt"
say_ "done: $(grep -c 'row dir=' "$OUT/mac_lines.txt") Mac rows in $OUT/mac_lines.txt"
