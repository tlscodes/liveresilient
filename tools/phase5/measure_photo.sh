#!/bin/bash
# Peak 2 measurer — camera JPEG -> smallest decodable wire image <= 3072B.
# Wire carries the codec bitstream ONLY: Exif/ICC metadata is stripped
# (first run measured 334B of AVIF pixels wrapped in 3270B of camera
# metadata — the wire format never ships Exif).
# Ladder (stops at the FIRST fit, searching from best quality down, honest
# label for whatever produced it):
#   1. AVIF color 120x160, -q sweep high -> low (--ignore-exif --ignore-icc)
#   2. AVIF grayscale 120x160, same sweep
#   3. WebP grayscale 120x160, quality sweep (labeled fallback)
# Decode is re-proven with the matching decoder (avifdec / dwebp).
# Prints one line: wire_bytes codec_label decode(ok|FAIL) artifact_path
set -euo pipefail
SRC="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIR/artifacts"

ffmpeg -y -v error -i "$SRC" -map_metadata -1 -vf "scale=120:160" "$WORK/small.png"
ffmpeg -y -v error -i "$SRC" -map_metadata -1 -vf "scale=120:160,format=gray" "$WORK/gray.png"

emit() { # file label decode artifact
  cp -f "$1" "$4"
  echo "$(stat -f %z "$1") $2 $3 $4"
  exit 0
}

for Q in 75 60 50 40 30 20 14 8; do
  avifenc -s 6 -q "$Q" --ignore-exif --ignore-icc \
    "$WORK/small.png" "$WORK/o.avif" >/dev/null 2>&1 || continue
  if [ "$(stat -f %z "$WORK/o.avif")" -le 3072 ]; then
    avifdec "$WORK/o.avif" "$WORK/back.png" >/dev/null 2>&1 \
      && emit "$WORK/o.avif" avif ok "$DIR/artifacts/photo_ref_3k.avif" \
      || emit "$WORK/o.avif" avif FAIL "$DIR/artifacts/photo_ref_3k.avif"
  fi
done

for Q in 75 60 50 40 30 20 14 8; do
  avifenc -s 6 -q "$Q" --ignore-exif --ignore-icc \
    "$WORK/gray.png" "$WORK/og.avif" >/dev/null 2>&1 || continue
  if [ "$(stat -f %z "$WORK/og.avif")" -le 3072 ]; then
    avifdec "$WORK/og.avif" "$WORK/back.png" >/dev/null 2>&1 \
      && emit "$WORK/og.avif" avif-gray ok "$DIR/artifacts/photo_ref_3k.avif" \
      || emit "$WORK/og.avif" avif-gray FAIL "$DIR/artifacts/photo_ref_3k.avif"
  fi
done

for Q in 30 20 10 5; do
  cwebp -quiet -metadata none -q "$Q" "$WORK/gray.png" -o "$WORK/o.webp" || continue
  if [ "$(stat -f %z "$WORK/o.webp")" -le 3072 ]; then
    dwebp -quiet "$WORK/o.webp" -o "$WORK/back.png" \
      && emit "$WORK/o.webp" webp-gray ok "$DIR/artifacts/photo_ref_3k.webp" \
      || emit "$WORK/o.webp" webp-gray FAIL "$DIR/artifacts/photo_ref_3k.webp"
  fi
done

echo "0 none FAIL -"
exit 1
