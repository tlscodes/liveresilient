#!/usr/bin/env bash
# gate_t0_device — PREFLIGHT: prove the phone is usable BEFORE any build.
#
# WHY THIS RUNS FIRST. Tracks 2 and 3 of FULL_TEST_PLAN.md cost long native
# builds and a shaped-network matrix; discovering a locked phone, an expired
# signing identity or a dead cable AFTER those builds wastes the night. Every
# check here is READ-ONLY and finishes in seconds.
#
# Exit 0 = the device path is ready. Exit 1 = a named blocker, printed with the
# exact remedy. Nothing here modifies the machine, so it is safe to re-run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOG_DIR="$REPO/tools/dossier/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/device_preflight.log"
fail=0
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
bad() { say "BLOCKER: $*"; fail=1; }

: > "$LOG"
say "=== device preflight $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# 1. Xcode toolchain actually selected (a wrong xcode-select breaks every
#    later step with a misleading error).
DEV_DIR="$(xcode-select -p 2>/dev/null)"
if [ -z "$DEV_DIR" ] || [ ! -d "$DEV_DIR" ]; then
  bad "xcode-select points nowhere. Fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
  say "xcode-select   $DEV_DIR"
fi

# 2. A physical iOS device visible to Flutter. The UDID is captured here and
#    reused by every later track, so no step ever hardcodes a device again
#    (the two-iPhone lesson: a hardcoded UDID aims the whole night at an
#    absent phone).
DEVICES="$(flutter devices --machine 2>/dev/null)"
UDID="$(printf '%s' "$DEVICES" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
ios=[x for x in d if x.get('targetPlatform','').startswith('ios') and not x.get('emulator',True)]
print(ios[0]['id'] if ios else '')
" 2>/dev/null)"
NAME="$(printf '%s' "$DEVICES" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
ios=[x for x in d if x.get('targetPlatform','').startswith('ios') and not x.get('emulator',True)]
print(ios[0].get('name','') if ios else '')
" 2>/dev/null)"
if [ -z "$UDID" ]; then
  bad "no physical iOS device visible to flutter. Fix: cable in, unlock the phone, answer Trust This Computer."
else
  say "device         $NAME  $UDID"
  printf '%s\n' "$UDID" > "$LOG_DIR/device_udid.txt"
fi

# 3. CoreDevice agrees the phone is connected (flutter can lag behind a
#    just-unplugged cable).
if command -v xcrun >/dev/null; then
  if xcrun devicectl list devices 2>/dev/null | grep -q "connected"; then
    say "coredevice     connected"
  else
    bad "devicectl reports no connected device. Fix: replug the cable, unlock, retry."
  fi
fi

# 4. A valid code-signing identity. With a paid account this is a year-long
#    certificate, so a failure here means the keychain, not the calendar.
IDS="$(security find-identity -v -p codesigning 2>/dev/null)"
COUNT="$(printf '%s' "$IDS" | grep -cE '^[[:space:]]+[0-9]+\)')"
if [ "${COUNT:-0}" -lt 1 ]; then
  bad "no valid codesigning identity in the keychain. Fix: Xcode > Settings > Accounts > Manage Certificates."
else
  say "identity       $(printf '%s' "$IDS" | grep -E '^[[:space:]]+1\)' | sed 's/^ *//')"
fi

# 5. A provisioning profile that is still in date. Xcode 16 moved this
#    directory; both locations are checked and the expiry is READ from the
#    profile itself rather than assumed.
PROF_NEW="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROF_OLD="$HOME/Library/MobileDevice/Provisioning Profiles"
NEWEST=""
for d in "$PROF_NEW" "$PROF_OLD"; do
  [ -d "$d" ] || continue
  cand="$(ls -t "$d"/*.mobileprovision 2>/dev/null | head -1)"
  [ -n "$cand" ] && { NEWEST="$cand"; break; }
done
if [ -z "$NEWEST" ]; then
  say "profile        none on disk — automatic signing will fetch one at first build (not a blocker)"
else
  EXP="$(security cms -D -i "$NEWEST" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)"
  say "profile        $(basename "$NEWEST")  expires $EXP"
  if [ -n "$EXP" ]; then
    python3 - "$EXP" <<'PY' || bad "the newest provisioning profile is expired. Fix: open the project in Xcode once to refresh it."
import sys, datetime
raw = sys.argv[1].strip().replace('Z', '+00:00')
try:
    exp = datetime.datetime.fromisoformat(raw)
except ValueError:
    sys.exit(0)  # unparseable date is not evidence of expiry
now = datetime.datetime.now(datetime.timezone.utc)
sys.exit(1 if exp <= now else 0)
PY
  fi
fi

# 6. The test link itself: the rig's own discovery, then a health ping. A
#    cable that enumerates but carries no IPv4 is the failure that has cost
#    this project the most hours.
if [ -x "$REPO/tools/t2/usb_peer.sh" ]; then
  eval "$("$REPO/tools/t2/usb_peer.sh" 2>/dev/null)" || true
  if [ -n "${T2_PEER:-}" ]; then
    RTT="$(ping -c 3 -q "$T2_PEER" 2>/dev/null | awk -F'/' '/round-trip|avg/ {print $5}')"
    LOSS="$(ping -c 3 -q "$T2_PEER" 2>/dev/null | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')"
    say "link           iface=${T2_IFACE:-?} peer=$T2_PEER rtt=${RTT:-?}ms loss=${LOSS:-?}%"
    [ "${LOSS:-100}" = "0.0" ] || say "NOTE: baseline loss is not 0% — the shaped matrix would measure the cable, not the design."
  else
    bad "usb_peer.sh found no IPv4 peer on the cable. Fix: see RIG_GUIDE §0.5 step 3."
  fi
fi

# 7. Passwordless rules for the shaping scripts, so track 3 never stalls on a
#    password prompt in the middle of the night.
for s in tools/t2/net_shape.sh tools/t2/h2_run.sh; do
  if sudo -n -l "$REPO/$s" >/dev/null 2>&1; then
    say "sudo rule      ok  $s"
  else
    say "NOTE: no NOPASSWD rule for $s — track 3 would stop at a prompt."
  fi
done

say "=== result: $([ $fail -eq 0 ] && echo READY || echo BLOCKED) ==="
exit $fail
