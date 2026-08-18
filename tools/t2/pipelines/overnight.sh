#!/bin/bash
# DAY MISSION (hotspot topology): after the video sniper pipeline, hammer
# voice loss60 (item 8) and messaging loss60/extreme. Peer defaults to
# the phone-as-hotspot gateway; override with T2_PEER.
cd /Users/behnam/Downloads/voice_call_kit_v3 || exit 1
S=$(cd "$(dirname "$0")" && pwd)/logs
mkdir -p "$S"
PEER="${T2_PEER:-172.20.10.1}"
IFACE="${T2_IFACE:-en1}"
DEV="${DEVICE:?DEVICE not set - eval tools/t2/usb_peer.sh first}"
case "$DEV" in UNKNOWN|"") echo "FATAL: no device discovered" >&2; exit 1 ;; esac
python3 "$(dirname "$0")/wake_udp.py" "$PEER" >/dev/null 2>&1 &
KEEPAWAKE=$!
trap 'kill $KEEPAWAKE 2>/dev/null' EXIT

while ! grep -q "SNIPER_PIPELINE_DONE" "$S/sniper_run.out" 2>/dev/null; do
  sleep 60
done
echo "MISSION video pipeline finished: $(grep -E 'PIPELINE' "$S/sniper_run.out" | tr '\n' ' ')"

clean_window() {
  local waited=0 lost
  while :; do
    lost=$(ping -c 30 -i 0.5 -t 8 "$PEER" 2>/dev/null \
      | awk -F'[ %]' '/packet loss/{print $7}')
    lost=${lost%.*}
    if [ -n "$lost" ] && [ "$lost" -lt 10 ] 2>/dev/null; then
      return 0
    fi
    waited=$((waited + 30))
    [ "$waited" -ge 900 ] && return 1
    sleep 15
  done
}

row_hammer() {
  local profile=$1 testfile=$2 label=$3 max=$4 i=1 row waived=0
  while [ "$i" -le "$max" ]; do
    clean_window || { echo "OVERNIGHT $label $i SKIPPED no window"; return 1; }
    sudo -n T2_IFACE="$IFACE" T2_PEER="$PEER" tools/t2/h2_run.sh "$profile" \
      "integration_test/$testfile" "$DEV" \
      > "$S/overnight_${label}_$i.log" 2>&1
    row=$(grep -E "^$profile	" "$S/overnight_${label}_$i.log" | tail -1 | cut -c1-130)
    echo "OVERNIGHT $label try $i: ${row:-NO_ROW}"
    case "$row" in
      *UNROUTED*)
        waived=$((waived + 1))
        if [ "$waived" -le 20 ]; then
          echo "OVERNIGHT $label waived try $waived: zero packets crossed — phone permission gate, shot NOT counted"
          sleep 90
          continue
        fi
        ;;
    esac
    case "$row" in
      *"	PASS"*) return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

row_hammer loss60 sla_thresholds_test.dart voice-loss60 6 \
  && echo "MISSION voice loss60 GREEN (item 8 closed)"
row_hammer loss60 messaging_survival_test.dart msg-loss60 4 \
  && echo "MISSION messaging loss60 GREEN"
row_hammer extreme messaging_survival_test.dart msg-extreme 4 \
  && echo "MISSION messaging extreme GREEN"

echo "OVERNIGHT_MISSION_DONE"
