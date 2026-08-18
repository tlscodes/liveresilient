#!/bin/bash
# Runs the on-device probe against the locally-running helper and records what
# the peer did with the configuration the phone offered it.
#
# Everything the test needs comes from docs/evidence/step5_helper_config.txt —
# the address, the port, the configuration list and the real name — so a passing
# probe cannot be passing against a peer nobody started. If that file is missing
# or the helper is not listening, this stops before touching the device.
#
#   exit 0  the peer applied the configuration; evidence written
#   exit 2  the helper's recorded configuration is missing or incomplete
#   exit 3  no phone attached
#   exit 4  the device refused to run it — the log says why
#   exit 5  it ran and the probe did not answer `applied`

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/apps/reference_app"
HELPER="$REPO/docs/evidence/step5_helper_config.txt"
OUT="$REPO/docs/evidence/step6_probe_answer.txt"
LOG_DIR="$REPO/tools/suite-logs"
LOG="$LOG_DIR/device_ech_probe_$(date -u '+%Y%m%dT%H%M%SZ').log"
DEVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --host)   FORCED_HOST="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR" "$(dirname "$OUT")"

[ -f "$HELPER" ] || { echo "no recorded helper configuration at $HELPER — start it first" >&2; exit 2; }

field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' "$HELPER"; }

PORT="$(field port)"
CONFIG_HEX="$(field ech_config_list_hex)"
INNER_NAME="$(field real_name)"
LAN="$(field lan_address)"
HOST="${FORCED_HOST:-${LAN%%:*}}"

if [ -z "$PORT" ] || [ -z "$CONFIG_HEX" ] || [ -z "$INNER_NAME" ] || [ -z "$HOST" ] || [ "$HOST" = "unknown" ]; then
  echo "the recorded configuration is incomplete: host=$HOST port=$PORT name=$INNER_NAME config=${#CONFIG_HEX} hex chars" >&2
  exit 2
fi

# The phone reaches the helper over the network, so a helper that is not
# listening HERE is a fault worth naming before a device build is spent on it.
if ! nc -z "$HOST" "$PORT" 2>/dev/null; then
  echo "nothing is listening on $HOST:$PORT — start tools/t2/step5_helper.sh" >&2
  exit 2
fi

if [ -z "$DEVICE" ]; then
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
[ -n "$DEVICE" ] || { echo "no phone attached" >&2; exit 3; }

echo "peer:   $HOST:$PORT  inner name $INNER_NAME"
echo "device: $DEVICE"
echo "log:    ${LOG#"$REPO"/}"

cd "$APP" || exit 4
flutter test integration_test/ech_probe_on_device_test.dart \
  -d "$DEVICE" --no-pub \
  --dart-define=PROBE_HOST="$HOST" \
  --dart-define=PROBE_PORT="$PORT" \
  --dart-define=PROBE_CONFIG_HEX="$CONFIG_HEX" \
  --dart-define=PROBE_INNER_NAME="$INNER_NAME" > "$LOG" 2>&1
STATUS=$?

if grep -qiE 'no devices found|Unable to (install|launch)|Device is locked|passcode|Trust this computer' "$LOG"; then
  echo "the device did not take the app — not a result about the capability" >&2
  grep -iE 'Unable to (install|launch)|locked|passcode|Trust this computer' "$LOG" | head -3 >&2
  exit 4
fi

if ! grep -q '^PROBE|' "$LOG"; then
  echo "the probe printed no answer; the last lines follow" >&2
  tail -20 "$LOG" >&2
  exit 5
fi

{
  echo "artifact: what the peer did with the configuration this build offered"
  echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "device: $DEVICE"
  echo "source: integration_test/ech_probe_on_device_test.dart via pt_shim_ech_probe"
  grep '^PROBE|' "$LOG" | sed 's/^PROBE|//'
  echo "helper_public_name: $(field public_name)"
  echo "test_exit: $STATUS"
} > "$OUT"

cat "$OUT"
if [ $STATUS -ne 0 ]; then
  echo "the probe ran and did not answer applied" >&2
  exit 5
fi
echo "wrote ${OUT#"$REPO"/}"
