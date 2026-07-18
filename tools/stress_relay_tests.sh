#!/usr/bin/env bash
# Flake reproducer/verifier for server/signaling_server tests: runs the suite
# N times with M concurrent copies to recreate the heavy-parallel-load
# condition under which relay_server_test once failed (2026-07-18). All runs
# must pass for the hardening to count as verified under load.
set -e
cd "$(dirname "$0")/../server/signaling_server"
ROUNDS="${1:-3}"
WIDTH="${2:-4}"
for round in $(seq 1 "$ROUNDS"); do
  echo "== round $round/$ROUNDS: $WIDTH concurrent suite runs"
  pids=()
  for i in $(seq 1 "$WIDTH"); do
    dart test >"/tmp/relay_stress_${round}_${i}.log" 2>&1 &
    pids+=($!)
  done
  fail=0
  for pid in "${pids[@]}"; do
    wait "$pid" || fail=1
  done
  if [ "$fail" = "1" ]; then
    echo "ROUND $round FAILED — logs in /tmp/relay_stress_${round}_*.log"
    grep -l "Some tests failed" /tmp/relay_stress_${round}_*.log || true
    exit 1
  fi
  echo "   round $round: all $WIDTH concurrent runs green"
done
echo "STRESS OK: $((ROUNDS * WIDTH)) suite runs, zero failures"
