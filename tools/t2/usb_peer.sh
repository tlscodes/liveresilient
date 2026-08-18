#!/bin/bash
# usb_peer.sh — discover the cabled iPhone rig endpoints, print exports.
#
#   eval "$(tools/t2/usb_peer.sh)"     # sets T2_IFACE, T2_PEER, DEVICE
#
# Works in BOTH wired topologies, no radio in either:
#   A. link-local  — phone self-assigns 169.254.x (phones WITH a SIM)
#   B. shared USB  — Internet Sharing "to iPhone USB" hands out 192.168.x
#                    via bridge100 (required for a SIM-less phone)
#
# Rule: ONE phone on the cable at a time. Plug it, unlock, Trust if asked.
set -uo pipefail

WIFI_DEV=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')

# Neighbours on every interface EXCEPT the Wi-Fi radio. The radio carries a
# link-local route too, so without this filter home-LAN hosts match first.
candidates() {
  arp -an 2>/dev/null | grep -v permanent \
    | sed -n 's/.*(\([0-9.]*\)) at .* on \([a-z0-9]*\).*/\1 \2/p' \
    | awk -v w="${WIFI_DEV:-none}" '$2 != w'
}

T2_IFACE="" T2_PEER=""
while read -r ip ifc; do
  [ -n "$ip" ] || continue
  case "$ip" in 169.254.*|192.168.*|172.20.*) ;; *) continue ;; esac
  # 5 probes, not 2: a freshly-attached iOS link drops its first
  # packets while waking (measured 2/5, then 1.4ms steady).
  if ping -c 5 -i 0.3 -t 3 "$ip" >/dev/null 2>&1; then
    T2_PEER="$ip"; T2_IFACE="$ifc"; break
  fi
done <<EOF_C
$(candidates)
EOF_C

# No IPv4 peer. Distinguish "cable dead" from "cable alive, phone has no
# IPv4" — the SIM-less case, which has a specific one-time remedy.
if [ -z "$T2_PEER" ]; then
  # Probe live, never trust the neighbour cache: a previously-cabled device
  # leaves a stale entry that names the wrong interface (measured 2026-08-09).
  LIVE=""
  for i in $(ifconfig -l); do
    case "$i" in en[0-9]*) ;; *) continue ;; esac
    [ "$i" = "${WIFI_DEV:-none}" ] && continue
    SELF_MAC=$(ifconfig "$i" 2>/dev/null | awk '/ether/{print $2; exit}')
    [ -n "$SELF_MAC" ] || continue
    PROBE=$(ping6 -c 2 -i 0.3 -I "$i" ff02::1 2>/dev/null)
    case "$PROBE" in
      *"bytes from fe80"*)
        NEIGH=$(ndp -an 2>/dev/null | awk -v ifc="$i" -v me="$SELF_MAC" \
          '$3 == ifc && $2 != me && $1 ~ /^fe80::/ {print $1; exit}')
        [ -n "$NEIGH" ] && { LIVE="$i"; break; }
        ;;
    esac
  done
  if [ -n "$LIVE" ]; then
    echo "usb_peer: cable is ALIVE on $LIVE (IPv6 link-local answers) but the" >&2
    echo "          phone has no IPv4 address — the SIM-less case." >&2
    echo "          Fix once: System Settings > General > Sharing >" >&2
    echo "          Internet Sharing: share from Wi-Fi, TO 'iPhone USB' ONLY." >&2
    echo "          Leave the Wi-Fi checkbox OFF (that AP mode is what killed" >&2
    echo "          22 draws on 2026-08-08). Then re-run this script." >&2
    exit 2
  fi
  echo "usb_peer: no neighbour on any wired interface — unlock phone, replug" >&2
  exit 1
fi

# udid = USB serial with a dash after the 8th character (ground truth for
# which phone is actually cabled).
SER=$(system_profiler SPUSBDataType 2>/dev/null \
  | awk '/Serial Number: 00008/{print $3; exit}')
if [ -n "$SER" ]; then
  DEVICE="${SER:0:8}-${SER:8}"
else
  DEVICE=UNKNOWN
fi

echo "export T2_IFACE=$T2_IFACE"
echo "export T2_PEER=$T2_PEER"
echo "export DEVICE=$DEVICE"
