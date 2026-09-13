#!/usr/bin/env bash
# T2 network shaping on macOS — the ONLY privileged script in the harness.
#
# WHY IT IS ONE FILE. Everything that needs root lives here so a single scoped
# sudoers entry can allow it without granting anything else:
#   <user> ALL=(root) NOPASSWD: <repo>/tools/t2/net_shape.sh
#
# ---------------------------------------------------------------------------
# WHY THE feth DESIGN FAILED, AND WHAT REPLACED IT  (2026-08-03)
#
# The first version created a feth pair, addressed it 172.30.0.1/172.30.0.2, and
# pinged one end from the other. The negative control reported:
#
#     base     loss 100.0%  rtt ? ms          <- BEFORE any shaping
#     shaped   loss 100.0%  rtt ? ms
#     FAIL     delay did not take effect
#
# and correctly refused to let anything be measured. Two things were wrong, and
# only the second is obvious in hindsight:
#
#  1. Both addresses were local to this host. The kernel does not send a packet
#     out feth0 and back in feth1 to reach an address it already owns — it
#     short-circuits through the loopback path. And `pfctl -s Interfaces -v`
#     on this machine reports `lo0 (skip)`, so pf never sees that traffic at
#     all. Shaping feth would therefore have done nothing EVEN IF the pair had
#     been up: a clean-network result that looks like a pass. That is the exact
#     failure the negative control exists to catch, and it caught it.
#  2. The baseline itself was 100% loss, so the pair was not carrying anything
#     to begin with. Debugging that would have bought a rig that, per (1),
#     could not have shaped real traffic anyway.
#
# THE REPLACEMENT: shape an interface that carries traffic between two REAL
# machines. This host already has one — the iPhone is on `bridge100` via
# Internet Sharing. pf sees bridge100 (it is not in the skip list), the phone
# is a genuinely remote endpoint, and the packets have nowhere to short-circuit
# to. The rig stops being synthetic, which also makes every number it produces
# mean more, not less.
# ---------------------------------------------------------------------------
#
# dummynet is NOT netem. It has bw, delay, plr (i.i.d. Bernoulli) and queue.
# It has no correlated loss, no reordering, no duplication, no delay
# distribution. Profiles that need those are reported unsupported by the
# runner, never approximated silently.
# ---------------------------------------------------------------------------
# WHY THE ANCHOR VERSION DID NOT SHAPE, AND WHY `pfctl -f -` IS NOT THE FIX
# (2026-08-03, second post-mortem)
#
# After moving to bridge100 the selftest still reported no effect, and the
# repair that made it work was changing
#     ... | pfctl -a "$ANCHOR" -f -      (load into the anchor)
# to
#     ... | pfctl -f -                   (load into the MAIN ruleset)
#
# That produced a real 400 ms / 62.5% measurement — and two serious side
# effects, which is why it is not what this script does now:
#
#  1. It REPLACES the system's main ruleset. macOS /etc/pf.conf loads the
#     com.apple anchors that Internet Sharing's NAT and the application
#     firewall rely on. Overwriting it can break the very connection the phone
#     is using to be tested.
#  2. `teardown` stops working. It flushes the ANCHOR, so rules living in the
#     main ruleset survive it — the host stays shaped after the harness exits,
#     silently degrading every later measurement and ordinary use. A harness
#     whose cleanup does not clean up is worse than no harness.
#
# THE ACTUAL ROOT CAUSE: dummynet rules are only evaluated through a
# `dummynet-anchor` declaration. Loading them into an anchor that the main
# ruleset hooks with a plain `anchor "t2harness"` means they are never reached.
# (An earlier attempt sent `dummynet-anchor "t2harness"` through
# `pfctl -a t2harness -f -`, which put the declaration INSIDE the anchor
# instead of in the main ruleset — the right idea in the wrong place.)
#
# THE FIX: compose a ruleset that is the system's own /etc/pf.conf plus the two
# anchor declarations, load THAT, then fill the anchor. Teardown restores
# /etc/pf.conf verbatim, so the machine ends exactly where it started.
# ---------------------------------------------------------------------------
set -euo pipefail

ANCHOR=t2harness
SYS_CONF=/etc/pf.conf
ANCHOR_FILE=/etc/pf.anchors/t2harness
COMPOSED=/var/run/t2harness.pf.conf

# The interface carrying traffic to the device under test. Overridable so the
# same script works for a different bridge, a USB-ethernet adapter, or Wi-Fi.
IFACE="${T2_IFACE:-bridge100}"

usage() {
  cat >&2 <<'EOF'
usage: net_shape.sh <command> [args]
  setup                      ONCE per machine: declare the anchors in
                             /etc/pf.conf. The only step that reloads pf, and
                             therefore the only one needing an Internet Sharing
                             toggle afterwards.
  unsetup                    undo setup and restore /etc/pf.conf
  check                      report whether the interface exists and pf sees it
  shape <bw> <delay> <plr>   e.g. shape 64Kbit/s 60 0.05   ("-" leaves a field unset)
  block <proto|all>          drop traffic: udp | all
  whitelist <spec>           load the filtered-network rule set: only the
                             listed TCP ports and UDP 53 to the allowed host
                             pass, TCP to the reset port on any other host is
                             answered with a reset, every other inbound IPv4
                             packet is dropped silently, everything else the Mac
                             sends the peer leaves STATELESSLY (so the anchor
                             decides outbound too and nothing downstream can
                             create a state), IPv6 is dropped in both directions
                             (the pass rules are IPv4-only), and states that
                             existed before the load are killed.
                             spec: peer=<ip>,allow=<ip>,tcp=<p1>+<p2>[,rst=<port>][,udp=<port>]
                             peer and allow are IPv4 hosts (optional /1..32);
                             a wildcard address is refused. rst defaults to 443.
                             udp=<port> adds ONE more UDP port to the allowed
                             host (both directions). UDP 53 passes either way,
                             with or without this key; omitting udp= leaves the
                             rule text exactly as it was before the key existed.
  whitelist-print <spec>     print the same rule text and exit. No sudo, no
                             pfctl, no interface needed — this is what the unit
                             test pins, and it comes from the same function
                             that `whitelist` loads.
  teardown                   remove our rules and restore /etc/pf.conf
  restore                    same, usable after a hand-repair left pf altered
  status                     show current pipes and anchor rules

The interface defaults to bridge100 (the iPhone over Internet Sharing) and is
overridden with T2_IFACE, e.g.  T2_IFACE=en7 net_shape.sh shape - 200 0.3
EOF
  exit 2
}

require_iface() {
  if ! ifconfig "$IFACE" >/dev/null 2>&1; then
    echo "MISSING INTERFACE: $IFACE does not exist." >&2
    echo "Bring the device up (Internet Sharing on, phone joined), then re-run." >&2
    echo "Available: $(ifconfig -l)" >&2
    exit 4
  fi
  # pf silently ignores rules on a skipped interface, which would produce
  # clean-network numbers that look like a pass — the one outcome this harness
  # exists to make impossible.
  if pfctl -s Interfaces -v 2>/dev/null | grep -qE "^${IFACE} .*\(skip\)"; then
    echo "PF SKIPS $IFACE — shaping it would silently do nothing." >&2
    echo "Remove it from 'set skip on' in /etc/pf.conf, or pick another." >&2
    exit 5
  fi
}

check() {
  require_iface
  local addr
  addr=$(ifconfig "$IFACE" | awk '/inet /{print $2; exit}')
  echo "iface   $IFACE up, address ${addr:-none}"
  echo "pf      sees $IFACE (not skipped)"
  echo "peers   $(arp -an 2>/dev/null | grep -c "on $IFACE") entries on $IFACE"
  # A main ruleset that no longer matches /etc/pf.conf means a previous run —
  # or a manual repair — left this host altered. Say so, because the symptom
  # (broken Internet Sharing, or measurements that stay shaped) appears far
  # from the cause.
  if pfctl -s rules 2>/dev/null | grep -q 'dummynet'; then
    if ! pfctl -s Anchors 2>/dev/null | grep -q "$ANCHOR"; then
      echo "WARN    dummynet rules are in the MAIN ruleset, not the anchor."
      echo "        Restore with: sudo pfctl -f $SYS_CONF && sudo dnctl -f flush"
    fi
  fi
}

# Puts the host back exactly as macOS defines it. Separate from teardown so it
# can be run after any hand-repair, without needing the harness to have run.
# The heavy repair, for when a hand-edit or an older version of this script left
# rules in the MAIN ruleset. It reloads /etc/pf.conf, which is the one action
# that costs Internet Sharing its NAT — hence the warning, and hence it is not
# what teardown does.
restore() {
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  dnctl -f flush 2>/dev/null || true
  pfctl -f "$SYS_CONF"
  rm -f "$COMPOSED" "$ANCHOR_FILE" 2>/dev/null || true
  echo "restored: $SYS_CONF reloaded, pipes flushed"
  echo "NOTE: this reload drops Internet Sharing's dynamic NAT."
  echo "      Toggle Internet Sharing off/on to give the phone its link back."
}

# ---------------------------------------------------------------------------
# WHY NOTHING HERE RELOADS THE MAIN RULESET ANY MORE  (2026-08-03, third
# post-mortem — the one that cost the phone its internet)
#
# The previous version composed `/etc/pf.conf` + our anchor declarations and
# ran `pfctl -f` on it before every shape, and again on teardown. It loaded
# correctly and shaped correctly. It also took the phone offline and kept it
# there until Internet Sharing was toggled by hand.
#
# The reason is not in our rules. macOS Internet Sharing installs its NAT
# DYNAMICALLY into the `com.apple/*` anchor when sharing starts. `pfctl -f`
# rebuilds the main ruleset and re-reads `/etc/pf.anchors/com.apple` FROM DISK,
# where those dynamic rules do not exist — so every reload silently deletes the
# NAT that gives the phone its connection. The symptom (no internet on the
# phone) appears nowhere near the cause (a ruleset reload in a test harness),
# which is why it survived two rounds of fixing something else.
#
# So the anchor declarations are installed ONCE, by `setup`, and after that
# every operation is anchor-scoped: `pfctl -a t2harness -f ...` does not touch
# the main ruleset, does not re-read com.apple, and cannot disturb NAT.
# ---------------------------------------------------------------------------

MARKER='# --- t2harness anchors (tools/t2/net_shape.sh) ---'

hooks_installed() {
  grep -qF "$MARKER" "$SYS_CONF" 2>/dev/null
}

# One-time, explicit, and reversible. Kept as its own command precisely because
# it is the only step that edits a system file, and a step that dangerous
# should never happen as a side effect of running a test.
setup() {
  [ -r "$SYS_CONF" ] || { echo "MISSING $SYS_CONF" >&2; exit 6; }
  if hooks_installed; then
    echo "already set up: $SYS_CONF declares the $ANCHOR anchors"
  else
    cp "$SYS_CONF" "${SYS_CONF}.t2harness.bak"
    {
      echo ''
      echo "$MARKER"
      echo "dummynet-anchor \"$ANCHOR\""
      echo "anchor \"$ANCHOR\""
    } >>"$SYS_CONF"
    pfctl -f "$SYS_CONF" 2>/dev/null
    echo "installed: anchor declarations appended to $SYS_CONF"
    echo "backup:    ${SYS_CONF}.t2harness.bak"
  fi
  pfctl -E 2>/dev/null || true
  cat <<EOF

ONE THING TO DO BY HAND, ONCE, NOW:
  turn Internet Sharing OFF and ON again
    (System Settings -> General -> Sharing -> Internet Sharing)

This reload is the only one that will ever happen, and it is why the toggle is
needed: reloading pf drops the NAT that Internet Sharing installed dynamically.
From here on every shape and teardown touches ONLY the $ANCHOR anchor, so the
phone keeps its connection across every profile.
EOF
}

unsetup() {
  teardown >/dev/null 2>&1 || true
  if [ -f "${SYS_CONF}.t2harness.bak" ]; then
    cp "${SYS_CONF}.t2harness.bak" "$SYS_CONF"
    rm -f "${SYS_CONF}.t2harness.bak"
  else
    # No backup: strip our block in place rather than leaving it behind.
    #
    # awk, not `sed -i '' '/x/,+2d'` — that range syntax is GNU sed and BSD sed
    # (which is what macOS ships) rejects it. A cleanup path that only works on
    # the wrong platform is a cleanup path that does not work.
    awk -v m="$MARKER" '
      $0 == m { skip = 3 }
      skip > 0 { skip--; next }
      { print }
    ' "$SYS_CONF" >"${SYS_CONF}.t2tmp" && mv "${SYS_CONF}.t2tmp" "$SYS_CONF"
  fi
  pfctl -f "$SYS_CONF" 2>/dev/null || true
  echo "removed: $SYS_CONF no longer declares the $ANCHOR anchors"
  echo "toggle Internet Sharing off/on once more to restore NAT."
}

# Verifies the hooks exist. NEVER installs them, because installing means
# reloading, and reloading means the phone loses its connection mid-run.
ensure_hooks() {
  if ! hooks_installed; then
    cat >&2 <<EOF
NOT SET UP: $SYS_CONF does not declare the $ANCHOR anchors, so pf would never
evaluate our dummynet rules — shaping would silently do nothing.

Run once:   sudo $0 setup

That is the only step that reloads pf (and therefore the only step that needs
an Internet Sharing toggle afterwards). Every run after it leaves NAT alone.
EOF
    exit 7
  fi
  pfctl -E 2>/dev/null || true
}

load_anchor() {
  # The anchor file is written to disk rather than piped so `pfctl -a ... -s
  # rules` and a human both have something to inspect after the fact.
  printf '%s\n' "$1" >"$ANCHOR_FILE"
  pfctl -a "$ANCHOR" -f "$ANCHOR_FILE"
}

shape() {
  local bw=$1 delay=$2 plr=$3 scope_arg="${4:-}"
  require_iface
  local cfg=""
  [ "$bw" != "-" ] && cfg="$cfg bw $bw"
  [ "$delay" != "-" ] && cfg="$cfg delay $delay"
  [ "$plr" != "-" ] && cfg="$cfg plr $plr"
  # Two pipes so each direction is shaped independently; a single pipe would
  # halve the effective impairment and quietly flatter every result.
  dnctl pipe 1 config $cfg
  dnctl pipe 2 config $cfg
  ensure_hooks
  # WHAT IS SHAPED, AND WHY NOT EVERYTHING (2026-08-03)
  #
  # The first version shaped `all` on this interface. That is every packet the
  # phone sends, including its ordinary internet access over Internet Sharing —
  # so running a profile took the phone offline. Two costs, one of them not
  # obvious:
  #   · the phone's browsing dies during a run, which is merely annoying;
  #   · iOS re-verifies a free-Personal-Team signature against Apple's servers
  #     each time the app launches, so a shaped-to-death link makes the app
  #     refuse to start with "Unable to Verify" — the test never even runs, and
  #     the failure looks like a rig problem rather than a policy one.
  #
  # So the impairment is scoped. T2_SHAPE_SPEC selects what to shape; the
  # default leaves everything else untouched:
  #   host <ip>   only traffic to/from that address (the test peer)
  #   port <n>    only that port (the signaling relay, say)
  #   all         the old behaviour, kept for a deliberate full blackout
  # pf has no `or` between two from/to clauses — that was a syntax error, and
  # pfctl reports it as a line number in the generated anchor rather than as
  # anything to do with the peer. The direction keyword already does the work:
  # `in` on this interface is traffic arriving FROM the phone, `out` is traffic
  # going TO it, so one address on the correct side of each rule covers both
  # directions without a disjunction.
  # ---------------------------------------------------------------------
  # WHY THE DEFAULT IS "UDP, EXCEPT mDNS"  (2026-08-03, fourth post-mortem)
  #
  # Shaping every packet to the phone also shapes the channel `flutter test`
  # uses to DRIVE the test: the Dart VM Service and the mDNS query that finds
  # it both cross bridge100. The measurements said so plainly:
  #
  #   latency (delay 900, RTT 1800)   PASS   236 s
  #   normal  (delay 40,  RTT 81)     FAIL   726 s   "mDNS query ... failed"
  #   bandwidth (32 kbit/s)           FAIL   711 s   "mDNS query ... failed"
  #
  # The HARSHEST delay passed and a mild one failed, which rules out the app
  # and rules out impairment level. What actually happened is that discovery
  # failed, flutter retried for ~12 minutes, and the run was scored FAIL — a
  # tooling failure wearing an app failure's label. At 32 kbit/s the debugger
  # was starved outright.
  #
  # So the default impairs the DATA plane and leaves the CONTROL plane alone:
  # UDP (WebRTC media and data channels) minus mDNS on 5353. The VM Service is
  # TCP, so it is untouched. Signalling over TLS is also untouched by default —
  # if a profile needs it impaired, name it explicitly rather than catching it
  # by accident, because catching the debugger by accident is what produced two
  # false FAILs.
  #
  #   T2_SHAPE_SPEC=<pf clause>   shape exactly this
  #   T2_SHAPE_ALL=1              every packet, debugger included (blackout)
  # ---------------------------------------------------------------------
  # ICMP IS SHAPED TOO, AND THAT IS NOT A DETAIL  (2026-08-03, fifth
  # post-mortem — the shortest-lived bug in this file's history)
  #
  # Scoping the impairment to UDP fixed the debugger starvation, and broke the
  # VERIFICATION in the same stroke: every check in this harness measures with
  # `ping`, which is ICMP. The next matrix run reported
  #
  #     verified  rtt 0.790 ms
  #     ERROR: shaping did not take effect (rtt 0.790 < 40)
  #
  # while the shaping was, in fact, perfectly in effect — on UDP, which ping
  # never touches. The rule and the ruler had drifted apart, and the harness
  # correctly refused to proceed on a measurement it could not confirm.
  #
  # ICMP joins the shaped set because it costs nothing to impair (nothing in
  # the toolchain depends on it: the Dart VM Service is TCP and mDNS is UDP
  # 5353) and because a verification probe must travel the same road as the
  # traffic whose impairment it certifies.
  local peer="${T2_PEER:-}"
  local shape_all="${T2_SHAPE_ALL:-0}"
  local tcp_ports="${T2_SHAPE_TCP_PORT:-}"
  # THE SCOPE AS AN ARGUMENT (2026-09-05). The sudoers rule that lets the
  # harness run this script without a password strips every environment
  # variable ("you are not allowed to set ... T2_PEER, T2_SHAPE_TCP_PORT"),
  # so the env forms above only work when run as root directly. The fourth
  # positional argument carries the same choice through sudo:
  #   all                      every packet on the interface
  #   peer=<ip>                UDP (not mDNS) and ICMP to/from that address
  #   peer=<ip>,tcp=<p1>+<p2>  the same plus TCP on those ports
  case "$scope_arg" in
    '') ;;
    all) shape_all=1 ;;
    peer=*)
      peer=${scope_arg#peer=}; peer=${peer%%,*}
      case "$scope_arg" in
        *,tcp=*) tcp_ports="{ $(printf '%s' "${scope_arg#*,tcp=}" | tr '+' ',' | sed 's/,/, /g') }" ;;
      esac ;;
    *) echo "unknown scope: $scope_arg" >&2; return 2 ;;
  esac
  local rules=""
  if [ -n "${T2_SHAPE_SPEC:-}" ]; then
    rules="dummynet in  quick on $IFACE ${T2_SHAPE_SPEC} pipe 1
dummynet out quick on $IFACE ${T2_SHAPE_SPEC} pipe 2"
  elif [ "$shape_all" = 1 ]; then
    if [ -n "$peer" ]; then
      rules="dummynet in  quick on $IFACE from $peer to any pipe 1
dummynet out quick on $IFACE from any to $peer pipe 2"
    else
      rules="dummynet in  quick on $IFACE all pipe 1
dummynet out quick on $IFACE all pipe 2"
    fi
  elif [ -n "$peer" ]; then
    rules="dummynet in  quick on $IFACE proto udp from $peer to any port != 5353 pipe 1
dummynet out quick on $IFACE proto udp from any to $peer port != 5353 pipe 2
dummynet in  quick on $IFACE proto icmp from $peer to any pipe 1
dummynet out quick on $IFACE proto icmp from any to $peer pipe 2"
    # SIGNALLING IS TCP, AND AN UNSHAPED PATH IS AN UNSHAPED METRIC
    # (2026-08-05). With the relay moved off-device (h2_run.sh hosts it on
    # the Mac), the ack-RTT probes travel wss/TCP to ONE well-known port.
    # Shaping all TCP would starve the Dart VM Service again (fourth
    # post-mortem above), so the scope is exactly that port: set
    # T2_SHAPE_TCP_PORT=<relay port> and the signalling path is impaired
    # while the debugger stays untouched. Expected consequence, not a bug:
    # under heavy-loss profiles TCP retransmission may stall signalling long
    # before media degrades.
    if [ -n "$tcp_ports" ]; then
      rules="$rules
dummynet in  quick on $IFACE proto tcp from $peer to any port ${tcp_ports} pipe 1
dummynet out quick on $IFACE proto tcp from any port ${tcp_ports} to $peer pipe 2"
    fi
  else
    rules="dummynet in  quick on $IFACE proto udp from any to any port != 5353 pipe 1
dummynet out quick on $IFACE proto udp from any to any port != 5353 pipe 2
dummynet in  quick on $IFACE proto icmp all pipe 1
dummynet out quick on $IFACE proto icmp all pipe 2"
  fi
  load_anchor "$rules"
  echo "shaped:$cfg on $IFACE"
}

block() {
  local what=$1
  require_iface
  ensure_hooks
  if [ "$what" = udp ]; then
    load_anchor "block drop quick on $IFACE proto udp all"
  else
    load_anchor "block drop quick on $IFACE all"
  fi
  echo "blocked:$what on $IFACE"
}

# ---------------------------------------------------------------------------
# THE FILTERED-NETWORK PROFILE  (2026-09-05)
#
# `whitelist` is a FILTER, not an impairment: no pipes, no dummynet, nothing
# for dnctl to flush. It states what may cross bridge100 and answers everything
# else, so a run can show the door standing open for allowed traffic in the
# same second the app rendezvouses through it.
#
# ORDER IS THE RULE. pf with `quick` takes the first match, so the four
# stateful pass rules come first (an allowed port keeps passing even if it is
# the same number as the reset port), then the stateless catch-all pass toward
# the peer, then the reset for TCP to the reset port on any other host, then
# the silent inbound catch-all drop that swallows QUIC on UDP 443, ICMP and
# every other TCP port, then both inet6 drops. An allowed flow's replies ride
# the state table (`keep state`); the stateless pass creates no state, so a
# blocked flow's answer has nothing to ride and meets the inbound drop. That
# pass is what keeps the anchor self-contained — see the comment on that rule
# for what pf did without it, and why a drop there was the wrong decision.
#
# STATES OUTLIVE RULES. `pfctl -f` on the anchor replaces rule text and touches
# no state entry, and a state is consulted before any rule — so a connection
# established before the load keeps crossing a filter that would now refuse it
# (measured 2026-09-13: an ESTABLISHED NAT state for the phone survived the
# load while the reset rule showed Packets 0). `whitelist` therefore kills the
# peer's states right after loading; see kill_peer_states().
#
# BOTH ADDRESS FAMILIES, OR THE DOOR IS NOT SHUT (2026-09-05). Every rule above
# names an IPv4 literal, so pf compiles each one with af=AF_INET and none of
# them can match an IPv6 packet. bridge100 carries a live IPv6 link-local and
# the phone configures its own, so the IPv4 catch-all alone would leave that
# family to the main ruleset, which has no default block: the phone could reach
# any Mac listener over fe80::...%bridge100 while the row still printed "all
# else dropped". The last two rules close the family in both directions — an
# outbound `inet6 all` drop and an inbound `inet6 from any to any` — because
# the peer's IPv6 addresses are not knowable from the spec, nothing on this
# bridge is allowed to use that family at all, and an undecided outbound v6
# packet state-creates in the Internet Sharing anchor exactly as an undecided
# IPv4 one did (measured 2026-09-13).
#
# The peer and allow addresses are validated (valid_addr) for the same reason
# the ports are: they are interpolated straight into the rule text, so a value
# like `any` or `0.0.0.0/0` would compile into a ruleset that reads as a
# whitelist and behaves as its inverse.
#
# The argument is positional and comma-separated for the same reason `shape`'s
# scope argument is: the scoped sudoers entry strips the environment, so a
# T2_-style variable would never reach this script through sudo.
#
# whitelist_rules() is the SINGLE SOURCE of the rule text. `whitelist` loads
# what it returns and `whitelist-print` prints what it returns, so the text a
# test pins and the text pf receives cannot drift apart.
# ---------------------------------------------------------------------------

valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# An address that reaches a pf rule must be a real IPv4 host, because the rule
# text is built by string interpolation: a value like `any` or `0.0.0.0/0`
# produces a syntactically valid ruleset that says the opposite of a whitelist
# (`pass ... from $peer to any port { 4443 }` opens that port on every host,
# and `block drop ... from any to any` drops the interface). Accepted: a dotted
# quad with each octet 0..255, optionally followed by /1../32. Rejected: the
# unspecified address 0.0.0.0 in any form, and a /0 prefix — both are the
# wildcard this profile exists to exclude.
valid_addr() {
  local a="${1:-}" host="" plen=""
  case "$a" in
    *[!0-9./]*) return 1 ;;
    */*/*) return 1 ;;
    .*|*.|*..*) return 1 ;;
    */*) host=${a%%/*}; plen=${a#*/}
         case "$plen" in
           ''|*[!0-9]*) return 1 ;;
         esac
         [ "${#plen}" -le 2 ] || return 1
         [ "$plen" -ge 1 ] && [ "$plen" -le 32 ] || return 1 ;;
    *) host=$a ;;
  esac
  local rest="$host" part i=0
  while [ -n "$rest" ]; do
    part=${rest%%.*}
    if [ "$part" = "$rest" ]; then rest=""; else rest=${rest#*.}; fi
    i=$((i + 1))
    [ "$i" -le 4 ] || return 1
    case "$part" in
      ''|*[!0-9]*) return 1 ;;
      0[0-9]*) return 1 ;;
    esac
    [ "${#part}" -le 3 ] || return 1
    [ "$part" -le 255 ] || return 1
  done
  [ "$i" -eq 4 ] || return 1
  [ "$host" != "0.0.0.0" ] || return 1
  return 0
}

whitelist_rules() {
  local arg="${1:-}" peer="" allow="" tcp="" rst="443" udp=""
  local rest="$arg" kv key val
  while [ -n "$rest" ]; do
    kv=${rest%%,*}
    if [ "$kv" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
    case "$kv" in
      *=*) key=${kv%%=*}; val=${kv#*=} ;;
      *) echo "whitelist: not a field: '$kv'" >&2; return 2 ;;
    esac
    case "$key" in
      peer) peer=$val ;;
      allow) allow=$val ;;
      tcp) tcp=$val ;;
      rst) rst=$val ;;
      # One extra UDP port to the allowed host. The rig's authoritative DNS
      # responder cannot bind 53 without root, so a filter that only ever
      # allowed 53 left its lane with nothing to answer it.
      udp) udp=$val ;;
      *) echo "whitelist: unknown field: '$key'" >&2; return 2 ;;
    esac
  done
  [ -n "$peer" ] || { echo "whitelist: missing peer=<ip>" >&2; return 2; }
  [ -n "$allow" ] || { echo "whitelist: missing allow=<ip>" >&2; return 2; }
  [ -n "$tcp" ] || { echo "whitelist: missing tcp=<p1>[+<p2>...]" >&2; return 2; }
  valid_addr "$peer" || { echo "whitelist: bad peer address: '$peer' (IPv4 host, optional /1..32, not 0.0.0.0 and not a wildcard)" >&2; return 2; }
  valid_addr "$allow" || { echo "whitelist: bad allow address: '$allow' (IPv4 host, optional /1..32, not 0.0.0.0 and not a wildcard)" >&2; return 2; }
  valid_port "$rst" || { echo "whitelist: bad rst port: '$rst' (1..65535)" >&2; return 2; }
  [ -z "$udp" ] || valid_port "$udp" || { echo "whitelist: bad udp port: '$udp' (1..65535)" >&2; return 2; }
  local ports="$tcp" p list=""
  while [ -n "$ports" ]; do
    p=${ports%%+*}
    if [ "$p" = "$ports" ]; then ports=""; else ports=${ports#*+}; fi
    valid_port "$p" || { echo "whitelist: bad tcp port: '$p' (1..65535)" >&2; return 2; }
    if [ -z "$list" ]; then list="$p"; else list="$list, $p"; fi
  done
  # Printed in four statements, ONE order: every stateful pass rule, then the
  # stateless catch-all pass toward the peer, then the reset, then the inbound
  # IPv4 catch-all drop, then both inet6 drops. Order is the rule under `quick`
  # — a stateful pass that landed after the stateless one would never be
  # reached, and its flow would lose the state its reply rides on. The optional
  # udp= pass sits with the other stateful passes.
  printf '%s\n' \
"pass  out quick on $IFACE proto tcp from $allow to $peer port { $list } keep state" \
"pass  in  quick on $IFACE proto tcp from $peer to $allow port { $list } keep state" \
"pass  out quick on $IFACE proto udp from $allow to $peer port 53 keep state" \
"pass  in  quick on $IFACE proto udp from $peer to $allow port 53 keep state"
  if [ -n "$udp" ]; then
    printf '%s\n' \
"pass  out quick on $IFACE proto udp from $allow to $peer port $udp keep state" \
"pass  in  quick on $IFACE proto udp from $peer to $allow port $udp keep state"
  fi
  # THE ANCHOR MUST DECIDE OUTBOUND TOO, AND THE DECISION IS A STATELESS PASS
  # (measured 2026-09-13). Every rule here used to be `in`, on the theory that
  # replies ride the state table and nothing else needs saying. pf proved
  # otherwise on the rig. pf consults the state table BEFORE any rule, so a
  # packet that matches a state is passed with nothing evaluated; and a
  # Mac-originated SYN to a port that is not on the allow list matched no rule
  # in this anchor, so evaluation fell through to the Internet Sharing anchor
  # that macOS loads AFTER t2harness, whose `pass on bridge100 all flags any
  # keep state` created a state for the flow. The phone's reset then came back
  # ON THAT STATE. The rule counters carry the signature: `pass out quick ...
  # port = 4443` at Evaluations 154, while `block drop in quick ... from <peer>
  # to any` sat at Evaluations 0 Packets 0, and `pfctl -ss` listed the Internet
  # Sharing states. The door probe saw the blocked port answer `refused` in
  # 1001 ms where the row claims a timeout, so the whitelist profile has never
  # produced a row.
  #
  # The first repair was `block drop out quick ... to $peer`, and it was the
  # wrong decision: pf refuses the packet inside ip_output, so connect() fails
  # LOCALLY with an errno, tcp_door_probe.py maps that to `error:<n>` — still a
  # failed verdict — and the row would be claiming a fact about the wire that
  # never reached the wire. A STATELESS pass is the decision that matches what
  # the row says: the SYN still leaves the Mac, `quick` is final for the other
  # anchors and the main ruleset so nothing downstream can state-create it, and
  # `no state` leaves the phone's reset with no state to ride — it falls to the
  # inbound catch-all below and is dropped silently, which is the timeout the
  # probe is written to see.
  #
  # It cannot affect an allowed flow: that flow's SYN matched a `keep state`
  # pass ABOVE this line, and every later packet of it, in either direction, is
  # passed by that state without any rule being evaluated.
  printf '%s\n' \
"pass  out quick on $IFACE inet from $allow to $peer no state"
  # `flags any` on the Internet Sharing pass means even a mid-stream packet
  # creates state there, so the inbound catch-all has to decide EVERY inbound
  # IPv4 packet on this interface, not only the ones whose source is the peer
  # literal — a second address on the bridge was otherwise undecided here and
  # state-created downstream. IPv6 is closed in BOTH directions for the reason
  # the IPv4 rules cannot close it: every rule above names an IPv4 literal, so
  # pf compiles it af=AF_INET, and base_nat66 would state-create a
  # Mac-originated v6 flow exactly as base_v4 did for IPv4.
  printf '%s\n' \
"block return-rst in quick on $IFACE proto tcp from $peer to any port $rst" \
"block drop        in quick on $IFACE inet from any to any" \
"block drop        out quick on $IFACE inet6 all" \
"block drop        in quick on $IFACE inet6 from any to any"
}

# Pulls peer= back out of a spec that whitelist_rules() has already validated,
# so the caller does not parse it twice and cannot disagree with the rule text
# about which address the peer is.
spec_peer() {
  local rest="${1:-}" kv
  while [ -n "$rest" ]; do
    kv=${rest%%,*}
    if [ "$kv" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
    case "$kv" in
      peer=*) printf '%s\n' "${kv#peer=}"; return 0 ;;
    esac
  done
  return 1
}

# Loading rules does not flush states, and pf checks the state table before any
# rule — so without this a flow established before the profile was loaded keeps
# crossing a filter that would now refuse it, and the row's claim about what may
# cross is false for that flow. Two kills: states whose source is the peer, and
# states from anywhere TO the peer. pfctl exits non-zero when there is nothing
# to kill, which is not an error here. Its message is `killed N states from ...`
# and N is summed, so the caller prints one honest number rather than two pfctl
# lines.
kill_peer_states() {
  local peer="$1" out total=0 n
  out=$( { pfctl -k "$peer" 2>&1 || true; pfctl -k 0.0.0.0/0 -k "$peer" 2>&1 || true; } )
  for n in $(printf '%s\n' "$out" | sed -n 's/^killed \([0-9][0-9]*\) states.*/\1/p'); do
    total=$((total + n))
  done
  printf '%s\n' "$total"
}

whitelist() {
  local rules peer killed
  rules=$(whitelist_rules "${1:-}") || exit $?
  peer=$(spec_peer "${1:-}")
  require_iface
  ensure_hooks
  load_anchor "$rules"
  killed=$(kill_peer_states "$peer")
  echo "whitelist: loaded on $IFACE"
  echo "whitelist: killed $killed pre-existing states involving $peer"
}

whitelist_print() {
  local rules
  rules=$(whitelist_rules "${1:-}") || exit $?
  printf '%s\n' "$rules"
}

teardown() {
  # Cleanup-first and idempotent on purpose: a crashed run must be recoverable
  # by running this one command, and running it twice must be harmless.
  #
  # It flushes OUR anchor and OUR pipes and nothing else. It deliberately does
  # not reload /etc/pf.conf: that reload is what deleted Internet Sharing's
  # dynamic NAT and took the phone offline. Emptying the anchor removes every
  # rule we ever added, so a reload buys nothing and costs the connection.
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  dnctl -f flush 2>/dev/null || true
  rm -f "$ANCHOR_FILE" 2>/dev/null || true
  echo "teardown: anchor flushed, pipes flushed (NAT and system rules untouched)"
}

status() {
  echo "--- pipes ---"; dnctl list 2>/dev/null || echo "(none)"
  echo "--- anchor $ANCHOR ---"; pfctl -a "$ANCHOR" -s rules 2>/dev/null || echo "(none)"
  echo "--- interface ---"; ifconfig "$IFACE" 2>/dev/null | head -4 || echo "(absent)"
}

[ $# -ge 1 ] || usage
case "$1" in
  setup) setup ;;
  unsetup) unsetup ;;
  check) check ;;
  shape) [ $# -eq 4 ] || [ $# -eq 5 ] || usage; shape "$2" "$3" "$4" "${5:-}" ;;
  block) [ $# -eq 2 ] || usage; block "$2" ;;
  whitelist) [ $# -eq 2 ] || usage; whitelist "$2" ;;
  whitelist-print) [ $# -eq 2 ] || usage; whitelist_print "$2" ;;
  teardown) teardown ;;
  restore) restore ;;
  status) status ;;
  # Read-only: the MAIN ruleset in evaluation order, so a rule of the host's
  # own (Internet Sharing loads its own anchors) that passes traffic with
  # `quick` before the harness anchor is visible instead of inferred.
  rules) pfctl -sr 2>&1; echo "--- anchors ---"; pfctl -sA 2>&1
         for a in $(pfctl -sA 2>/dev/null); do echo "--- anchor $a ---"; pfctl -a "$a" -sr 2>&1; done ;;
  # Read-only: per-rule evaluation/packet counters of the harness anchor and
  # the state table entries that involve the peer — whether a packet is
  # passed by an existing state before any rule is consulted, and whether
  # the block rules are evaluated at all, is read here rather than guessed.
  counters) echo "--- t2harness rules with counters ---"; pfctl -a t2harness -vvsr 2>&1
            echo "--- states involving ${T2_PEER:-192.168.2.2} ---"; pfctl -ss 2>&1 | grep -F "${T2_PEER:-192.168.2.2}"
            echo "--- nested apple anchors ---"
            for a in $(pfctl -a 'com.apple' -sA 2>/dev/null) $(pfctl -a 'com.apple.internet-sharing' -sA 2>/dev/null); do
              echo "--- anchor $a ---"; pfctl -a "$a" -sr 2>&1
            done ;;
  *) usage ;;
esac
