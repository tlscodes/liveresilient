#!/bin/bash
# Gate 3 — VoiceNote: 10s of reference speech -> <= 1000B wire, successful
# decode, audible artifact delivered for owner judgement (perceptual quality is
# NOT mechanically gated; bytes and decodability are).
# Primary codec: Codec2 700C (c2enc/c2dec, measured-on-host). 1200 mode is the
# labeled fallback: PASS(fallback:codec2-1200) — only if it fits the budget.
# Build prerequisites (peak 3 build step):
#   brew codec2 (c2enc/c2dec on PATH or tools/phase5/native/)
#   packages/hamseda_codec/lib/src/voice_note_codec.dart
#   tools/phase5/measure_voice.sh  (prints: wire_bytes codec_label decode(ok|FAIL)
#     artifact_path)
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 3

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$PHASE5_DIR/logs/voice_result.txt" ] || die "no measurement evidence"
  A=$(awk '{print $4}' "$PHASE5_DIR/logs/voice_result.txt")
  [ -f "$A" ] || die "voice artifact missing: $A"
  require_row "VoiceNote" '^PASS'
  echo "gate_3 check-only OK"
  exit 0
fi

verify_asset speech_ref_10s.wav
[ -f "$PHASE5_DIR/measure_voice.sh" ] || die "measure_voice.sh not built yet"

OUT=$(bash "$PHASE5_DIR/measure_voice.sh" "$CORPUS/speech_ref_10s.wav")
echo "$OUT" > "$PHASE5_DIR/logs/voice_result.txt"
read -r WIRE LABEL DEC ARTIFACT <<< "$OUT"
RAW=$(stat -f %z "$CORPUS/speech_ref_10s.wav")

echo "raw=$RAW wire=$WIRE codec=$LABEL decode=$DEC artifact=$ARTIFACT (measured-on-host)"
STATUS=FAIL
if [ "$WIRE" -le 1000 ] && [ "$DEC" = "ok" ]; then
  case "$LABEL" in
    codec2-700c) STATUS="PASS" ;;
    *)           STATUS="PASS(fallback:$LABEL)" ;;
  esac
fi
tsv_row_replace "VoiceNote" "${RAW}B" "${WIRE}B" "$(wire_time_2kbps "$WIRE")" "n/a" "$STATUS"
echo "gate_3 -> $STATUS (wire=${WIRE}B budget=1000B)"
case "$STATUS" in PASS*) exit 0 ;; *) exit 1 ;; esac
