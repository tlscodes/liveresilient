#!/bin/bash
# Section ب over the TXT lane: the writer off for at least 45 minutes, receipts
# read back over the lane.
#
#   1. The Mac writes a #rig-reply-after=60 text (+ media) and exits.
#      both: GAP minutes later, with both apps off (gap 1),
#   2. the phone app is switched on, opens them, and a minute later writes a
#      text and sends back the photo, voice note and video. Then off.
#   3. GAP minutes later (gap 2) the Mac app (never filtered) opens the four
#      and reads the receipts of its own.
#   4. The phone app once more, for its receipts. Then off. Verdict.
#
# Without `both` the phone is switched on right after the Mac wrote, so only
# the phone -> Mac rows can pass (hour4). With `both` all eight rows are
# measured in this one run.
#
# The pf whitelist (phone may reach only the Mac: UDP 5300 + rig ports, TCP 443
# elsewhere reset) is loaded for EVERY phone-app session and removed while the
# phone app is confirmed off. Held for 45+ minutes it leaves the bridge without
# internet, and the idle iPhone then drops off the bridge for good (hour2,
# 2026-10-09: leg 4 found it gone, lease expired 3079 s earlier). Before each
# phone session the phone is woken onto the bridge UNFILTERED
# (tools/t2/sealed_bridge_wake.sh); a session that ends off the bridge, or with
# no lane traffic, stops the run.
#
# The writer's silence in each gap is shown instead of filtered: the phone's
# journal copied at the end of the gap must end on the same line as the copy
# taken when it was confirmed off, and the Mac app is looked for every 30 s.
# One line per gap goes to gaps.txt; a gap whose journal MOVED voids the run.
#
# Usage: SEALED_RIG_PEER=<phone install> tools/t2/sealed_txt_phone_rig.sh <output dir> [both]
#   (~60 min; both ~110 min)
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
MODE=${2:-phone}
. tools/t2/sealed_rig_lib.sh
LOG="$OUT/script.log"
SELF=192.168.2.1
PEER=${SEALED_TXT_PEER:-192.168.2.2}
DOMAIN=give.test
RELAY="https://voice-call-relay.tlscodes-com.workers.dev"
SHAPE=tools/t2/net_shape.sh
APP=apps/reference_app
BOX="$HOME/Library/Containers/$MAC_BUNDLE_ID/Data/tmp/sealed_rig"
GAP_MIN=${SEALED_GAP_MIN:-46}
# peer = section ب (the rig peer on the phone, sealed_offline_rig_test on the
# Mac); real = phase پ: lib/main.dart on BOTH devices, built with SEALED_RIG.
TARGET=${SEALED_TARGET:-peer}
RUN_START=$(date -u +%Y-%m-%dT%H:%M:%S)

# mac_app_run <write|receive>: the Mac half. With real it is the real main()
# driven through the chat panel (integration_test/sealed_real_app_test.dart).
mac_app_run() {
  local test=integration_test/sealed_offline_rig_test.dart extra=--dart-define=SEALED_RIG_TEXT_ONLY=false
  if [ "$TARGET" = real ]; then
    test=integration_test/sealed_real_app_test.dart
    extra=--dart-define=SEALED_RIG=true
  fi
  # full2: the app was built but its VM Service never attached ("Failed to
  # foreground app; open returned 1"), so nothing ran. Only that launch failure
  # is retried — up to 3 tries 20 s apart, each failed log kept as .tryN.
  local try rc
  for try in 1 2 3; do
    ( cd "$APP" && flutter test "$test" -d macos \
        --dart-define=SEALED_RIG_MODE="$1" --dart-define=SEALED_RIG_DIR="$BOX" \
        --dart-define=SEALED_RIG_WAIT_S=300 --dart-define=SEALED_RIG_PEER="${SEALED_RIG_PEER:-}" \
        --dart-define=SEALED_RIG_REPLY_AFTER_S=60 "$extra" \
        >"$OUT/mac_$1.log" 2>&1 )
    rc=$?
    grep -q "Connecting to the VM Service timed out" "$OUT/mac_$1.log" || return $rc
    grep -qa "SEALED_RIG" "$OUT/mac_$1.log" && return $rc
    cp "$OUT/mac_$1.log" "$OUT/mac_$1.log.try$try"
    say_ "mac $1: VM Service timed out (try $try); retrying in 20 s"
    pkill -f "Debug/reference_app.app/Contents/MacOS" 2>/dev/null
    sleep 20
  done
  return $rc
}

# real_install: the phone's Documents are backed up first; then (unless
# SEALED_REAL_INSTALL=0) lib/main.dart is built with SEALED_RIG and the TXT
# lane and installed OVER the rig build — same bundle id, never a delete. iOS
# refusing that install stops the run here. The rig box goes to
# Documents/sealed_rig, and the first launch runs unfiltered (developer-app
# verification needs the WAN), then the app is confirmed off.
real_install() {
  local bundle j
  say_ "real: backing up the phone app's Documents"
  # An idle phone can cut the copy ("connection was interrupted", full1
  # 2026-10-09); three tries, 20 s apart.
  for try in 1 2 3; do
    xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --source Documents --destination "$OUT/documents_backup" \
      >>"$OUT/backup.log" 2>&1
    j=$(find "$OUT/documents_backup" -name sealed_events.jsonl 2>/dev/null | head -1)
    [ -s "$j" ] && break
    say_ "real: Documents backup try $try failed: $(grep -m1 ERROR "$OUT/backup.log" | cut -c1-120)"
    sleep 20
  done
  [ -s "$j" ] || { say_ "real: STOPPED — the Documents backup holds no journal"; tail -3 "$OUT/backup.log"; exit 3; }
  say_ "real: Documents backed up ($(du -sh "$OUT/documents_backup" | cut -f1)), journal at ${j#$OUT/}"
  if [ "${SEALED_REAL_INSTALL:-1}" = 1 ]; then
    say_ "real: building lib/main.dart for the phone (profile, SEALED_RIG, TXT lane $SELF:5300 $DOMAIN)"
    ( cd "$APP" && flutter build ios --profile -t lib/main.dart --dart-define=SEALED_RIG=true \
        --dart-define=SEALED_TXT_HOST="$SELF" --dart-define=SEALED_TXT_DOMAIN="$DOMAIN" \
        --dart-define=SEALED_TXT_PORT=5300 >"$OUT/build_ios.log" 2>&1 ) \
      || { say_ "real: STOPPED — the iOS build failed"; tail -5 "$OUT/build_ios.log"; exit 3; }
    bundle=$(ls -td "$APP"/build/ios/iphoneos/Runner.app "$APP"/build/ios/Profile-iphoneos/Runner.app 2>/dev/null | head -1)
    say_ "real: installing ${bundle#$APP/} over the rig build (no delete)"
    xcrun devicectl device install app --device "$PHONE" "$bundle" >"$OUT/install.log" 2>&1 \
      || { say_ "real: STOPPED — iOS did not take the install over the rig build; nothing deleted"; tail -5 "$OUT/install.log"; exit 3; }
    say_ "real: installed, bundle id $BUNDLE_ID"
  else
    say_ "real: install skipped (SEALED_REAL_INSTALL=0); the phone keeps the real app"
  fi
  for f in photo.jpg voice.m4a video.mp4; do
    xcrun devicectl device copy to --device "$PHONE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --source "$BOX/$f" --destination "Documents/sealed_rig/$f" \
      >>"$OUT/fixtures.log" 2>&1 || { say_ "real: STOPPED — fixture $f not copied to the phone"; exit 3; }
  done
  say_ "real: rig box copied to the phone (Documents/sealed_rig)"
  LOG="$LOG" tools/t2/sealed_bridge_wake.sh "$PEER" || { say_ "real: STOPPED — phone not on the bridge"; exit 3; }
  phone_on || { say_ "real: STOPPED — the real app did not launch"; exit 3; }
  sleep 45
  phone_off "$OUT" || say_ "real: the phone app was NOT confirmed off after its first launch"
  phone_journal "$OUT/first_launch_journal.jsonl"
  say_ "real: first launch — rig_ready lines: $(grep -c '"rig_ready"' "$OUT/first_launch_journal.jsonl") ($(grep '"rig_ready"' "$OUT/first_launch_journal.jsonl" | tail -1 | cut -c1-160))"
  grep -q '"rig_ready"' "$OUT/first_launch_journal.jsonl" \
    || { say_ "real: STOPPED — the phone app ran without the rig flag or without its panel"; exit 3; }
}
mkdir -p "$BOX"
say_ "mode $MODE, gap $GAP_MIN min, target $TARGET"

SSL_CERT_FILE=${SSL_CERT_FILE:-/etc/ssl/cert.pem} \
python3 tools/t2/txt_give.py --domain "$DOMAIN" --host "$SELF" --port 5300 \
  --relay "$RELAY" >"$OUT/give.log" 2>&1 &
GIVE_PID=$!
sleep 2
kill -0 "$GIVE_PID" 2>/dev/null || { say_ "the give gateway did not start"; tail -5 "$OUT/give.log"; exit 2; }
say_ "give gateway pid $GIVE_PID on udp/$SELF:5300 zone $DOMAIN -> $RELAY"

pf_off() { sudo -n "$SHAPE" teardown >>"$OUT/pf.log" 2>&1; }
cleanup() {
  pf_off && say_ "pf: whitelist removed" || say_ "pf: teardown FAILED — run: sudo $SHAPE teardown"
  kill "$GIVE_PID" 2>/dev/null; wait "$GIVE_PID" 2>/dev/null
  say_ "give gateway stopped"
}
trap cleanup EXIT

lane_lines() { grep -cE ' give (PUT|GET) ' "$OUT/give.log"; }

# phone_session <name> <seconds>
# The journal is copied AFTER the app is confirmed off, so the copy is the
# state the following gap must keep.
phone_session() {
  local name=$1 secs=$2 before after rst
  pf_off
  LOG="$LOG" tools/t2/sealed_bridge_wake.sh "$PEER" || { say_ "$name: STOPPED — phone not on the bridge"; exit 3; }
  sudo -n "$SHAPE" whitelist "peer=$PEER,allow=$SELF,tcp=8765+4443,udp=5300" >>"$OUT/pf.log" 2>&1 \
    || { say_ "$name: STOPPED — whitelist did NOT load"; exit 3; }
  sudo -n "$SHAPE" status >"$OUT/pf_$name.txt" 2>&1
  rst=$(grep -c 'return-rst' "$OUT/pf_$name.txt")
  [ "$rst" -ge 1 ] || { say_ "$name: STOPPED — no reset rule loaded"; exit 3; }
  say_ "$name: whitelist loaded ($rst reset rule) — phone app on"
  before=$(lane_lines)
  phone_on || { say_ "$name: STOPPED — phone app did not launch"; exit 3; }
  sleep "$secs"
  phone_off "$OUT" || say_ "$name: the phone app was NOT confirmed off"
  phone_journal "$OUT/phone_events_$name.jsonl"
  say_ "phone journal ($name): $(wc -l <"$OUT/phone_events_$name.jsonl" 2>/dev/null | tr -d ' ') lines"
  after=$(lane_lines)
  say_ "$name: lane lines during the session: $((after - before)); arp at end: $(arp -n "$PEER" 2>&1 | tail -1 | cut -c1-60)"
  sudo -n "$SHAPE" status >"$OUT/pf_after_$name.txt" 2>&1
  pf_off && say_ "$name: whitelist removed (phone app off)"
  [ $((after - before)) -gt 0 ] || { say_ "$name: STOPPED — the lane carried nothing: the phone went around the filter"; exit 3; }
}

# gap_wait <name> <until epoch> <phone journal copied when it was confirmed off>
gap_wait() {
  local name=$1 until=$2 base=$3 mac=yes still end="$OUT/gap_journal_${1}_end.jsonl"
  say_ "$name: waiting until $(date -u -r "$until" +%H:%M:%SZ) with both apps off"
  while [ "$(date +%s)" -lt "$until" ]; do
    [ -n "$(mac_pids)" ] && mac="NO"
    sleep 30
  done
  [ -n "$(mac_pids)" ] && mac="NO"
  phone_journal "$end"
  if [ -s "$base" ] && [ -s "$end" ] && [ "$(last_line "$base")" = "$(last_line "$end")" ]; then
    still="no line"
  else
    still="MOVED"
  fi
  echo "$name: phone journal: $still (last $(last_line "$end" | cut -c8-34)); mac_not_running = $mac" \
    | tee -a "$OUT/gaps.txt" | tee -a "$LOG"
}

[ "$TARGET" = real ] && real_install
say_ "0: Mac app not running: $(mac_not_running)"
phone_off "$OUT" || say_ "0: phone app was NOT confirmed off"
[ "$MODE" = both ] && phone_journal "$OUT/gap_journal_gap1_start.jsonl"

# --- 1. the Mac writes ------------------------------------------------------------
# The trigger hour2 proved: the Mac (unfiltered, phone off) writes a text ending
# in #rig-reply-after=60 plus its media and exits; the phone opens them over the
# lane and writes its four a minute later. (SEALED_AUTOSEND=1 through devicectl
# launched the app but wrote nothing — hour3, 01:09Z.)
for f in photo.jpg voice.m4a video.mp4; do [ -s "$BOX/$f" ] || { say_ "1: STOPPED — fixture $BOX/$f missing"; exit 3; }; done
say_ "1: the Mac app writes the reply-after text; the phone app is off"
mac_app_run write
say_ "1: Mac app exited rc=$?; not running: $(mac_not_running)"
MAC_LEFT=$(date +%s)
grep -a "SEALED_RIG" "$OUT/mac_write.log" | tee -a "$LOG" >/dev/null
[ "$MODE" = both ] && gap_wait gap1 $((MAC_LEFT + GAP_MIN * 60)) "$OUT/gap_journal_gap1_start.jsonl"

# --- 2. the phone opens and writes ----------------------------------------------
phone_session 2_phone_opened_and_wrote 150
PHONE_LEFT=$(date +%s)

# --- 3. GAP later, the Mac alone ----------------------------------------------
gap_wait gap2 $((PHONE_LEFT + GAP_MIN * 60)) "$OUT/phone_events_2_phone_opened_and_wrote.jsonl"
phone_journal "$OUT/phone_events_3_phone_before_mac.jsonl"
say_ "3: starting the Mac app; the phone app has been off since $(date -u -r "$PHONE_LEFT" +%H:%M:%SZ)"
mac_app_run receive
say_ "3: Mac app exited rc=$?; not running: $(mac_not_running)"

# --- 4. the phone reads its receipts -------------------------------------------
phone_session 4_phone_final 75

# The Mac's own written lines feed the mac -> phone rows.
grep -a "SEALED_RIG" "$OUT/mac_write.log" "$OUT/mac_receive.log" 2>/dev/null | sed 's/^[^:]*://' >"$OUT/mac_lines.txt"
python3 tools/t2/sealed_hour_verdict.py "$OUT" "$GAP_MIN" >"$OUT/verdict.txt"
# The Mac journal of this run only (rig_screen lines: what its screen showed).
python3 -c 'import sys; [sys.stdout.write(l) for l in open(sys.argv[1], errors="replace") if l[7:26] >= sys.argv[2]]' \
  "$MAC_JOURNAL" "$RUN_START" >"$OUT/mac_journal.jsonl" 2>/dev/null
say_ "screen lines in the journals: mac $(grep -c '"rig_screen"' "$OUT/mac_journal.jsonl"), phone $(cat "$OUT"/phone_events_[24]_*.jsonl 2>/dev/null | grep -c '"rig_screen"')"
cat "$OUT"/phone_events_*.jsonl 2>/dev/null | grep -a '"relay_request"' | sort -u >"$OUT/phone_txt_requests.jsonl"
say_ "phone requests the lane carried: $(grep -c '"via":"txt"' "$OUT/phone_txt_requests.jsonl") (PUT $(grep -c '"method":"PUT"' "$OUT/phone_txt_requests.jsonl"), GET $(grep -c '"method":"GET"' "$OUT/phone_txt_requests.jsonl"))"
say_ "gateway forwarded: $(grep -c ' give PUT ' "$OUT/give.log") PUT, $(grep -c ' give GET ' "$OUT/give.log") GET; unreachable: $(grep -c 'relay unreachable' "$OUT/give.log")"
grep "mac -> phone\|phone -> mac\|phone journal between\|VERDICT" "$OUT/verdict.txt" | tee -a "$LOG"
grep -q MOVED "$OUT/gaps.txt" && say_ "RUN VOID: the phone journal moved in a gap"
exit 0
