#!/bin/bash
# Runs the on-device measurement and turns its output into an evidence file.
#
# The measurement itself is an integration test, because the thing being
# measured is what the APP's process composes on the phone's architecture — see
# apps/reference_app/integration_test/first_record_on_device_test.dart. This
# script only drives it and extracts the marker-prefixed lines, so nothing has
# to be pulled off the device.
#
# WHY THE FAILURE MESSAGES ARE SEPARATED
# An unattended run needs to tell three different stories apart: no phone was
# attached, a phone was attached but would not take the app (locked, untrusted,
# out of space), and the app ran and the measurement failed. Only the third is
# about this repository's code, and a log that blurs them wastes a morning.
#
#   exit 0  evidence written
#   exit 3  no device attached
#   exit 4  the device refused to run it — the full log says why
#   exit 5  it ran and the measurement failed
#   exit 6  it ran, reported success, and printed no record lines

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/apps/reference_app"
OUT="$REPO/docs/evidence/first_record_arm64.txt"
LOG_DIR="$REPO/tools/suite-logs"
LOG="$LOG_DIR/device_record_$(date -u '+%Y%m%dT%H%M%SZ').log"
DEVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: capture_device_record.sh [--device <id>] [--out <file>]" >&2
      exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR" "$(dirname "$OUT")"

if [ -z "$DEVICE" ]; then
  # The first attached iOS device, by its identifier column.
  DEVICE="$(flutter devices --machine 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
try:
    devices = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in devices:
    if d.get("targetPlatform","").startswith("ios") and not d.get("emulator", False):
        print(d.get("id",""))
        break')"
fi

if [ -z "$DEVICE" ]; then
  echo "no phone attached — nothing to measure on a second architecture" >&2
  echo "attach the device by cable, unlock it, and trust this computer" >&2
  exit 3
fi

echo "device: $DEVICE"
echo "log:    ${LOG#"$REPO"/}"

cd "$APP" || exit 4
flutter test integration_test/first_record_on_device_test.dart \
  -d "$DEVICE" --no-pub > "$LOG" 2>&1
STATUS=$?

if grep -qiE 'no devices found|device .* not found|Could not find|is not connected|Unable to (install|launch)|Device is locked|passcode|Trust this computer|DeviceNotFoundException' "$LOG"; then
  echo "the device did not take the app — this is not a failure of the measurement" >&2
  grep -iE 'no devices found|Unable to (install|launch)|locked|passcode|Trust this computer' "$LOG" | head -3 >&2
  exit 4
fi

if [ $STATUS -ne 0 ]; then
  echo "the test ran and failed; the last lines follow" >&2
  tail -20 "$LOG" >&2
  exit 5
fi

if ! grep -q '^RECORD|' "$LOG"; then
  # A pass with no record lines means the test's own output never arrived —
  # treat it as a failed measurement rather than writing an empty evidence file
  # that would later read as a green step.
  echo "the test reported success but printed no record lines" >&2
  exit 6
fi

grep '^RECORD|' "$LOG" | sed 's/^RECORD|//' > "$OUT"
echo "wrote ${OUT#"$REPO"/}"
grep -v '^hex:' "$OUT"
