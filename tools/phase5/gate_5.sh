#!/bin/bash
# Gate 5 — PTT engine, two-level per plan appendix A:
#   HARD: total wire bytes (bit-packed Codec2 frames + 2B tag-v2 + computed
#         28B UDP/IPv4) over a 60s continuous-speech window <= 750 bps.
#         Bundling window 1-4s ONLY (duty-cycle games are rejected by design).
#   SURVIVAL (labeled simulation-on-host): 60s stream under seeded 60% random
#         datagram loss must not abort, decoded-frame ratio within ±5% of the
#         theoretical 40%, queue delay bounded.
#   REPORT: per-packet byte anatomy goes to the log; numbers only from
#         measure_ptt.py output.
# Prerequisites (peak 5 build step):
#   tag-v2 (2B) in the rig forwarder + its unit test in server/signaling_server
#   packages/adaptive_transport/lib/src/ptt_engine.dart
#   tools/phase5/measure_ptt.py
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 5

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$PHASE5_DIR/logs/ptt_result.txt" ] || die "no measurement evidence"
  require_row "PTT" '^PASS'
  echo "gate_5 check-only OK"
  exit 0
fi

verify_asset speech_ref_10s.wav
[ -f "$PHASE5_DIR/measure_ptt.py" ] || die "measure_ptt.py not built yet"
TAGTEST_MARKER="$PHASE5_DIR/.markers/tagv2_unit_test.done"
[ -f "$TAGTEST_MARKER" ] || die "tag-v2 unit test not green yet (marker missing)"

# Codec: 700C's wire floor measured 760bps > 750 at max bundling (header
# floor, see logs/ptt_anatomy.tsv of the 2026-08-19 night run) — the peak
# ships on the REAL codec2 450 mode (18 bits/40ms, built from the last
# upstream commit carrying it), labeled as the fallback it is. 1s bundling:
# 690bps AND 4x lower latency than the 4s bundles 700C would have needed.
C2_450="$PHASE5_DIR/native/codec2_450/build/src/c2enc"
ART_450="$PHASE5_DIR/artifacts/voice_ref_codec2-450.wav"
[ -x "$C2_450" ] || die "codec2 450 toolchain not built"
[ -f "$ART_450" ] || die "450 audible artifact missing (owner judges quality)"

# measure_ptt.py prints one line:
#   wire_bytes_60s bps bundling_s decoded_ratio_at_60loss queue_ok(ok|FAIL) anatomy_file
OUT=$(python3 "$PHASE5_DIR/measure_ptt.py" --window 60 --loss 0.60 --seed 53 \
      --frame-bits 18 --bundle 1 \
      --anatomy "$PHASE5_DIR/logs/ptt_anatomy.tsv")
echo "$OUT" > "$PHASE5_DIR/logs/ptt_result.txt"
read -r WIRE BPS BUNDLE RATIO QOK ANAT <<< "$OUT"
RAW=1920000  # 60s PCM 16kHz mono s16 reference baseline, stated in log

echo "wire_60s=${WIRE}B bps=$BPS bundling=${BUNDLE}s decoded_ratio@60%loss=$RATIO queue=$QOK"
echo "codec=codec2-450 (18b/40ms, measured-on-host; fallback labeled — 700C floor is 760bps)"
echo "anatomy: $ANAT (simulation-on-host; UDP/IPv4 28B computed per packet)"

STATUS=FAIL
BPS_OK=$(python3 -c "print(1 if float('$BPS')<=750 else 0)")
RATIO_OK=$(python3 -c "print(1 if abs(float('$RATIO')-0.40)<=0.05 else 0)")
BUNDLE_OK=$(python3 -c "print(1 if 1.0<=float('$BUNDLE')<=4.0 else 0)")
[ "$BPS_OK" = 1 ] && [ "$RATIO_OK" = 1 ] && [ "$BUNDLE_OK" = 1 ] && [ "$QOK" = ok ] \
  && STATUS='PASS(fallback:codec2-450)'
tsv_row_replace "PTT" "${RAW}B" "${WIRE}B" "$(wire_time_2kbps "$WIRE")" \
  "ratio=${RATIO}@60%loss,queue=$QOK" "$STATUS"
echo "gate_5 -> $STATUS (bps=$BPS budget=750)"
case "$STATUS" in PASS*) exit 0 ;; *) exit 1 ;; esac
