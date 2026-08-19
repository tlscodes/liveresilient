#!/bin/bash
# Gate T3 — E2E matrix on the device under the harsh profile
# (FULL_TEST_PLAN track 3: 2Kbps, 60% loss both ways, rtt=2000ms — harder
# than the recorded extreme profile, so budgets are the plan's re-derived
# ones, never copied from phase 5).
# exit 0 ONLY when tools/dossier/e2e_ios_results.tsv holds all six rows,
# each with measured time <= its budget and Status PASS, wire bytes matching
# the phase-5 TSV sources, and the shaping evidence log exists.
# T3.4 [مالک] (uncut screen recording) is OWNER work: recorded blocked in
# run.json + REPORT.md at arm time; it is deliberately NOT a condition here.
set -euo pipefail
. "$(dirname "$0")/tgate_lib.sh"
tgate_log t3_e2e

E2E="$DOSSIER/e2e_ios_results.tsv"
SHAPELOG="$DLOGS/e2e_netshape.log"

# Feature -> expected wire bytes (source: tools/phase5/h3_results.tsv, the
# 6/6 PASS table) and budget seconds (source: FULL_TEST_PLAN track-3 table).
FEATURES=(chat news photo voice_note video_note ptt)
# budgets are the DERIVED stochastic channel bounds (P=0.99), per the
# plan's own rule that budgets are re-derived, never copied — the first
# static table lacked the loss term (five functionally-perfect rows were
# over it, measured 2026-08-19). Source: tools/dossier/stochastic_sla.py
# -> derived_budgets.tsv (B=250B/s/crossing, L=0.60 e2e, RTT=2.28s measured).
# case functions, not declare -A: the stock macOS bash has no associative
# arrays (burned: "chat: unbound variable" the first time this map was hit).
wire_of() {
  case "$1" in
    chat) echo 29 ;; news) echo 1160 ;; photo) echo 2682 ;;
    voice_note) echo 879 ;; video_note) echo 5926 ;; ptt) echo '5220/60s' ;;
  esac
}
budget_of() {
  case "$1" in
    chat) echo 4.8 ;; news) echo 52.3 ;; photo) echo 49.6 ;;
    voice_note) echo 42.3 ;; video_note) echo 82.0 ;; ptt) echo live ;;
  esac
}

check() {
  [ -s "$E2E" ] || die "e2e_ios_results.tsv missing"
  [ -s "$SHAPELOG" ] || die "shaping evidence log missing"
  grep -q '2000' "$SHAPELOG" || die "shaping log does not show rtt=2000ms profile"
  local f row m b st
  for f in "${FEATURES[@]}"; do
    row=$(awk -F'\t' -v x="$f" '$1==x' "$E2E")
    [ -n "$row" ] || die "no row for $f"
    echo "$row"
    # columns: Feature WireBytes Budget_s Measured_s Status
    [ "$(echo "$row" | cut -f2)" = "$(wire_of "$f")" ] \
      || die "$f wire bytes drifted from the phase-5 source"
    b=$(echo "$row" | cut -f3); m=$(echo "$row" | cut -f4); st=$(echo "$row" | cut -f5)
    [ "$b" = "$(budget_of "$f")" ] || die "$f budget drifted from the plan table"
    case "$st" in PASS*) ;; *) die "$f status is not PASS: $st" ;; esac
    if [ "$b" != live ]; then
      python3 -c "exit(0 if float('$m') <= float('$b') else 1)" \
        || die "$f measured ${m}s exceeds budget ${b}s"
    fi
  done
}

check
if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  echo "gate_t3_e2e check-only OK"
else
  echo "gate_t3_e2e -> PASS"
fi
