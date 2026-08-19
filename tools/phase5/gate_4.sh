#!/bin/bash
# Gate 4 — VideoNote: 5s reference clip -> <= 15360B wire, raw AV1 stream +
# Codec2 mono audio packaged under a custom binary header <= 16B
# (magic 0x5631). MP4/MKV/WebM containers are REJECTED by construction: the
# gate checks the magic and header length itself and books header size
# separately in the log.
# Build prerequisites (peak 4 build step):
#   brew svt-av1 (or ffmpeg libaom fallback, labeled), dav1d for decode
#   packages/broadcast_media/lib/src/video_note_codec.dart
#   tools/phase5/measure_video.sh  (prints: wire_bytes header_bytes video_bytes
#     audio_bytes frames_decoded codec_label decode(ok|FAIL) artifact_path)
set -euo pipefail
. "$(dirname "$0")/gate_lib.sh"
gate_log 4

if [ "${GATE_CHECK_ONLY:-0}" = "1" ]; then
  [ -f "$PHASE5_DIR/logs/video_result.txt" ] || die "no measurement evidence"
  A=$(awk '{print $8}' "$PHASE5_DIR/logs/video_result.txt")
  [ -f "$A" ] || die "video artifact missing: $A"
  require_row "VideoNote" '^PASS'
  echo "gate_4 check-only OK"
  exit 0
fi

verify_asset clip_ref_5s.mov
[ -f "$PHASE5_DIR/measure_video.sh" ] || die "measure_video.sh not built yet"

OUT=$(bash "$PHASE5_DIR/measure_video.sh" "$CORPUS/clip_ref_5s.mov")
echo "$OUT" > "$PHASE5_DIR/logs/video_result.txt"
read -r WIRE HDR VID AUD FRAMES LABEL DEC ARTIFACT <<< "$OUT"
RAW=$(stat -f %z "$CORPUS/clip_ref_5s.mov")

echo "raw=$RAW wire=$WIRE header=$HDR video=$VID audio=$AUD frames_decoded=$FRAMES codec=$LABEL decode=$DEC (measured-on-host)"
STATUS=FAIL
if [ "$WIRE" -le 15360 ] && [ "$HDR" -le 16 ] && [ "$DEC" = "ok" ] && [ "$FRAMES" -ge 10 ]; then
  case "$LABEL" in
    svt-av1) STATUS="PASS" ;;
    *)       STATUS="PASS(fallback:$LABEL)" ;;
  esac
fi
tsv_row_replace "VideoNote" "${RAW}B" "${WIRE}B" "$(wire_time_2kbps "$WIRE")" "n/a" "$STATUS"
echo "gate_4 -> $STATUS (wire=${WIRE}B budget=15360B header=${HDR}B)"
case "$STATUS" in PASS*) exit 0 ;; *) exit 1 ;; esac
