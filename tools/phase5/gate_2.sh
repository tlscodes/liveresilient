#!/bin/bash
# Gate 2 — Photo: reference camera JPEG (2-10MB) -> wire image <= 3072B that
# decodes successfully. Primary target codec: AVIF (avifenc). Sanctioned
# fallback with its own honest label: aggressively quantized WebP
# (Status becomes PASS(fallback:webp-gray-q) — never plain PASS).
# Build prerequisites (peak 2 build step):
#   packages/broadcast_media/lib/src/compact_photo_codec.dart
#   tools/phase5/measure_photo.sh  (encode pipeline; prints:
#     wire_bytes codec_label decode(ok|FAIL) artifact_path)
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 2

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$PHASE5_DIR/logs/photo_result.txt" ] || die "no measurement evidence"
  A=$(awk '{print $4}' "$PHASE5_DIR/logs/photo_result.txt")
  [ -f "$A" ] || die "photo artifact missing: $A"
  require_row "Photo" '^PASS'
  echo "gate_2 check-only OK"
  exit 0
fi

verify_asset photo_ref.jpg
[ -f "$PHASE5_DIR/measure_photo.sh" ] || die "measure_photo.sh not built yet"

OUT=$(bash "$PHASE5_DIR/measure_photo.sh" "$CORPUS/photo_ref.jpg")
echo "$OUT" > "$PHASE5_DIR/logs/photo_result.txt"
read -r WIRE LABEL DEC ARTIFACT <<< "$OUT"
RAW=$(stat -f %z "$CORPUS/photo_ref.jpg")

echo "raw=$RAW wire=$WIRE codec=$LABEL decode=$DEC artifact=$ARTIFACT"
STATUS=FAIL
if [ "$WIRE" -le 3072 ] && [ "$DEC" = "ok" ]; then
  case "$LABEL" in
    avif) STATUS="PASS" ;;
    *)    STATUS="PASS(fallback:$LABEL)" ;;
  esac
fi
tsv_row_replace "Photo" "${RAW}B" "${WIRE}B" "$(wire_time_2kbps "$WIRE")" "n/a" "$STATUS"
echo "gate_2 -> $STATUS (wire=${WIRE}B budget=3072B)"
case "$STATUS" in PASS*) exit 0 ;; *) exit 1 ;; esac
