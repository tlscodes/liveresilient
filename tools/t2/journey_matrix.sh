#!/usr/bin/env bash
# journey_matrix.sh — every impairment profile of the app journey, in sequence,
# on the real rig (Mac app + persistent phone peer over bridge100), then the
# report. One profile at a time: the shaper, the recorder and the phone are
# each a single shared resource.
#
# Prerequisites (checked, not assumed): the relay on the journey port, the
# phone peer installed (tools/t2/journey_peer_install.sh, its microphone prompt
# answered once), Internet Sharing with the phone on bridge100, and enough disk
# for the recordings (each 0.1-1.2 GB; the flutter_build cache grew to 22 GB
# in one day of runs, 2026-09-03).
#
# USAGE  tools/t2/journey_matrix.sh [profile ...]   (default: all seven)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PROFILES=("$@")
[ ${#PROFILES[@]} -gt 0 ] || PROFILES=(normal latency loss10 bandwidth narrow loss60 extreme)
PORT=${JOURNEY_RELAY_PORT:-4443}
LOG="$REPO/tools/dossier/logs/journey/matrix.log"
mkdir -p "$(dirname "$LOG")"

pgrep -f "signaling_server.dart --port $PORT" >/dev/null || { echo "ERROR: no relay on $PORT (tools/t2/relay_restart.sh $PORT)" >&2; exit 1; }
free_gb=$(df -g / | awk 'NR==2{print $4}')
MIN_FREE_GB=${JOURNEY_MIN_FREE_GB:-12}
[ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || { echo "ERROR: only ${free_gb} GB free (need $MIN_FREE_GB; JOURNEY_MIN_FREE_GB overrides); recordings are ~0.3-1.7 GB per profile" >&2; exit 1; }

echo "matrix    ${PROFILES[*]}   (relay $PORT, ${free_gb} GB free)" | tee -a "$LOG"
for p in "${PROFILES[@]}"; do
  echo "=== $p  $(date -u +%H:%M:%SZ) ===" | tee -a "$LOG"
  "$REPO/tools/t2/journey_run.sh" "$p" 2>&1 | tee -a "$LOG" | grep -E "^(profile|verified|phone|app|go|runs|rows|ERROR|note)" || true
  echo "=== $p done $(date -u +%H:%M:%SZ) ===" | tee -a "$LOG"
  sleep 5
done
echo
python3 "$REPO/tools/dossier/journey_report.py" | tee -a "$LOG"
