#!/bin/bash
# Before the phone app is launched over the TXT lane: wake the phone's link to
# the Mac's bridge WITHOUT starting the app, and prove the phone is on it.
#
# Why: an idle phone lets its bridge lease lapse (one hour) and rejoins the
# bridge only ~40 s after it wakes. An app launched before that reaches the
# relay over the phone's own network, so the pf whitelist cuts nothing
# (hour1, 2026-10-08: lease expired 22:37:40Z, phone launched 23:04:37Z, all
# eight requests direct, give.log empty). iOS Settings is launched instead —
# it wakes the phone and holds the screen while the link comes back.
#
# Passes when the peer answers ARP on bridge100 AND holds an unexpired lease.
# Usage: tools/t2/sealed_bridge_wake.sh [peer ip]   (exit 0 = on the bridge)
set -uo pipefail
cd "$(dirname "$0")/../.."
. tools/t2/sealed_rig_lib.sh
PEER=${1:-${SEALED_TXT_PEER:-192.168.2.2}}

lease_left_s() { # seconds until the peer's DHCP lease ends (negative = expired)
  local h
  h=$(awk -v ip="ip_address=$PEER" '$1==ip {f=1} f && $1 ~ /^lease=/ {sub("lease=0x","",$1); print $1; exit}' \
    /var/db/dhcpd_leases 2>/dev/null)
  [ -n "$h" ] && echo $(( 16#$h - $(date +%s) )) || echo -1
}
on_bridge() {
  case "$(arp -n "$PEER" 2>&1 | tail -1)" in *incomplete*|*"no entry"*) return 1 ;; esac
  [ "$(lease_left_s)" -gt 300 ]
}

for try in 1 2 3; do
  out=$(xcrun devicectl device process launch --device "$PHONE" com.apple.Preferences 2>&1) || true
  echo "$out" | grep -qi 'launched application' || say_ "wake: Settings did not launch (try $try): $(echo "$out" | grep -i 'error\|locked' | head -1 | cut -c1-120)"
  for i in $(seq 1 40); do
    if on_bridge; then
      sleep 5 # let the phone's routes settle on the bridge
      say_ "wake: phone $PEER on the bridge (try $try, ${i}x3s): $(arp -n "$PEER" | tail -1 | cut -c1-60), lease left $(lease_left_s)s"
      exit 0
    fi
    sleep 3
  done
done
say_ "wake: phone $PEER NOT on the bridge — arp: $(arp -n "$PEER" 2>&1 | tail -1 | cut -c1-60), lease left $(lease_left_s)s"
exit 1
