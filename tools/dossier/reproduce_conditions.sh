#!/bin/bash
# External-referee reproduction of the E2E test conditions (gate T5 item 2).
#
# The Mac rig shapes the device link with dnctl/pf (tools/t2/net_shape.sh).
# This is the Linux equivalent, same numbers as the T3 matrix profile
# ‹src:tools/phase5/FULL_TEST_PLAN.md track 3›:
#   bandwidth 2 Kbps, loss 60% each direction, rtt 2000 ms (1000 ms/way)
#
# Usage (root, Linux with iproute2):
#   ./reproduce_conditions.sh setup <iface>    # apply the profile to iface
#   ./reproduce_conditions.sh teardown <iface> # remove it
#   ./reproduce_conditions.sh demo             # veth pair + ping through it
# Loss composition note: applied per direction at 60% i.i.d., matching the
# rig's end-to-end target the way the probes apply it (drop-on-send per
# crossing) ‹src:apps/reference_app/test/datagram_lane_probe_test.dart›.
set -euo pipefail

RATE=2kbit
DELAY_MS=1000
LOSS_PCT=60

case "${1:-}" in
  setup)
    IF="${2:?iface}"
    tc qdisc replace dev "$IF" root netem \
      rate "$RATE" delay "${DELAY_MS}ms" loss "${LOSS_PCT}%"
    echo "applied: $RATE / ${LOSS_PCT}% loss / ${DELAY_MS}ms one-way on $IF"
    ;;
  teardown)
    IF="${2:?iface}"
    tc qdisc del dev "$IF" root || true
    echo "cleared $IF"
    ;;
  demo)
    ip link add veth-a type veth peer name veth-b
    ip addr add 10.99.0.1/24 dev veth-a
    ip addr add 10.99.0.2/24 dev veth-b
    ip link set veth-a up
    ip link set veth-b up
    "$0" setup veth-a
    "$0" setup veth-b
    echo "profile live on veth pair; ping to observe rtt/loss:"
    ping -c 10 -I 10.99.0.1 10.99.0.2 || true
    ip link del veth-a
    ;;
  *)
    echo "usage: $0 setup|teardown <iface> | demo" >&2
    exit 2
    ;;
esac
