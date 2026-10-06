#!/bin/bash
# The idle line: both apps open and doing nothing for eight hours, one pinned
# peer, and what each of them asked of the relay in that time.
#
#   0. Both apps are closed, and their silence confirmed.
#   1. The phone app is launched (devicectl) and the Mac app is opened (the
#      built app itself, not a test). Each must write this run's `start`
#      line in its own journal.
#   2. Nothing is touched for HOURS. Every half hour both journals are
#      copied and one line per device says where its count is — so what was
#      seen so far survives whatever happens to this script.
#   3. Both apps are closed, and their silence confirmed.
#   4. tools/t2/sealed_soak_verdict.py reads the two journals.
#
# "Open" is not a process list: an app was open for as long as its journal
# has an `alive` line every thirty seconds. The request count is the app's
# own, from those same lines. The Mac and its display are kept awake for the
# length of the run; the phone's rig peer keeps its own screen on.
#
# The Mac app is built beforehand (it is not built here) and the phone app
# is never reinstalled or removed here.
#
# Usage: tools/t2/sealed_soak_rig.sh <output dir> <path to the built Mac .app> [hours, default 8]
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
MAC_APP=${2:?path to the built Mac app}
HOURS=${3:-8}
. tools/t2/sealed_rig_lib.sh
LOG="$OUT/script.log"
[ -d "$MAC_APP" ] || { say_ "no Mac app at $MAC_APP"; exit 2; }

snapshot() {
  cp "$MAC_JOURNAL" "$OUT/mac_events_soak.jsonl" 2>/dev/null
  phone_journal "$OUT/phone_events_soak.jsonl" || say_ "the phone's journal could not be copied this time"
  python3 tools/t2/sealed_soak_verdict.py "$OUT" --progress "$HOURS" | while read -r line; do say_ "$line"; done
}

say_ "0: both apps are closed first"
mac_off || say_ "0 continues, but the Mac app was NOT confirmed off"
phone_off "$OUT" || say_ "0 continues, but the phone app was NOT confirmed off"

SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
echo "$SINCE" >"$OUT/soak_since.txt"
say_ "1: opening both apps; this run begins at ${SINCE}Z"
phone_on || { say_ "1: the phone app could NOT be launched"; exit 2; }
open "$MAC_APP"
sleep 8
MAC_PID=$(mac_pids | head -n 1)
if [ -n "$MAC_PID" ]; then
  # The Mac and its display stay awake for as long as the app runs.
  caffeinate -dimsu -w "$MAC_PID" &
  say_ "1: Mac app process $MAC_PID; the Mac is kept awake while it runs"
else
  say_ "1: the Mac app did NOT start"
fi
wait_for_start "$MAC_JOURNAL" "$SINCE" mac \
  && say_ "1: Mac app on: yes — a start line in its journal" \
  || say_ "1: Mac app on: NO start line in its journal"
wait_for_start "$OUT/phone_events_soak.jsonl" "$SINCE" phone \
  && say_ "1: phone app on: yes — a start line in its journal" \
  || say_ "1: phone app on: NO start line in its journal"

END=$(( $(date +%s) + HOURS * 3600 + 120 ))
say_ "2: both open and idle until $(date -u -r "$END" +%Y-%m-%dT%H:%M:%SZ); nothing is touched"
while [ "$(date +%s)" -lt "$END" ]; do
  NEXT=$(( $(date +%s) + 1800 ))
  [ "$NEXT" -gt "$END" ] && NEXT=$END
  wait_until "$NEXT"
  snapshot
done

say_ "3: closing both apps"
snapshot
mac_off && MAC_END=yes || MAC_END=NO
phone_off "$OUT" && PHONE_END=yes || PHONE_END=NO

python3 tools/t2/sealed_soak_verdict.py "$OUT" "$HOURS" | tee "$OUT/verdict.txt" | tee -a "$LOG" >/dev/null
say_ "done — Mac app off: $MAC_END; phone app off: $PHONE_END"
tail -n 1 "$OUT/verdict.txt"
