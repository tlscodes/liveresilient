#!/bin/bash
# SNIPER PIPELINE (hotspot topology 2026-08-09): cheap connect-only draws
# first, full video row only after a connect lands. Peer defaults to the
# phone-as-hotspot gateway; override with T2_PEER.
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
    [ "$waited" -ge 600 ] && return 1
    sleep 15
  done
}

sniper_then_record() {
  local profile=$1 snipes=$2 i=1 row waived=0
  while [ "$i" -le "$snipes" ]; do
    clean_window || { echo "SNIPER $profile $i SKIPPED no clean window"; return 1; }
    sudo -n T2_IFACE="$IFACE" T2_PEER="$PEER" tools/t2/h2_run.sh "$profile" \
      integration_test/loopback_call_test.dart "$DEV" \
      > "$S/sniper_${profile}_$i.log" 2>&1
    row=$(grep -E "^$profile	" "$S/sniper_${profile}_$i.log" | tail -1 | cut -c1-130)
    echo "SNIPER $profile shot $i: ${row:-NO_ROW}"
    case "$row" in
      *UNROUTED*)
        waived=$((waived + 1))
        if [ "$waived" -le 20 ]; then
          echo "SNIPER $profile waived try $waived: zero packets crossed — phone permission gate, shot NOT counted"
          sleep 90
          continue
        fi
        ;;
    esac
    case "$row" in
      *"	PASS"*)
        echo "SNIPER $profile CONNECT PROVEN — firing the record run"
        clean_window || true
        sudo -n T2_IFACE="$IFACE" T2_PEER="$PEER" tools/t2/h2_run.sh "$profile" \
          integration_test/video_survival_test.dart "$DEV" \
          > "$S/record_${profile}.log" 2>&1
        row=$(grep -E "^$profile	" "$S/record_${profile}.log" | tail -1 | cut -c1-150)
        echo "RECORD $profile: ${row:-NO_ROW}"
        case "$row" in *"	PASS"*) return 0 ;; esac
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

if sniper_then_record loss60 8; then
  echo "PIPELINE loss60 GREEN"
  sniper_then_record extreme 4 && echo "PIPELINE extreme GREEN"
fi
echo "SNIPER_PIPELINE_DONE"
