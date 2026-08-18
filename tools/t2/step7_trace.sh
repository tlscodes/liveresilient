#!/bin/bash
# Records a trace of the attached phone's traffic, and records how it was
# recorded. It runs as root because attaching a trace interface to a device
# requires it; nothing else here needs privilege, which is why the script is
# kept small enough to read in full before granting it a rule.
#
# It writes exactly two files and touches nothing else:
#   <out>.pcap                 the capture
#   <out>_provenance.txt       tool, absolute dates, host, device, interface,
#                              the command line, and the capture tool's version
#
# The provenance file exists because the absence of a string in a capture is a
# much weaker claim than it looks: a name can be missing because it was
# protected, or because the connection never happened, or because the capture
# watched the wrong interface. Step 7 of docs/PLAN_REMAINING.md therefore checks
# both directions — the name that must not appear, and the name that must.
#
# Grant it with the exact absolute path, never ALL:
#   sudo visudo -f /etc/sudoers.d/t2rig-extra
#   behnam ALL=(root) NOPASSWD: /Users/behnam/Downloads/voice_call_kit_v3/tools/t2/step7_trace.sh
#
# Then always call it as `sudo -n`, so a missing rule fails loudly and at once
# instead of hanging an unattended run behind a password prompt nobody is awake
# to answer. Note what the grant means: this file is writable by the ordinary
# user, so anything running as that user can obtain root through it. On a
# single-user development machine that is a deliberate trade; the stricter form
# is a root-owned copy with the rule pointing at the copy.

set -euo pipefail

UDID=""
OUT=""
DURATION=45
IFACE="rvi0"

usage() {
  echo "usage: step7_trace.sh --udid <device-udid> --out <path-prefix> [--seconds N]" >&2
  echo "  writes <prefix>.pcap and <prefix>_provenance.txt" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --udid)    UDID="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --seconds) DURATION="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$UDID" ] || usage
[ -n "$OUT" ] || usage
case "$DURATION" in ''|*[!0-9]*) echo "--seconds must be a number" >&2; exit 2 ;; esac

RVICTL=/Library/Apple/usr/bin/rvictl
TCPDUMP=/usr/sbin/tcpdump
[ -x "$RVICTL" ]  || { echo "missing $RVICTL" >&2; exit 3; }
[ -x "$TCPDUMP" ] || { echo "missing $TCPDUMP" >&2; exit 3; }

PCAP="${OUT}.pcap"
PROV="${OUT}_provenance.txt"
mkdir -p "$(dirname "$PCAP")"

cleanup() { "$RVICTL" -x "$UDID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A stale interface left by an interrupted run would make the attach fail.
"$RVICTL" -x "$UDID" >/dev/null 2>&1 || true
"$RVICTL" -s "$UDID" >/dev/null || { echo "could not attach a trace interface to $UDID" >&2; exit 4; }

for _ in 1 2 3 4 5; do
  ifconfig "$IFACE" >/dev/null 2>&1 && break
  sleep 1
done
ifconfig "$IFACE" >/dev/null 2>&1 || { echo "$IFACE never appeared" >&2; exit 5; }

START_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
"$TCPDUMP" -i "$IFACE" -s 0 -w "$PCAP" -G "$DURATION" -W 1 >/dev/null 2>&1 || true
END_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

[ -s "$PCAP" ] || { echo "the capture produced an empty file" >&2; exit 6; }

# Ownership follows the invoking user so that reading the result afterwards
# does not need privilege a second time.
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
  chown "$SUDO_UID:$SUDO_GID" "$PCAP"
fi

{
  echo "tool: tcpdump over rvictl"
  echo "date: ${START_UTC}"
  echo "date_end: ${END_UTC}"
  echo "host: $(hostname)"
  echo "device_udid: ${UDID}"
  echo "interface: ${IFACE}"
  echo "duration_seconds: ${DURATION}"
  echo "invoked_by_uid: ${SUDO_UID:-0}"
  echo "command: $0 --udid ${UDID} --out ${OUT} --seconds ${DURATION}"
  echo "tcpdump_version: $($TCPDUMP --version 2>&1 | head -1)"
  echo "pcap_bytes: $(wc -c < "$PCAP" | tr -d ' ')"
} > "$PROV"

if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
  chown "$SUDO_UID:$SUDO_GID" "$PROV"
fi

echo "wrote $PCAP"
echo "wrote $PROV"
