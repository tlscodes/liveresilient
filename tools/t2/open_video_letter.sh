#!/usr/bin/env bash
# open_video_letter_v2.sh — receiver v2 for the video letter. Reads the flags byte
# (low nibble = audio mode), decodes Codec2 700C/1200/1600/2400/3200 with c2dec or
# Opus 6k CBR with ffmpeg (packets rebuilt into Ogg by pack_video_note_v2.py), and
# a better display path. v1 letters (flags 0 = 700C) open unchanged.
#
# USAGE  open_video_letter_v2.sh <letter.bin> <out.mp4> [plain|enhanced]
#        "plain" = nearest 4x at native fps (the old comparison path).
#
# DISPLAY PATH (costs no bytes; ~real-time on a 2015 iMac at ≤256x192):
#   1. minterpolate to 24 fps at NATIVE size (mci/aobmc/bidir/vsbmc, epzs search,
#      search_param 24 — a little wider than v1 because 6 fps means bigger motion
#      vectors between neighbours; scd on so a cut does not get blended).
#   2. scale 4x with SPLINE (softer ringing than lanczos on block edges; the AV1
#      grain synthesis already supplies texture, we do not want halos around it).
#   3. deband after the upscale (thr 0.012, range 14, blur) — smooths the 8-bit
#      staircase that a 4x upscale exposes in skin and walls.
#   4. cas 0.35 (contrast-adaptive sharpen) instead of unsharp — sharpens edges
#      without amplifying grain or ringing the flat areas.
#   x264 crf 18 veryfast + aac 48k.
set -euo pipefail
IN=${1:?letter}; OUT=${2:?out.mp4}; MODE=${3:-enhanced}
HERE=$(cd "$(dirname "$0")" && pwd)
PACK="$HERE/pack_video_note_v2.py"
for tool in dav1d ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AMODE=$(python3 "$PACK" unpack "$IN" "$T/v.ivf" "$T/a.bits")
FPS=$(od -An -j2 -N1 -tu1 "$IN" | tr -d ' ')
W=$(python3 -c "d=open('$IN','rb').read(); print(d[3]|d[4]<<8)")
H=$(python3 -c "d=open('$IN','rb').read(); print(d[5]|d[6]<<8)")
# A two-band letter (2026-09-23) switches frame size mid-stream: page
# frames at 3x the moving band. dav1d's y4m writer cannot change size, so
# a mixed stream is decoded by ffmpeg's libdav1d and every frame is scaled
# to one output size first (page x1.33, motion x4) — the rest of the chain
# then sees a single size.
SIZES=$(ffprobe -v error -c:v libdav1d -select_streams v -show_entries frame=width,height \
  -of csv=p=0 "$T/v.ivf" 2>/dev/null | sort -u)
NSIZES=$(printf '%s\n' "$SIZES" | grep -c . || true)
FRAMES=$(ffprobe -v error -c:v libdav1d -count_frames -select_streams v \
  -show_entries stream=nb_read_frames -of csv=p=0 "$T/v.ivf" 2>/dev/null)
if [ "${NSIZES:-1}" -le 1 ]; then
  dav1d -i "$T/v.ivf" -o "$T/v.y4m" >/dev/null 2>&1
  VIN=(-r "$FPS" -i "$T/v.y4m")
else
  VIN=(-r "$FPS" -c:v libdav1d -i "$T/v.ivf")
fi

case "$AMODE" in
  700C|1200|1600|2400|3200)
    command -v c2dec >/dev/null || { echo "ERROR: c2dec not installed" >&2; exit 2; }
    c2dec "$AMODE" "$T/a.bits" "$T/a.raw" >/dev/null 2>&1
    AIN=(-f s16le -ar 8000 -ac 1 -i "$T/a.raw") ;;
  opus)
    python3 "$PACK" opus-ogg "$T/a.bits" "$T/a.opus" 45 >/dev/null
    AIN=(-i "$T/a.opus") ;;
  opusvbr)
    # NoLACE for the ear: the letter's own libopus at decoder complexity 7,
    # never ffmpeg's plain decoder — the voice letter was judged this way
    # (2026-09-22).
    ( cd "$(dirname "$0")/../../packages/hamseda_codec" \
      && dart run tool/decode_video_tail.dart "$T/a.bits" "$T/a.wav" 7 >/dev/null )
    AIN=(-i "$T/a.wav") ;;
  *) echo "ERROR: unknown audio mode '$AMODE' in flags byte" >&2; exit 2 ;;
esac

if [ "${NSIZES:-1}" -gt 1 ]; then
  # Two bands: one output size for both, lanczos, a firm cas for the text
  # the page frames carry. No motion interpolation: inventing frames across
  # a page would smear exactly the print the page band is there to carry.
  OW=$((W * 4)); OH=$((H * 4))
  VF="scale=${OW}:${OH}:flags=lanczos:param0=3,setsar=1"
  VF="$VF,deband=1thr=0.008:2thr=0.008:3thr=0.008:range=8:blur=1"
  VF="$VF,cas=0.6"
  OUTFPS=$FPS
  MODE="two-band, pages $(printf '%s\n' "$SIZES" | grep -vc "^${W},${H}$" || true) size(s)"
elif [ "$MODE" = plain ]; then
  VF="scale=iw*4:ih*4:flags=neighbor"; OUTFPS=$FPS
else
  # For a talking face (2026-09-22): denoise the crf pulse first, invent
  # only one mid-frame (12 fps — 24 fps from 6 warped the lips), lanczos
  # instead of the softest kernel, a firmer cas.
  VF="hqdn3d=1.0:0.8:3.0:2.5"
  VF="$VF,minterpolate=fps=12:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:me=epzs:vsbmc=1:search_param=32:scd=fdiff:scd_threshold=8:mb_size=16"
  VF="$VF,scale=iw*4:ih*4:flags=lanczos:param0=3"
  VF="$VF,deband=1thr=0.010:2thr=0.010:3thr=0.010:range=12:blur=1"
  VF="$VF,cas=0.5"
  OUTFPS=12
fi
ffmpeg -y -v error "${VIN[@]}" "${AIN[@]}" \
  -vf "$VF" -r "$OUTFPS" -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 18 \
  -c:a aac -b:a 48k -ar 16000 -shortest "$OUT"
SECS=$(python3 -c "print(round(${FRAMES:-0}/${FPS}, 1))")
echo "video ${SECS}s ${W}x${H}@${FPS} frames ${FRAMES:-0} audio $AMODE ($MODE) -> $OUT"
