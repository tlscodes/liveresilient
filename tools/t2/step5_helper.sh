#!/bin/bash
# Starts the pinned backend's own command-line server locally, configured so the
# publicly visible name differs from the real destination name, and records the
# configuration it was actually started with.
#
# WHY THE BACKEND'S OWN TOOL
# Standing up a server for this is configuration, not code: the pinned clone
# already ships a server that speaks the extension under test, so using it keeps
# the measurement about the extension rather than about something written here
# tonight. Nothing in this script needs privilege.
#
# WHAT IT WRITES
#   docs/evidence/step5_helper_config.txt   the configuration, as served
#   tools/t2/step5_work/                    key, config list, log (ignored)
#
# The two names are the whole point. Step 7 checks a capture for both: the real
# name must not appear in the clear, and the public one must — a capture of
# nothing would otherwise pass a one-sided check.
#
#   exit 0  running, configuration recorded
#   exit 2  bad arguments
#   exit 3  the backend tool is missing — build it first
#   exit 4  the server did not come up

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${BORINGSSL_SRC:-$HOME/.cache/tlsapi/boringssl}"
BSSL="$SRC/build-host/bssl"
WORK="$REPO/tools/t2/step5_work"
EVIDENCE="$REPO/docs/evidence/step5_helper_config.txt"

PORT=4433
PUBLIC_NAME="public-front-a7f3.example"
REAL_NAME="hidden-destination-a7f3.example"
CONFIG_ID=7
ACTION="start"

while [ $# -gt 0 ]; do
  case "$1" in
    --port)        PORT="${2:-}"; shift 2 ;;
    --public-name) PUBLIC_NAME="${2:-}"; shift 2 ;;
    --real-name)   REAL_NAME="${2:-}"; shift 2 ;;
    --stop)        ACTION="stop"; shift ;;
    --status)      ACTION="status"; shift ;;
    -h|--help)
      echo "usage: step5_helper.sh [--port N] [--public-name X] [--real-name Y] [--stop|--status]" >&2
      exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK" "$(dirname "$EVIDENCE")"
PIDFILE="$WORK/server.pid"

stop_server() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "stopped pid $pid"
    fi
    rm -f "$PIDFILE"
  else
    echo "no recorded pid"
  fi
}

case "$ACTION" in
  stop)   stop_server; exit 0 ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "running, pid $(cat "$PIDFILE")"; exit 0
    fi
    echo "not running"; exit 1 ;;
esac

[ -x "$BSSL" ] || { echo "missing $BSSL — build the host targets first" >&2; exit 3; }

stop_server >/dev/null 2>&1

# A fresh configuration each start: the config list is what a client must be
# handed out of band, so it is regenerated rather than cached, and the evidence
# records the one that was actually served.
"$BSSL" generate-ech \
  -out-ech-config-list "$WORK/ech_config_list.bin" \
  -out-ech-config "$WORK/ech_config.bin" \
  -out-private-key "$WORK/ech_key.bin" \
  -public-name "$PUBLIC_NAME" \
  -config-id "$CONFIG_ID" \
  -max-name-length 0 || { echo "could not generate the configuration" >&2; exit 4; }

"$BSSL" server -accept "$PORT" -ech-key "$WORK/ech_key.bin" \
  -ech-config "$WORK/ech_config.bin" -loop -debug \
  > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PIDFILE"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "the server exited immediately; its log follows" >&2
    tail -10 "$WORK/server.log" >&2
    rm -f "$PIDFILE"
    exit 4
  fi
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 1
done

if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "nothing is listening on port $PORT" >&2
  stop_server
  exit 4
fi

# The address a phone on the same network would use, recorded because "reachable
# from the phone" is part of what this step claims.
# Asked of the routing table rather than assumed to be en0: on this machine the
# default route lives on en1, and a hardcoded interface recorded "unknown" for
# an address that existed.
DEFAULT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
LAN_IP="$(ipconfig getifaddr "${DEFAULT_IF:-en0}" 2>/dev/null || true)"
LAN_IP="${LAN_IP:-unknown}"

{
  echo "artifact: the pinned backend's own server, running locally"
  echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "tool: $BSSL server"
  echo "pin: $(git -C "$SRC" rev-parse HEAD)"
  echo "public_name: $PUBLIC_NAME"
  echo "real_name: $REAL_NAME"
  echo "config_id: $CONFIG_ID"
  echo "port: $PORT"
  echo "listen: 0.0.0.0:$PORT"
  echo "lan_address: $LAN_IP:$PORT"
  echo "pid: $SERVER_PID"
  echo "ech_config_list_bytes: $(wc -c < "$WORK/ech_config_list.bin" | tr -d ' ')"
  echo "ech_config_list_hex: $(xxd -p "$WORK/ech_config_list.bin" | tr -d '\n')"
  echo "certificate: generated at run time by the tool (no key was supplied)"
} > "$EVIDENCE"

echo "listening on 0.0.0.0:$PORT (pid $SERVER_PID)"
echo "wrote ${EVIDENCE#"$REPO"/}"
grep -v ech_config_list_hex "$EVIDENCE"
