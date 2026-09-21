#!/usr/bin/env bash
# make_video_letter.sh — a video letter for the door, made on the Mac with the
# rig's smallest video codec (the phase-5 video-note wire: 12 B header, raw
# SVT-AV1 frames 3 B-length-prefixed, then Codec2 700C audio; see
# packages/broadcast_media/lib/src/video_note_codec.dart and
# tools/phase5/pack_video_note.py). Feed the result to journey_run.sh as
# JOURNEY_VALVE_CHAT_FILE: over 4096 B it rides as parts.
#
# USAGE  tools/t2/make_video_letter.sh <src> <seconds> <out.bin> [letters] [w h fps]
#        letters (default 20): the part budget the letter must fit —
#        10 → 160x120@5, 20 → 176x144@6, 30 → 208x156@8 unless w h fps are
#        given. The encoder is spent well (2026-09-21, after the Fable 5.1
#        consult): denoise before scaling (hqdn3d), area scaling, SVT-AV1
#        preset 4, tune 0 (VQ), ONE keyframe (--keyint -1), lookahead 120,
#        temporal filtering on; the crf ladder 32..56 step 3 takes the
#        LOWEST crf that fits, exactly like the photo ladder. Prints bytes,
#        frames, crf and how many letters it needs; exits 3 when it needs
#        more than the budget (then lower the shape or the seconds — never
#        the cap).
set -euo pipefail
SRC=${1:?src}; SECS=${2:?seconds}; OUT=${3:?out}
LETTERS=${4:-20}
case "$LETTERS" in
  10) DW=160; DH=120; DF=5 ;;
  20) DW=176; DH=144; DF=6 ;;
  30) DW=208; DH=156; DF=8 ;;
  *)  DW=176; DH=144; DF=6 ;;
esac
W=${5:-$DW}; H=${6:-$DH}; FPS=${7:-$DF}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PACK="$REPO/tools/phase5/pack_video_note.py"
PART_PAYLOAD=4067   # 4096 − 29 B part header; the cap per letter is untouched
BUDGET=$((LETTERS * PART_PAYLOAD))
for tool in ffmpeg SvtAv1EncApp c2enc python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ffmpeg -y -v error -i "$SRC" -t "$SECS" -vn -ac 1 -ar 8000 -f s16le "$T/a.raw"
c2enc 700C "$T/a.raw" "$T/a.c2" >/dev/null 2>&1
ffmpeg -y -v error -i "$SRC" -t "$SECS" \
  -vf "hqdn3d=3:2:6:4,scale=${W}:${H}:flags=area,fps=${FPS}" -pix_fmt yuv420p "$T/v.y4m"
FIT=""
for CRF in 32 35 38 41 44 47 50 53 56 60 63; do
  SvtAv1EncApp --preset 4 --tune 0 --keyint -1 --lookahead 120 --enable-tf 1 \
    --crf "$CRF" -i "$T/v.y4m" -b "$T/v.ivf" >/dev/null 2>&1
  python3 "$PACK" pack "$T/v.ivf" "$T/a.c2" "$T/note.bin" "$FPS" "$W" "$H"
  TOTAL=$(stat -f%z "$T/note.bin")
  if [ "$TOTAL" -le "$BUDGET" ]; then FIT=$CRF; cp "$T/note.bin" "$OUT"; break; fi
done
[ -n "$FIT" ] || { echo "ERROR: ${W}x${H}@${FPS} does not fit $LETTERS letters even at crf 63" >&2; exit 3; }
read -r TOTAL HDRB VIDEO AUDIO NFRAMES <<< "$(python3 "$PACK" stats "$OUT")"
NEED=$(( (TOTAL + PART_PAYLOAD - 1) / PART_PAYLOAD )); [ "$TOTAL" -le 4096 ] && NEED=1
echo "video letter ${W}x${H}@${FPS} crf $FIT preset 4, ${SECS}s: $TOTAL B (video $VIDEO, audio $AUDIO, $NFRAMES frames) -> $NEED letter(s) of $LETTERS"
