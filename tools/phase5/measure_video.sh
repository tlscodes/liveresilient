#!/bin/bash
# Peak 4 measurer — 5s reference clip -> raw AV1 + Codec2 under a 12B header,
# total <= 15360B, >= 10 frames decoded. measured-on-host.
# Ladder (first fit wins; every rung is SVT-AV1 unless it falls to libaom):
#   96x64@3fps  crf 50, 56, 63
#   96x64@2fps  crf 56, 63
#   64x48@2fps  crf 63
# Decode proof: repackage -> IVF -> dav1d --muxer null; audio: c2dec on the
# unpacked bits. Artifact: side-by-side viewable mp4 from the decoded stream.
# Prints: wire hdr video audio frames label decode artifact
set -euo pipefail
SRC="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIR/artifacts"

# Codec2 audio once: 5s @ 8k -> 700C bits (raw bit file, no header)
ffmpeg -y -v error -i "$SRC" -t 5 -ar 8000 -ac 1 -f s16le "$WORK/a.raw"
c2enc 700C "$WORK/a.raw" "$WORK/a.c2" >/dev/null 2>&1

try() { # w h fps crf
  local w="$1" h="$2" fps="$3" crf="$4"
  ffmpeg -y -v error -i "$SRC" -t 5 -vf "scale=${w}:${h},fps=${fps}" \
    -pix_fmt yuv420p "$WORK/v.y4m"
  SvtAv1EncApp --preset 8 --crf "$crf" --keyint 64 -i "$WORK/v.y4m" \
    -b "$WORK/v.ivf" >/dev/null 2>&1 || return 1
  python3 "$DIR/pack_video_note.py" pack "$WORK/v.ivf" "$WORK/a.c2" \
    "$WORK/note.bin" "$fps" "$w" "$h"
  local total
  total=$(stat -f %z "$WORK/note.bin")
  [ "$total" -le 15360 ] || return 1
  # decode proof from the packaged stream, never from the encoder's output
  python3 "$DIR/pack_video_note.py" unpack "$WORK/note.bin" \
    "$WORK/back.ivf" "$WORK/back.c2"
  # dav1d prints rolling progress lines; only the LAST "Decoded X/Y" is the
  # final count (first-line parsing under-reported 15/15 as 1).
  local frames
  frames=$(dav1d -i "$WORK/back.ivf" -o /dev/null --muxer null 2>&1 \
    | grep -oE 'Decoded [0-9]+/' | tail -1 | grep -oE '[0-9]+')
  frames=${frames:-0}
  cmp -s "$WORK/a.c2" "$WORK/back.c2" || return 1
  c2dec 700C "$WORK/back.c2" "$WORK/adec.raw" >/dev/null 2>&1 || return 1
  read -r TOTAL HDRB VIDEO AUDIO NFRAMES \
    <<< "$(python3 "$DIR/pack_video_note.py" stats "$WORK/note.bin")"
  local dec=ok
  [ "$frames" -ge 10 ] || dec=FAIL
  # owner-viewable artifact: decoded video + decoded audio remuxed
  ffmpeg -y -v error -i "$WORK/back.ivf" \
    -f s16le -ar 8000 -ac 1 -i "$WORK/adec.raw" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac \
    "$DIR/artifacts/video_note_preview.mp4" 2>/dev/null || true
  cp -f "$WORK/note.bin" "$DIR/artifacts/video_note_15k.bin"
  echo "$TOTAL $HDRB $VIDEO $AUDIO $frames svt-av1 $dec $DIR/artifacts/video_note_15k.bin"
  return 0
}

# best quality first: the first rung that fits the 15360B budget wins
try 128 96 3 40 && exit 0
try 128 96 3 50 && exit 0
try 96 64 3 35 && exit 0
try 96 64 3 45 && exit 0
try 96 64 3 55 && exit 0
try 96 64 3 63 && exit 0
try 96 64 2 63 && exit 0
try 64 48 2 63 && exit 0
echo "0 0 0 0 0 none FAIL -"
exit 1
