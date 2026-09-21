#!/usr/bin/env bash
# open_video_letter.sh — the receiver's half of a video letter on the Mac:
# a phase-5 video-note wire (magic 'V1') as the responder assembled it ->
# frames decoded with dav1d, audio with c2dec, muxed to one mp4 the person
# can play. Never guesses: a wire that does not unpack or decode exits 2.
#
# USAGE  tools/t2/open_video_letter.sh <letter.bin> <out.mp4>
#        prints "video <seconds>s <w>x<h>@<fps> frames <n> -> <out.mp4>"
set -euo pipefail
IN=${1:?letter}; OUT=${2:?out.mp4}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PACK="$REPO/tools/phase5/pack_video_note.py"
for tool in dav1d c2dec ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 "$PACK" unpack "$IN" "$T/v.ivf" "$T/a.c2"
FPS=$(od -An -j2 -N1 -tu1 "$IN" | tr -d ' ')
W=$(python3 -c "d=open('$IN','rb').read(); print(d[3]|d[4]<<8)")
H=$(python3 -c "d=open('$IN','rb').read(); print(d[5]|d[6]<<8)")
dav1d -i "$T/v.ivf" -o "$T/v.y4m" >/dev/null 2>&1
FRAMES=$(dav1d -i "$T/v.ivf" -o /dev/null --muxer null 2>&1 | grep -oE 'Decoded [0-9]+/' | tail -1 | grep -oE '[0-9]+')
c2dec 700C "$T/a.c2" "$T/a.raw" >/dev/null 2>&1
ffmpeg -y -v error -r "$FPS" -i "$T/v.y4m" -f s16le -ar 8000 -ac 1 -i "$T/a.raw" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 18 -vf "scale=iw*4:ih*4:flags=neighbor" \
  -c:a aac -b:a 24k -shortest "$OUT"
SECS=$(python3 -c "print(round(${FRAMES:-0}/${FPS}, 1))")
echo "video ${SECS}s ${W}x${H}@${FPS} frames ${FRAMES:-0} -> $OUT"
