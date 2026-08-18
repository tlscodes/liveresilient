#!/usr/bin/env bash
# Negative control for the T2 harness — run BEFORE trusting any measurement.
#
# The failure mode this exists to catch: shaping that silently does nothing.
# pf may skip the interface, the traffic may never traverse it, the anchor may
# not load — and every one of those produces clean-network numbers that look
# like a passing result.
#
# It has already earned its keep once. The first harness shaped a feth pair and
# pinged one local address from another; the kernel short-circuits that through
# loopback, which pf skips on this machine, so shaping could never have worked.
# This script refused to report anything, which is the only reason that was
# discovered before numbers were published rather than after. See the header of
# net_shape.sh for the full post-mortem.
#
# WHAT IT MEASURES NOW: the real path to the device under test — by default the
# iPhone on bridge100 via Internet Sharing. A remote peer cannot short-circuit.
#
# Impairment used: 200 ms delay, 30% loss. The pass band is deliberately wide,
# because the question is "is the shaper doing anything at all", not calibration.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SHAPE="$HERE/net_shape.sh"
IFACE="${T2_IFACE:-bridge100}"
PINGS=40
fail=0

note() { printf '%-8s %s\n' "$1" "$2"; }

cleanup() { sudo -n "$SHAPE" teardown >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# The harness must never prompt for a password: it runs unattended. If the
# sudoers entry is absent, say exactly what to install rather than hanging.
if ! sudo -n true 2>/dev/null; then
  note SKIP "passwordless sudo is not configured — the harness cannot run unattended."
  cat <<EOF

Install once, by hand, then re-run:

  sudo tee /etc/sudoers.d/t2harness >/dev/null <<'SUDO'
  $(whoami) ALL=(root) NOPASSWD: $SHAPE
  SUDO
  sudo chmod 440 /etc/sudoers.d/t2harness

Nothing was measured. This is reported as a missing prerequisite, not a pass.
EOF
  exit 3
fi

# ---------------------------------------------------------------------------
# Find the peer. Everything downstream is meaningless without a REMOTE address
# on the shaped interface: a local address would be short-circuited and the
# shaper would appear ineffective even when it works.
# ---------------------------------------------------------------------------
PEER="${T2_PEER:-}"
if [ -z "$PEER" ]; then
  # Neighbours seen on this interface, minus our own address.
  SELF=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
  PEER=$(arp -an 2>/dev/null | grep "on $IFACE" | grep -oE '\(([0-9.]+)\)' \
         | tr -d '()' | grep -v "^${SELF:-none}$" | head -1)
fi

if [ -z "$PEER" ]; then
  note FAIL "no peer found on $IFACE"
  cat <<EOF

The device under test must be reachable on the shaped interface before this
can mean anything. Checklist:
  · System Settings -> General -> Sharing -> Internet Sharing is ON
  · the phone has joined the Mac's hotspot (not the other way round: if the
    Mac joins the PHONE's hotspot, the phone is the router and nothing on this
    machine can shape the phone's traffic)
  · confirm with:  arp -an | grep "on $IFACE"
  · or set it explicitly:  T2_PEER=192.168.3.2 $0

Nothing was measured. This is a missing prerequisite, not a pass.
EOF
  exit 3
fi
note peer "$PEER on $IFACE"

sudo -n "$SHAPE" check || { note FAIL "interface check failed"; exit 1; }

# Baseline first: an unshaped path must be reachable and mostly lossless, or
# the rig itself is broken and nothing downstream means anything.
note step "baseline, unshaped"
sudo -n "$SHAPE" teardown >/dev/null 2>&1 || true
base=$(ping -c "$PINGS" -i 0.1 -q "$PEER" 2>/dev/null | tail -2)
base_loss=$(printf '%s' "$base" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+' || echo 100)
base_rtt=$(printf '%s' "$base" | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
note base "loss ${base_loss}%  rtt ${base_rtt:-?} ms"

# A broken baseline is the single most misleading state this rig can be in: the
# shaped run would also look terrible, the deltas would look like the shaper
# working, and every later number would be fiction.
ok_base=$(python3 -c "print(1 if ${base_loss:-100} <= 10 else 0)" 2>/dev/null || echo 0)
if [ "$ok_base" != 1 ]; then
  note FAIL "baseline is already ${base_loss}% loss — the rig is broken, not the network"
  echo
  echo "SHAPER NOT EFFECTIVE — no measurements should be taken on this host"
  echo "Fix reachability to $PEER first; a shaped run over a broken path proves nothing."
  exit 1
fi

note step "installing 200 ms delay and 30% loss"
sudo -n "$SHAPE" shape - 200 0.30 >/dev/null

out=$(ping -c "$PINGS" -i 0.1 -q "$PEER" 2>/dev/null | tail -2)
loss=$(printf '%s' "$out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+' || echo 0)
rtt=$(printf '%s' "$out" | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
note shaped "loss ${loss}%  rtt ${rtt:-?} ms"

# Each direction carries 200 ms, so a round trip should show roughly 400 ms;
# accept anything at or above 200 to allow for how dummynet accounts it.
ok_rtt=$(python3 -c "print(1 if ${rtt:-0} >= 200 else 0)" 2>/dev/null || echo 0)
# Both directions drop 30%, so a round trip survives (0.7 x 0.7) = 49% of the
# time. Accept a wide band: anything from 20% to 80% proves loss is real.
ok_loss=$(python3 -c "print(1 if 20 <= ${loss:-0} <= 80 else 0)" 2>/dev/null || echo 0)

[ "$ok_rtt" = 1 ] || { note FAIL "delay did not take effect (rtt ${rtt:-?} ms, wanted >= 200)"; fail=1; }
[ "$ok_loss" = 1 ] || { note FAIL "loss did not take effect (${loss}%, wanted 20-80)"; fail=1; }

# Restoring is part of the test, not an afterthought: a harness that leaves the
# host shaped makes every later measurement silently wrong, and the symptom
# appears far from the cause. Verify the restore rather than trusting it.
note step "restoring, then re-checking the clean path"
sudo -n "$SHAPE" teardown >/dev/null 2>&1 || true
after=$(ping -c 10 -i 0.1 -q "$PEER" 2>/dev/null | tail -2)
after_rtt=$(printf '%s' "$after" | awk -F'/' '/round-trip|avg/ {print $5}' | head -1)
note restored "rtt ${after_rtt:-?} ms"
ok_restore=$(python3 -c "print(1 if ${after_rtt:-9999} < 100 else 0)" 2>/dev/null || echo 0)
[ "$ok_restore" = 1 ] || {
  note FAIL "the host is STILL SHAPED after teardown (rtt ${after_rtt:-?} ms)"
  echo "Run: sudo $SHAPE restore"
  fail=1
}

if [ $fail = 0 ]; then
  echo
  echo "SHAPER EFFECTIVE — measurements taken after this point are trustworthy"
  echo "iface=$IFACE peer=$PEER baseline=${base_rtt:-?}ms/${base_loss}% shaped=${rtt}ms/${loss}% restored=${after_rtt:-?}ms"
else
  echo
  echo "SHAPER NOT EFFECTIVE — no measurements should be taken on this host"
  echo "Diagnose with:  sudo pfctl -s Interfaces -v   and   sudo dnctl list"
fi
exit $fail
