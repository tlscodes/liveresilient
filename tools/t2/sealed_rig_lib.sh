#!/bin/bash
# Shared by the sealed-letter rig scripts. Sourced, not run.
#
# "On" and "off" are read from the app's own journal, never from a process
# list. A running letter service writes a `start` line and then an `alive`
# line every thirty seconds; so an app is ON while those lines keep coming,
# and it is OFF only when it was told to stop AND its journal then stays
# still for longer than two beats. (A process list is not evidence: after a
# terminate iOS lists a new `Runner` within seconds that runs nothing.)
#
# Every script that sources this ends by closing what it opened: the phone
# app is terminated and its silence confirmed before the script returns.
PHONE=${JOURNEY_PHONE:-00008030-001215003AF2802E}
BUNDLE_ID=${JOURNEY_BUNDLE_ID:-com.tlscodes.referenceApp}
MAC_BUNDLE_ID=${JOURNEY_MAC_BUNDLE_ID:-com.voicecallkit.referenceApp}
JOURNAL=Documents/voice_call_kit_intelligence/sealed_events.jsonl
MAC_SUPPORT="$HOME/Library/Containers/$MAC_BUNDLE_ID/Data/Library/Application Support/voice_call_kit_intelligence"
MAC_JOURNAL="$MAC_SUPPORT/sealed_events.jsonl"
# Longer than two thirty-second beats.
BEAT_GAP_S=${SEALED_BEAT_GAP_S:-75}

say_() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG:-/dev/null}"; }

phone_pids() {
  xcrun devicectl device info processes --device "$PHONE" 2>/dev/null \
    | awk '/Runner\.app\/Runner/ {print $1}'
}

# Copies the phone app's journal to $1. Fails when it could not be copied.
phone_journal() {
  rm -f "$1"
  xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$JOURNAL" --destination "$1" >/dev/null 2>&1
  [ -s "$1" ]
}

last_line() { tail -n 1 "$1" 2>/dev/null; }

# A locked phone refuses a launch, so this keeps trying for half an hour.
phone_on() {
  local out try
  for try in $(seq 1 60); do
    out=$(xcrun devicectl device process launch --terminate-existing --device "$PHONE" "$BUNDLE_ID" 2>&1) || true
    if echo "$out" | grep -qi 'launched application'; then
      say_ "phone app launched (try $try)"
      return 0
    fi
    say_ "phone app did not launch (try $try): $(echo "$out" | grep -i 'error\|locked\|denied' | head -1 | cut -c1-140)"
    sleep 30
  done
  return 1
}

# Terminates the phone app and CONFIRMS it is off by its heartbeat stopping:
# the journal is copied, BEAT_GAP_S pass, it is copied again, and its last
# line must be the same line. $1 is a directory for the two copies.
phone_off() {
  local dir=${1:?directory} try pid a b
  mkdir -p "$dir"
  for try in 1 2 3; do
    for pid in $(phone_pids); do
      xcrun devicectl device process terminate --device "$PHONE" --pid "$pid" --kill >/dev/null 2>&1
    done
    sleep 3
    if ! phone_journal "$dir/.beat_a.jsonl"; then
      say_ "phone app off: UNCONFIRMED — its journal could not be read (try $try)"
      sleep 10
      continue
    fi
    a=$(last_line "$dir/.beat_a.jsonl")
    sleep "$BEAT_GAP_S"
    if ! phone_journal "$dir/.beat_b.jsonl"; then
      say_ "phone app off: UNCONFIRMED — its journal could not be read (try $try)"
      continue
    fi
    b=$(last_line "$dir/.beat_b.jsonl")
    if [ "$a" = "$b" ]; then
      say_ "phone app off: yes — no journal line in ${BEAT_GAP_S}s; last $(echo "$b" | cut -c1-90)"
      rm -f "$dir/.beat_a.jsonl" "$dir/.beat_b.jsonl"
      return 0
    fi
    say_ "phone app off: NO — its journal moved after it was terminated (try $try)"
  done
  return 1
}

mac_pids() { pgrep -f "reference_app.app/Contents/MacOS/reference_app"; }

# Stops any Mac app process and confirms it the same way: by the journal.
mac_off() {
  local pid a b
  for pid in $(mac_pids); do kill "$pid" 2>/dev/null; done
  sleep 2
  for pid in $(mac_pids); do kill -9 "$pid" 2>/dev/null; done
  a=$(last_line "$MAC_JOURNAL")
  sleep "$BEAT_GAP_S"
  b=$(last_line "$MAC_JOURNAL")
  if [ -z "$(mac_pids)" ] && [ "$a" = "$b" ]; then
    say_ "Mac app off: yes — no journal line in ${BEAT_GAP_S}s; last $(echo "$b" | cut -c1-90)"
    return 0
  fi
  say_ "Mac app off: NO — $([ -n "$(mac_pids)" ] && echo 'a process is running' || echo 'its journal moved')"
  return 1
}

# For a Mac app that a test run started and that has exited by itself: only
# the process is looked at, because its exit is the script's own doing.
mac_not_running() { [ -z "$(mac_pids)" ] && echo yes || echo "NO, a Mac app process is running"; }

# Waits until the journal file $1 has a `start` line written at or after
# the ISO time $2; $3 is "phone" to copy it from the device each time.
wait_for_start() {
  local file=$1 since=$2 where=${3:-mac} try
  for try in $(seq 1 30); do
    [ "$where" = phone ] && phone_journal "$file" >/dev/null
    if python3 - "$file" "$since" <<'PY' 2>/dev/null
import json, sys
since = sys.argv[2]
for line in open(sys.argv[1], errors="replace"):
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("event") == "start" and row.get("at", "") >= since:
        sys.exit(0)
sys.exit(1)
PY
    then return 0; fi
    sleep 5
  done
  return 1
}

wait_until() { while [ "$(date +%s)" -lt "$1" ]; do sleep 30; done; }
