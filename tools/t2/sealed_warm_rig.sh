#!/bin/bash
# The warm line: both apps open, a conversation going, and the time from
# "written" to "opened on the other side" taken for ten texts each way on the
# same Mac and the same phone. No call, no hub: the texts cross the pair
# shelf of the border relay over the internet, found by looking — nothing
# rings and no request is held open.
#
#   1. The phone app is closed (confirmed by its journal going still), then
#      launched; its journal must show this run's `start` line.
#   2. The Mac app is started by a test that types each text into the app's
#      own panel. The phone's rig peer answers each one with a text that says
#      when it opened it. One warm-up round, then the counted ones.
#   3. Both apps are closed; the phone's silence is confirmed.
#   4. tools/t2/sealed_warm_verdict.py reads the Mac's lines. The two clocks
#      are not assumed to agree: the verdict bounds their difference from the
#      data itself.
#
# The phone app is launched and terminated with devicectl and is never
# reinstalled or removed here.
#
# Usage: tools/t2/sealed_warm_rig.sh <output dir>      (about 8 minutes)
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
. tools/t2/sealed_rig_lib.sh
APP=apps/reference_app
COUNT=${SEALED_WARM_COUNT:-10}
LOG="$OUT/script.log"

say_ "1: the phone app is closed first, so that its start is this run's"
phone_off "$OUT" || say_ "1 continues, but the phone app was NOT confirmed off"
say_ "1: Mac app not running: $(mac_not_running)"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%S)
phone_on || { say_ "1: the phone app could NOT be launched"; exit 2; }
if wait_for_start "$OUT/phone_events_start.jsonl" "$SINCE" phone; then
  say_ "1: phone app on: yes — a start line in its journal since $SINCE"
else
  say_ "1: phone app on: NO start line in its journal since $SINCE"
fi

say_ "2: the Mac app writes one warm-up and $COUNT texts; the phone answers each"
( cd "$APP" && flutter test integration_test/sealed_warm_rig_test.dart -d macos \
    --dart-define=SEALED_WARM_COUNT="$COUNT" >"$OUT/mac_warm.log" 2>&1 )
say_ "2: Mac app exited rc=$?; not running: $(mac_not_running)"
grep -a "SEALED_WARM" "$OUT/mac_warm.log" | tee -a "$LOG" >/dev/null

say_ "3: closing the phone app"
phone_journal "$OUT/phone_events_warm.jsonl"
say_ "3: phone journal: $(wc -l <"$OUT/phone_events_warm.jsonl" 2>/dev/null | tr -d ' ') lines"
phone_off "$OUT" && PHONE_END=yes || PHONE_END=NO

python3 tools/t2/sealed_warm_verdict.py "$OUT" "$COUNT" | tee "$OUT/verdict.txt" | tee -a "$LOG" >/dev/null
say_ "done — phone app off: $PHONE_END; Mac app not running: $(mac_not_running)"
tail -n 1 "$OUT/verdict.txt"
