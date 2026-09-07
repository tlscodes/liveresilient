#!/usr/bin/env bash
# journey_kill.sh — stop every process an app-journey run leaves behind and
# restore the link. Kept in a file on purpose: `pkill -f <pattern>` typed into
# an interactive shell matches that shell's own command line and kills the
# caller instead of the runner (measured 2026-09-04: the runner lived on, the
# next run started a second one, and two macOS builds fought one lock).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
for pat in "tools/t2/journey_matrix.sh" "tools/t2/journey_run.sh" "journey_hub.py" \
           "integration_test/journey_driver" "xcodebuild.*reference_app" "macos_assemble.sh" \
           "screencapture -v"; do
  pkill -f "$pat" 2>/dev/null && echo "stopped: $pat"
done
sleep 1
sudo -n "$REPO/tools/t2/net_shape.sh" teardown >/dev/null 2>&1 && echo "shaping torn down"
left=$(pgrep -fl "journey_matrix|journey_run|journey_hub|journey_driver|xcodebuild.*reference_app" | wc -l | tr -d ' ')
echo "journey processes left: $left"
