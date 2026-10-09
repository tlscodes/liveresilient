#!/bin/bash
# Is the phone on the Mac's bridge? Launches the phone app (no filter loaded),
# watches ARP + the DHCP lease for the peer for 45 s, then turns the app off.
# A run over the TXT lane is only valid when the phone answers ARP on bridge100:
# otherwise it reaches the relay on its own network and the pf whitelist cuts nothing.
# Usage: tools/t2/sealed_path_probe.sh <output dir>
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
. tools/t2/sealed_rig_lib.sh
LOG="$OUT/script.log"
PEER=${SEALED_TXT_PEER:-192.168.2.2}
say_ "probe: peer $PEER, arp before: $(arp -n "$PEER" 2>&1 | tail -1)"
phone_on || say_ "probe: phone app could NOT be launched"
seen=no
for i in $(seq 1 22); do
  line=$(arp -n "$PEER" 2>&1 | tail -1)
  case "$line" in *incomplete*|*"no entry"*) ;; *) seen=yes; say_ "probe: arp $line"; break ;; esac
  sleep 2
done
say_ "probe: bridge100 neighbours: $(arp -an -i bridge100 2>/dev/null | grep -v permanent | tr '\n' ' ')"
phone_off "$OUT" || say_ "probe: phone app NOT confirmed off"
say_ "PROBE on_bridge=$seen"
