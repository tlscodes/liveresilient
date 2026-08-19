#!/bin/bash
# T3.4 [مالک] — Mac-side rig for the uncut demo screencast. The recording
# itself needs the owner present (device screen mirror + system permission),
# so the run only PREPARES this side and records the task blocked. What this
# script does when the owner sits down:
#   start  : applies the t3x profile marker line, starts a live monitor pane
#            (relay + shaper state, 1 Hz) and stamps the slate file — the
#            uncut video shows this terminal beside the mirrored device.
#   stop   : stamps the slate end line and stops the monitor.
# Slate: tools/dossier/logs/owner_video_slate.txt (start/stop timestamps the
# video's timeline is checked against).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SLATE="$REPO/tools/dossier/logs/owner_video_slate.txt"
MONPID="$REPO/tools/dossier/logs/.owner_video_mon.pid"

case "${1:-}" in
  start)
    echo "slate start $(date -u +%Y-%m-%dT%H:%M:%SZ) profile=t3x" | tee -a "$SLATE"
    (
      while :; do
        printf '%s relay=%s shaper=%s\n' \
          "$(date -u +%H:%M:%SZ)" \
          "$(pgrep -f 'datagram_relay' >/dev/null && echo up || echo down)" \
          "$(sudo -n dnctl list 2>/dev/null | head -1 || echo unknown)"
        sleep 1
      done
    ) &
    echo $! > "$MONPID"
    echo "monitor pid $(cat "$MONPID") — keep this terminal in frame"
    ;;
  stop)
    echo "slate stop  $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$SLATE"
    [ -f "$MONPID" ] && kill "$(cat "$MONPID")" 2>/dev/null || true
    rm -f "$MONPID"
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 2
    ;;
esac
