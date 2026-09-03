#!/usr/bin/env bash
# relay_restart.sh — (re)start the dev signaling relay on the journey port from
# the CURRENT source, detached from the caller's shell. A relay left running
# from before a relay code change serves the old code silently; the journey
# rig therefore restarts it here before a matrix.
#
# USAGE  tools/t2/relay_restart.sh [port]      (default 4443; log in $TMPDIR)
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${1:-4443}
LOG=${RELAY_LOG:-${TMPDIR:-/tmp}/signaling_relay_$PORT.log}
pkill -f "signaling_server.dart --port $PORT" 2>/dev/null && sleep 1
cd "$REPO/server/signaling_server" || exit 1
nohup dart run bin/signaling_server.dart --port "$PORT" --address any >"$LOG" 2>&1 &
for _ in $(seq 1 40); do
  pgrep -f "signaling_server.dart --port $PORT" >/dev/null && curl -sk --max-time 2 "https://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 1
done
pgrep -fl "signaling_server.dart --port $PORT" | head -1 | cut -c1-90 || { echo "relay did not start; see $LOG" >&2; exit 1; }
echo "relay on $PORT, log $LOG"
