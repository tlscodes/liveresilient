#!/usr/bin/env bash
# make_video_letter.sh — a video letter for the door, made on the Mac with the
# rig's smallest video codec (the phase-5 video-note wire: 12 B header, raw
# SVT-AV1 frames 3 B-length-prefixed, then Codec2 700C audio; see
# packages/broadcast_media/lib/src/video_note_codec.dart and
# tools/phase5/pack_video_note.py). Feed the result to journey_run.sh as
# JOURNEY_VALVE_CHAT_FILE: over 4096 B it rides as up to ten letters.
#
# USAGE  tools/t2/make_video_letter.sh <src> <seconds> <out.bin> [w h fps crf]
#        defaults 128 96 3 40 — the ladder's top rung (704–1185 B/s measured
#        2026-09-21; 30 s ≈ 21–35 KB, 6–9 letters). Prints the bytes, the
#        frames and how many letters it needs; exits 3 when it needs more
#        than ten (then lower the rung or the seconds — never the cap).
set -euo pipefail
SRC=${1:?src}; SECS=${2:?seconds}; OUT=${3:?out}
W=${4:-128}; H=${5:-96}; FPS=${6:-3}; CRF=${7:-40}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PACK="$REPO/tools/phase5/pack_video_note.py"
for tool in ffmpeg SvtAv1EncApp c2enc python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ffmpeg -y -v error -i "$SRC" -t "$SECS" -vn -ac 1 -ar 8000 -f s16le "$T/a.raw"
c2enc 700C "$T/a.raw" "$T/a.c2" >/dev/null 2>&1
ffmpeg -y -v error -i "$SRC" -t "$SECS" -vf "scale=${W}:${H},fps=${FPS}" -pix_fmt yuv420p "$T/v.y4m"
SvtAv1EncApp --preset 8 --crf "$CRF" --keyint 64 -i "$T/v.y4m" -b "$T/v.ivf" >/dev/null 2>&1
python3 "$PACK" pack "$T/v.ivf" "$T/a.c2" "$OUT" "$FPS" "$W" "$H"
read -r TOTAL HDRB VIDEO AUDIO NFRAMES <<< "$(python3 "$PACK" stats "$OUT")"
LETTERS=$(( (TOTAL + 4066) / 4067 ))
[ "$TOTAL" -le 4096 ] && LETTERS=1
echo "video letter ${W}x${H}@${FPS} crf $CRF, ${SECS}s: $TOTAL B (video $VIDEO, audio $AUDIO, $NFRAMES frames) -> $LETTERS letter(s)"
[ "$LETTERS" -le 10 ] || { echo "ERROR: needs $LETTERS letters, the door takes ten" >&2; exit 3; }
