#!/usr/bin/env bash
# preflight.sh — check every precondition the H2 matrix depends on, in ~90 s,
# before an hour is spent discovering one of them the hard way.
#
# WHY THIS EXISTS, FROM THE RECORD. `h2_results.tsv` currently holds nine rows.
# Six are not results:
#
#   FAIL  "Because reference_app requires SDK version ^3.12.2, version solving
#          failed"                              -> pub ran under the wrong SDK
#   FAIL  "The mDNS query for an attached iOS device failed"
#                                               -> Personal Hotspot / iPhone USB
#   INVALID/UNROUTED  "only 1 packet crossed bridge100"
#                                               -> the test never used the path
#
# Every one of them was knowable in under two minutes and cost between 15 s and
# 12 MINUTES of a shaped run to find out. A matrix row that reports on the rig
# is worse than no row: it looks like data, it goes in a table, and it has to be
# argued back out later.
#
# This script asserts the preconditions and nothing else. It shapes nothing,
# runs no test, and changes no state. It is safe to run at any time, and it does
# NOT need root for most checks — the ones that do are reported as UNKNOWN
# rather than skipped silently, because "I could not check" and "it is fine" are
# different answers.
#
#   tools/t2/preflight.sh              # as your user: most checks
#   sudo tools/t2/preflight.sh         # adds the pf/dnctl checks
#
# Exit: 0 all green · 1 at least one BLOCKER · 2 only WARNINGs.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
APP="$REPO/apps/reference_app"
DEVICE_ARG="${1:-${T2_DEVICE:-}}"

BLOCKERS=0
WARNINGS=0

ok()    { printf '  \033[32mOK\033[0m       %s\n' "$*"; }
warn()  { printf '  \033[33mWARN\033[0m     %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
block() { printf '  \033[31mBLOCKER\033[0m  %s\n' "$*"; BLOCKERS=$((BLOCKERS+1)); }
unknown() { printf '  \033[36m?\033[0m        %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

echo "=============================================================="
echo " H2 preflight · $(date -u +%FT%TZ)"
echo "=============================================================="

# --- 1. toolchain ----------------------------------------------------------
section "1. toolchain"

FLUTTER_BIN=$(command -v flutter || true)
if [ -z "$FLUTTER_BIN" ]; then
  block "flutter not on PATH"
else
  ok "flutter at $FLUTTER_BIN"
fi

# THE SDK TRAP, CHECKED DIRECTLY. `sudo` resets PATH via secure_path on many
# setups, so root's `flutter` can be a DIFFERENT installation from yours — and
# a different Dart SDK, which is exactly what "requires SDK version ^3.12.2,
# version solving failed" reports. h2_run.sh builds as $SUDO_USER, but any pub
# resolution that slips through as root hits this.
if [ -n "$FLUTTER_BIN" ]; then
  ROOT_FLUTTER=$(sudo -n env PATH="$PATH" command -v flutter 2>/dev/null || true)
  if [ -z "$ROOT_FLUTTER" ]; then
    unknown "cannot check root's flutter without a live sudo session"
  elif [ "$ROOT_FLUTTER" != "$FLUTTER_BIN" ]; then
    block "root resolves a DIFFERENT flutter: $ROOT_FLUTTER (yours: $FLUTTER_BIN)"
  else
    ok "root resolves the same flutter"
  fi

  SDK=$("$FLUTTER_BIN" --version 2>/dev/null | head -1)
  ok "${SDK:-flutter version unreadable}"
fi

command -v tcpdump >/dev/null && ok "tcpdump present" || block "tcpdump missing (traffic verification needs it)"
command -v python3 >/dev/null && ok "python3 present" || block "python3 missing (h2_run.sh parses SLA_SUMMARY with it)"
command -v dnctl   >/dev/null && ok "dnctl present"   || block "dnctl missing (no dummynet, no shaping)"

# --- 2. the repository resolves ------------------------------------------
section "2. the repository resolves"

if [ ! -d "$APP" ]; then
  block "apps/reference_app not found at $APP"
else
  # Resolve dependencies AS YOUR USER now, so the shaped run never has to.
  # This is the check that would have caught six of the nine bad rows: if
  # version solving fails, it fails here in 10 s instead of after a build.
  if ( cd "$APP" && "$FLUTTER_BIN" pub get >/tmp/preflight_pubget.log 2>&1 ); then
    ok "flutter pub get resolves in apps/reference_app"
  else
    block "pub get FAILED — see /tmp/preflight_pubget.log"
    sed -n '1,6p' /tmp/preflight_pubget.log | sed 's/^/           /'
  fi

  TEST_FILE="$APP/integration_test/sla_thresholds_test.dart"
  [ -f "$TEST_FILE" ] && ok "sla_thresholds_test.dart present" \
    || block "integration_test/sla_thresholds_test.dart missing"

  # A build directory owned by root is the residue of an earlier sudo run and
  # makes the next build fail in a way that reads like a code error.
  if [ -d "$APP/build" ] && [ -n "$(find "$APP/build" -maxdepth 2 -user root -print -quit 2>/dev/null)" ]; then
    block "apps/reference_app/build contains root-owned files: sudo rm -rf '$APP/build'"
  else
    ok "no root-owned build residue"
  fi
fi

# --- 3. the device ---------------------------------------------------------
section "3. the device"

if [ -n "$FLUTTER_BIN" ]; then
  DEVJSON=$("$FLUTTER_BIN" devices --machine 2>/dev/null || true)
  IOS_COUNT=$(printf '%s' "$DEVJSON" | grep -c '"targetPlatform": *"ios' || true)
  # A device running a newer iOS than the installed SDK supports is a real
  # source of debugserver instability, and it is silent: the build succeeds,
  # the app launches, and the debug connection drops minutes later. Reported
  # rather than blocked, because it is often the only device available.
  DEV_OS=$(printf '%s' "$DEVJSON" | python3 -c '
import json,sys
try: devices = json.load(sys.stdin)
except Exception: sys.exit(0)
for d in devices:
    if str(d.get("targetPlatform","")).startswith("ios"):
        print(d.get("sdk","")); break
' 2>/dev/null)
  SDK_MAX=$(ls -1 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/ 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -1)
  if [ -n "$DEV_OS" ] && [ -n "$SDK_MAX" ]; then
    DEV_MAJMIN=$(printf '%s' "$DEV_OS" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$DEV_MAJMIN" ] && \
       [ "$(printf '%s\n%s\n' "$SDK_MAX" "$DEV_MAJMIN" | sort -V | tail -1)" = "$DEV_MAJMIN" ] && \
       [ "$SDK_MAX" != "$DEV_MAJMIN" ]; then
      warn "device runs iOS $DEV_MAJMIN but the newest SDK here is $SDK_MAX"
      echo "           an SDK older than the device is a known cause of" >&2
      echo "           debugserver dropping mid-session. Update Xcode if the" >&2
      echo "           stalls persist after clearing stale debuggers." >&2
    else
      ok "device iOS $DEV_MAJMIN is within the installed SDK ($SDK_MAX)"
    fi
  fi

  if [ "${IOS_COUNT:-0}" -eq 0 ]; then
    block "no iOS device visible to flutter — attach by cable and UNLOCK it"
  else
    # Parsed, not grepped. `"id"` appears BEFORE `"targetPlatform"` in the
    # object, so a `grep -A` window after the platform line never sees it and
    # the first version of this printed "unknown id" while a perfectly good
    # device was attached. python3 is already a hard requirement above, so
    # there is no reason to guess at JSON with line offsets.
    IOS_ID=$(printf '%s' "$DEVJSON" | python3 -c '
import json,sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    if str(d.get("targetPlatform","")).startswith("ios"):
        print(d.get("id",""))
        break
' 2>/dev/null)
    if [ -n "$IOS_ID" ]; then
      ok "iOS device visible: $IOS_ID"
    else
      warn "an iOS device is present but its id could not be read"
    fi
    if [ -n "$DEVICE_ARG" ] && [ "$DEVICE_ARG" != "$IOS_ID" ]; then
      warn "you passed device '$DEVICE_ARG' but flutter sees '$IOS_ID'"
    fi
  fi
fi

# TWO DEBUGGERS, ONE DEVICE.
#
# On 2026-08-04T00:21 Xcode reported "The LLDB RPC server has exited
# unexpectedly" (IDEDebugSessionErrorDomain code 20) after a 612-second
# session. It is tempting to read that as the harness crashing, and it is not:
# three fields in the crash metadata say whose session it was.
#
#   launchSession_schemeCommand      = Run     (not Test)
#   param_testing_launchedForTesting = 0
#   param_testing_usingCLI           = 0
#
# That is somebody pressing Run in the Xcode GUI. `flutter test` from
# `h2_run.sh` sets usingCLI and launchedForTesting, and never uses Xcode's
# debugger at all. So the crash did not stop the matrix — but it is exactly
# where the matrix's trouble came FROM: a crashed RPC server leaves the app
# installed and a debug session half-open on the device, and the next harness
# run inherits a phone whose native audio and WebRTC sockets were never
# released. That is the PLATFORM-STALL in `setLocalDescription`.
#
# The Xcode session also had every expensive diagnostic on —
# viewDebugging with an injected dylib, GPU validation, queue debugging,
# MallocStackLogging for XPC — which is why it lasted ten minutes and then
# did not.
#
# So the precondition is not "Xcode must be closed". It is "nothing else may
# be holding the device". Killing Xcode outright would also discard whatever
# is unsaved in it, which is a rude fix for a checkable condition.
DEBUGGERS=$(pgrep -f 'lldb-rpc-server|debugserver' 2>/dev/null | wc -l | tr -d ' ')
XCODE_UP=$(pgrep -f 'Xcode.app/Contents/MacOS/Xcode' 2>/dev/null | head -1)
if [ "${DEBUGGERS:-0}" -gt 0 ]; then
  block "${DEBUGGERS} debugger process(es) still hold the device"
  echo "           sudo killall -9 lldb debugserver lldb-rpc-server" >&2
  echo "           then close the app on the phone via the app switcher." >&2
elif [ -n "$XCODE_UP" ]; then
  warn "Xcode is open (pid $XCODE_UP). Stop any Run session (Cmd-period)"
  echo "           before the matrix; two debuggers on one device is the" >&2
  echo "           documented cause of the native-stack stalls." >&2
else
  ok "no debugger is holding the device"
fi

# THE SEVEN-DAY CLOCK.
#
# This app is signed with a free Apple Personal Team. That profile lives for
# SEVEN DAYS, not a year: measured on this machine, created 2026-08-03,
# expires 2026-08-10. When it lapses, Xcode regenerates it with a new UUID,
# iOS sees a new developer, and the trust the phone granted last week no
# longer applies — which is why the "Trust this developer" dance recurs and
# why it feels random rather than scheduled.
#
# Left unchecked it does not fail politely: the profile expires, the app
# refuses to launch, and the matrix spends its first three minutes finding out.
# The date is on disk and costs nothing to read.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE=$(ls -t "$PROFILE_DIR"/*.mobileprovision 2>/dev/null | head -1)
if [ -z "$PROFILE" ]; then
  warn "no provisioning profile found — open the project in Xcode once"
else
  PROF_INFO=$(security cms -D -i "$PROFILE" 2>/dev/null | python3 -c '
import sys, plistlib, datetime
try:
    d = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
exp = d.get("ExpirationDate")
created = d.get("CreationDate")
if exp is None:
    sys.exit(0)
left = (exp - datetime.datetime.now()).days
ttl = (exp - created).days if created else -1
print(f"{left}\t{exp:%Y-%m-%d}\t{ttl}")
' 2>/dev/null)
  if [ -z "$PROF_INFO" ]; then
    unknown "could not read the provisioning profile's expiry"
  else
    DAYS_LEFT=$(printf '%s' "$PROF_INFO" | cut -f1)
    EXP_DATE=$(printf '%s' "$PROF_INFO" | cut -f2)
    TTL=$(printf '%s' "$PROF_INFO" | cut -f3)
    if [ "${DAYS_LEFT:-0}" -lt 0 ]; then
      block "signing profile EXPIRED on $EXP_DATE — the app will not launch"
      echo "           open apps/reference_app/ios/Runner.xcworkspace in Xcode," >&2
      echo "           build once to regenerate, then re-Trust on the phone." >&2
    elif [ "${DAYS_LEFT:-99}" -le 1 ]; then
      warn "signing profile expires $EXP_DATE (${DAYS_LEFT}d) — renew before an hour-long matrix"
    else
      ok "signing profile valid until $EXP_DATE (${DAYS_LEFT}d left)"
    fi
    if [ "${TTL:-0}" -le 8 ] && [ "${TTL:-0}" -gt 0 ]; then
      echo "           note: ${TTL}-day lifetime = free Personal Team. A paid" >&2
      echo "           account issues 365-day profiles and ends the weekly" >&2
      echo "           re-Trust cycle entirely." >&2
    fi
  fi
fi

# TRUSTING A DEVELOPER NEEDS THE PHONE TO REACH APPLE.
#
# "Unable to Trust ... could not be trusted" is almost never a certificate
# problem; it is the phone failing to validate the certificate ONLINE. The
# phone's only link during this work is the Mac's Internet Sharing, and the
# harness shapes that same interface — so the two interact, and the symptom
# ("sometimes it works") is exactly what an intermittently-reachable Apple
# looks like.
#
# net_shape.sh already scopes impairment to UDP for this reason (its fourth
# post-mortem). What it cannot do is give the Mac an upstream it does not have.
if ifconfig bridge100 >/dev/null 2>&1; then
  if ping -c 1 -t 3 -q 1.1.1.1 >/dev/null 2>&1; then
    ok "this Mac has upstream internet to share"
  else
    block "this Mac cannot reach the internet — the phone cannot either, so"
    echo "           'Trust this developer' will fail and so will app launch" >&2
  fi
fi

# THE mDNS TRAP. flutter finds the VM Service on an attached iPhone over mDNS.
# Personal Hotspot and the "Disable unless needed" checkbox on the iPhone USB
# interface both break it, and the failure surfaces twelve minutes into a
# shaped run as a generic FAIL. Neither is readable from the Mac directly, so
# this reports what CAN be seen and names the two settings.
IPHONE_USB=$(networksetup -listallnetworkservices 2>/dev/null | grep -i 'iPhone USB' || true)
if [ -n "$IPHONE_USB" ]; then
  ok "iPhone USB network service exists"
  if networksetup -getinfo "iPhone USB" 2>/dev/null | grep -q 'IP address: (null)\|^IP address: $'; then
    warn "iPhone USB has no IP — 'Disable unless needed' may be checked"
  fi
else
  warn "no 'iPhone USB' network service (fine if the phone shares no network)"
fi
echo "           reminder: Personal Hotspot OFF, and System Settings > Network >"
echo "           iPhone USB > Details > 'Disable unless needed' UNCHECKED"

# --- 4. the shaped path ----------------------------------------------------
section "4. the shaped path"

if ifconfig bridge100 >/dev/null 2>&1; then
  BRIDGE_IP=$(ifconfig bridge100 | awk '/inet /{print $2}')
  ok "bridge100 up at ${BRIDGE_IP:-?} (Internet Sharing is on)"

  # The peer must be REACHABLE, or the run records INVALID/UNROUTED after
  # having already spent the shaped minutes.
  PEER=$(arp -an 2>/dev/null | grep -i 'on bridge100' \
         | grep -v 'incomplete' | head -1 \
         | sed 's/.*(\([0-9.]*\)).*/\1/')
  if [ -z "$PEER" ]; then
    block "no peer on bridge100 — connect the phone to this Mac's hotspot"
  else
    ok "peer discovered at $PEER"
    RTT=$(ping -c 3 -i 0.2 -q "$PEER" 2>/dev/null | awk -F'/' '/round-trip|avg/{print $5}' | head -1)
    if [ -z "${RTT:-}" ]; then
      block "peer $PEER does not answer ping — the shaped path is not live"
    else
      ok "peer answers in ${RTT} ms"
      # A baseline that is ALREADY slow means a previous run left the shaper
      # up — an interrupted run is the usual way. Measuring impairment on top
      # of leftover impairment is meaningless, and it has a second cost that is
      # easy to miss: iOS validates a developer certificate ONLINE, so a phone
      # whose only link is this shaped bridge will fail "Trust this developer"
      # and refuse to launch the app, with an error that names neither.
      if [ "$(python3 -c "print(1 if $RTT > 50 else 0)" 2>/dev/null)" = "1" ]; then
        block "baseline rtt ${RTT} ms — the link is STILL SHAPED from an earlier run"
        # TEARDOWN, NOT RESTORE. This line used to recommend `restore`, which
        # reloads /etc/pf.conf and therefore deletes Internet Sharing's dynamic
        # NAT — taking the phone's internet away completely. Recommending it to
        # someone whose symptom is "the phone cannot reach Apple" makes the
        # problem worse while looking like a fix. `teardown` is anchor-scoped
        # and cannot touch NAT.
        echo "           sudo $HERE/net_shape.sh teardown     # anchor-only, keeps NAT" >&2
        echo "           if that is not enough:" >&2
        echo "           sudo $HERE/net_shape.sh restore      # heavy: DROPS Internet" >&2
        echo "             Sharing's NAT, so toggle Internet Sharing off/on after it" >&2
      fi
    fi
  fi
else
  block "bridge100 absent — turn on Internet Sharing and join the phone to it"
fi

# pf anchors: installing them reloads pf, and a reload WIPES Internet Sharing's
# dynamic NAT. So the anchors must already be present; this only verifies.
if [ -r /etc/pf.conf ]; then
  if grep -q 'dummynet-anchor "t2harness"' /etc/pf.conf && grep -q 'anchor "t2harness"' /etc/pf.conf; then
    ok "pf anchors installed in /etc/pf.conf"
  else
    block "pf anchors missing — run ONCE: sudo $HERE/net_shape.sh setup"
  fi
else
  unknown "cannot read /etc/pf.conf (run under sudo to check anchors)"
fi

if [ "$(id -u)" -eq 0 ]; then
  if pfctl -s info >/dev/null 2>&1; then
    pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' \
      && ok "pf is enabled" || warn "pf is disabled — net_shape.sh enables it"
  fi
  LEFTOVER=$(dnctl list 2>/dev/null | grep -c '^[0-9]* ' || true)
  [ "${LEFTOVER:-0}" -eq 0 ] && ok "no leftover dummynet pipes" \
    || block "${LEFTOVER} dummynet pipe(s) still configured — sudo $HERE/net_shape.sh restore"
else
  unknown "pf/dnctl state not checked (re-run under sudo for these two)"
fi

# --- 5. disk and time ------------------------------------------------------
section "5. disk and time"

FREE_MB=$(df -m "$REPO" | awk 'NR==2{print $4}')
if [ "${FREE_MB:-0}" -lt 4096 ]; then
  warn "only ${FREE_MB} MB free — an iOS build plus pcaps wants a few GB"
else
  ok "${FREE_MB} MB free on the repo volume"
fi

if pmset -g batt 2>/dev/null | grep -q "'Battery Power'"; then
  warn "on battery — an hour-long matrix should be on mains"
else
  ok "on mains power"
fi

# --- verdict ---------------------------------------------------------------
echo
echo "=============================================================="
if [ "$BLOCKERS" -gt 0 ]; then
  printf ' \033[31m%d BLOCKER(S)\033[0m · %d warning(s) — do NOT start the matrix\n' \
    "$BLOCKERS" "$WARNINGS"
  echo "=============================================================="
  echo "Fix the blockers above first. Each one would otherwise appear as a"
  echo "FAIL row in h2_results.tsv describing the rig rather than the app."
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  printf ' \033[33mno blockers · %d warning(s)\033[0m — the matrix can run\n' "$WARNINGS"
else
  printf ' \033[32mall green\033[0m — the matrix can run\n'
fi
echo "=============================================================="
echo
echo "Next, in order:"
echo "  sudo $HERE/t2_selftest.sh          # proves the shaper actually bites"
echo "  sudo $HERE/h2_run.sh clean integration_test/sla_thresholds_test.dart"
echo "  sudo $HERE/h2_matrix.sh            # the full hour"
[ "$WARNINGS" -gt 0 ] && exit 2
exit 0
