#!/bin/bash
# Phase چ rig, ONE window (docs/ch-background-design.md). Run under nohup:
#   nohup tools/t2/sealed_ch_rig.sh <run dir> >/dev/null 2>&1 &
# The phone gets the flag build installed OVER the app (never a delete), is
# launched once (registration lives in the app), sent to the background by
# opening Settings (no kill) and left for auto-lock. The Mac app sends one
# text at T and stays on; the letter rides the phone's own internet (DoH) to
# the relay's /dns-query — no bridge, no local responder, no pf whitelist.
# Inside the window the phone is never launched: its journal is only copied.
# A second start on the same dir re-runs only the verdict, never a new window.
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT=$PWD
OUT=$(mkdir -p "${1:?run dir}" && cd "$1" && pwd)
LOG="$OUT/script.log"
. tools/t2/sealed_rig_lib.sh
APP=$ROOT/apps/reference_app
RIG_APP=${CH_RIG_APP:-$ROOT/.autorun/evidence/ch/rig/Runner.app}
# phase چ DoH: no bridge host, no local responder. The flag app resolves give
# over its OWN internet to the relay's /dns-query (baked SEALED_TXT_DOH). The
# Mac only installs the app and copies the journal over devicectl (USB/paired).
RELAY="https://voice-call-relay.tlscodes-com.workers.dev"
PEER_ID=${SEALED_CH_PEER:-a08887e8c641b475cc4c50722640e68f}
WINDOW_S=${CH_WINDOW_S:-28800}
STARTED="$ROOT/.autorun/ch_device_started"
SUPPORT=Documents/voice_call_kit_intelligence

verdict() {
  # The window's copies fail while the phone is locked; this one waits for the unlock.
  phone_journal_unlocked "$OUT/phone_journal.jsonl" "${CH_UNLOCK_WAIT_S:-3600}" \
    || say_ "verdict: phone journal copy failed (keeping the last copy)"
  [ -s "$OUT/phone_journal.jsonl" ] || cp "$OUT/phone_journal_last.jsonl" "$OUT/phone_journal.jsonl" 2>/dev/null
  cp "$MAC_JOURNAL" "$OUT/mac_journal.jsonl" 2>/dev/null
  python3 tools/t2/sealed_ch_verdict.py --run "$OUT" >"$OUT/verdict.txt" 2>&1
  local rc=$?
  echo "$rc" >"$ROOT/.autorun/ch_verdict_rc"
  say_ "verdict rc=$rc: $(tail -2 "$OUT/verdict.txt" | head -1)"
  touch "$ROOT/.autorun/ch_device_done"
}

if [ -e "$STARTED" ]; then
  say_ "second start: the window was already opened ($(cat "$STARTED")); verdict only"
  verdict
  exit 0
fi

# --- preconditions, each in its own call ---------------------------------------
load=$(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/')
awk -v l="$load" 'BEGIN{exit !(l<6)}' || { say_ "STOPPED load $load"; exit 3; }
pgrep -f "flutter_tester|flutter build|flutter test" >/dev/null && { say_ "STOPPED a flutter process runs"; exit 3; }
[ -d "$RIG_APP" ] || { say_ "STOPPED no rig app at $RIG_APP (run .autorun/ch_build_check.sh)"; exit 3; }
tools/t2/net_shape.sh status >"$OUT/pf_before.txt" 2>&1
# DoH: no bridge wake, no local responder. The letter rides the phone's OWN
# internet to the relay's /dns-query; the Mac only needs devicectl reach.
xcrun devicectl device info details --device "$PHONE" >"$OUT/device.log" 2>&1 \
  || { say_ "STOPPED phone not reachable over devicectl"; exit 3; }

LOCK_PID= MAC_PID=
cleanup() {
  [ -n "$LOCK_PID" ] && kill "$LOCK_PID" 2>/dev/null
  [ -n "$MAC_PID" ] && kill "$MAC_PID" 2>/dev/null
  mac_off >/dev/null 2>&1
  # w1 never ran the end script, so its bg_cancelled line was never written.
  tools/t2/sealed_ch_end.sh "$OUT" >>"$LOG" 2>&1
  tools/t2/net_shape.sh status >"$OUT/pf_after.txt" 2>&1
  say_ "cleanup: Mac app off, end script ran, pf status in pf_after.txt"
}
trap cleanup EXIT

# --- 1. install over, 2. bg_until, 3. one launch ------------------------------
xcrun devicectl device install app --device "$PHONE" "$RIG_APP" >"$OUT/install.log" 2>&1 \
  || { say_ "STOPPED install failed"; tail -3 "$OUT/install.log"; exit 3; }
date -u -v+"$((WINDOW_S / 3600 + 1))"H +%Y-%m-%dT%H:%M:%SZ >"$OUT/sealed_bg_until"
xcrun devicectl device copy to --device "$PHONE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source "$OUT/sealed_bg_until" \
  --destination "$SUPPORT/sealed_bg_until" >"$OUT/until.log" 2>&1 \
  || say_ "bg_until copy failed (the turn then has no end of its own)"
phone_on || { say_ "STOPPED the phone app did not launch"; exit 3; }
for _ in $(seq 1 20); do
  sleep 6
  phone_journal "$OUT/phone_journal_last.jsonl" && grep -q '"event":"bg_registered"' "$OUT/phone_journal_last.jsonl" && break
done
grep '"event":"bg_registered"\|"event":"bg_submitted"\|"event":"bg_not_permitted"' "$OUT/phone_journal_last.jsonl" \
  | tail -3 | tee -a "$LOG"
grep -q '"event":"bg_submitted"' "$OUT/phone_journal_last.jsonl" \
  || { say_ "STOPPED no bg_submitted after launch"; exit 3; }

# --- 4. background without a kill, then prove the loop is quiet ---------------
xcrun devicectl device process launch --device "$PHONE" com.apple.Preferences >>"$LOG" 2>&1
# Lock state from passcodeRequired / the 10003 refusal (the old grep matched
# "unlockedSinceBoot" and read open always). Writes lock2.tsv, stops on ch_device_done.
tools/t2/ch_lock_probe.sh "$OUT" >/dev/null 2>&1 &
LOCK_PID=$!
quiet_since=$(date +%s)
last=
for _ in $(seq 1 40); do
  sleep 75
  # A locked phone refuses the copy: no new line seen, so the quiet clock runs on.
  if phone_journal "$OUT/phone_journal_last.jsonl"; then
    now_last=$(grep '"event":"\(alive\|look\|warm\)"' "$OUT/phone_journal_last.jsonl" | tail -1)
    [ "$now_last" != "$last" ] && { last=$now_last; quiet_since=$(date +%s); }
  fi
  [ $(( $(date +%s) - quiet_since )) -ge $((2 * BEAT_GAP_S)) ] && break
done
[ $(( $(date +%s) - quiet_since )) -ge $((2 * BEAT_GAP_S)) ] \
  || { say_ "STOPPED the phone loop never went quiet (audio background may keep it alive)"; exit 3; }
say_ "phone loop quiet for >= $((2 * BEAT_GAP_S)) s"

# --- 5. T: the Mac sends one text and stays on ---------------------------------
date -u +%FT%TZ >"$STARTED"
( cd "$APP" && flutter test integration_test/sealed_ch_mac_test.dart -d macos \
    --dart-define=SEALED_CH_PEER="$PEER_ID" --dart-define=SEALED_CH_WAIT_S="$WINDOW_S" ) \
  >"$OUT/mac.log" 2>&1 &
MAC_PID=$!
for _ in $(seq 1 60); do
  sleep 5
  grep -q "SEALED_CH tx id=" "$OUT/mac.log" && break
  kill -0 "$MAC_PID" 2>/dev/null || break
done
tx=$(grep -o "SEALED_CH tx id=[0-9a-f]* at=[^ ]*" "$OUT/mac.log" | head -1)
[ -n "$tx" ] || { say_ "STOPPED the Mac never sent"; tail -5 "$OUT/mac.log"; verdict; exit 3; }
lid=$(echo "$tx" | sed 's/.*id=\([0-9a-f]*\).*/\1/') at=$(echo "$tx" | sed 's/.*at=//')
off=$(date +%z | awk '{s=substr($0,1,1)=="-"?-1:1; print s*(substr($0,2,2)*3600+substr($0,4,2)*60)}')
python3 -c "import json,sys,datetime as d;t=d.datetime.fromisoformat(sys.argv[2].replace('Z','+00:00'));json.dump({'letter_id':sys.argv[1],'tx_at':t.isoformat(),'window_end':(t+d.timedelta(seconds=int(sys.argv[3]))).isoformat(),'give_utc_offset_s':int(sys.argv[4])},open(sys.argv[5],'w'))" \
  "$lid" "$at" "$WINDOW_S" "$off" "$OUT/meta.json"
say_ "T: letter $lid sent at $at; window ${WINDOW_S}s; no launch inside it"

# --- 6/7. the window: copies only ----------------------------------------------
end=$(( $(date +%s) + WINDOW_S ))
while [ "$(date +%s)" -lt "$end" ]; do
  grep -q "SEALED_CH receipt id=" "$OUT/mac.log" && break
  kill -0 "$MAC_PID" 2>/dev/null || break
  sleep 300
  phone_journal "$OUT/phone_journal_last.jsonl" >/dev/null 2>&1
done
say_ "window over: $(grep -o 'SEALED_CH receipt.*' "$OUT/mac.log" | head -1)"
sleep 20
verdict
