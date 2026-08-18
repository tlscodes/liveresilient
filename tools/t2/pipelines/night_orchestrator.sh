#!/bin/bash
# NIGHT ORCHESTRATOR: serialize everything — wait for the rig to be truly
# free, then the video sniper pipeline, then the overnight voice+messaging
# mission (it waits for the sniper's DONE marker in the fresh out file).
S=$(cd "$(dirname "$0")" && pwd)/logs
mkdir -p "$S"
while pgrep -f "h2_run.sh" >/dev/null 2>&1; do
  sleep 30
done
sleep 15
echo "ORCH rig free — firing video sniper pipeline"
bash "$(dirname "$0")/sniper.sh" > "$S/sniper_run.out" 2>&1
echo "ORCH sniper done — firing overnight mission"
bash "$(dirname "$0")/overnight.sh" > "$S/overnight_run.out" 2>&1
echo "ORCH_ALL_DONE"
