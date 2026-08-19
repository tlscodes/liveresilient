#!/bin/bash
# Phase 5 run-level goal verifier — a PURE READER (design consult 2026-08-19):
# green only when h3_results.tsv holds the header plus EXACTLY the six
# contracted rows (Text NewsPage Photo VoiceNote PTT VideoNote), every Status
# is PASS or PASS(fallback:<name>), and every gate re-exits 0 in
# GATE_CHECK_ONLY=1 mode (verification never mutates evidence).
set -euo pipefail
cd "$(dirname "$0")"
TSV=h3_results.tsv

[ -f "$TSV" ] || { echo "goal_verify: $TSV missing"; exit 1; }

LINES=$(wc -l < "$TSV" | tr -d ' ')
[ "$LINES" -eq 7 ] || { echo "goal_verify: expected header+6 rows, got $LINES lines"; exit 1; }

head -1 "$TSV" | grep -q $'^Feature\tStandard_Size\tCompressed_Size\tWire_Time_At_2Kbps\tLoss_Survival\tStatus$' \
  || { echo "goal_verify: bad header"; exit 1; }

for F in Text NewsPage Photo VoiceNote PTT VideoNote; do
  N=$(awk -F'\t' -v f="$F" '$1==f' "$TSV" | wc -l | tr -d ' ')
  [ "$N" -eq 1 ] || { echo "goal_verify: feature $F has $N rows (want 1)"; exit 1; }
  awk -F'\t' -v f="$F" '$1==f' "$TSV" \
    | grep -Eq $'\t(PASS|PASS\\(fallback:[^)]+\\))$' \
    || { echo "goal_verify: $F row not PASS: $(awk -F'\t' -v f="$F" '$1==f' "$TSV")"; exit 1; }
done

for N in 1 6 2 3 5 4; do
  GATE_CHECK_ONLY=1 bash "gate_$N.sh" >/dev/null 2>&1 \
    || { echo "goal_verify: gate_$N check-only failed"; exit 1; }
done

echo "GOAL VERIFY GREEN: 6/6 rows PASS and all gates re-verify"
