#!/bin/bash
# Phase 5 step zero — assemble the fixed-name reference corpus and pin every
# item's sha256 in manifest.tsv. Idempotent: re-running regenerates the same
# derived assets from the same sources and rewrites the manifest.
# Sources (recorded per item in the manifest's source column):
#   photo_ref.jpg      <- real iPhone camera JPEG (12MP), copied unmodified
#   speech_ref_10s.wav <- first 10s of demo_audio/level1_original.wav
#                         (real recorded speech, 24kHz mono), resampled 16kHz s16
#   clip_ref_5s.mov    <- 5s excerpt (t=30s) of a real phone video 1080x1920@30,
#                         re-encoded once h264 crf18 + aac128k as the frozen ref
#   chat_corpus_200.jsonl / chat_train_2000.jsonl <- make_chat_corpus.py (seeded)
#   news_ref_page.json <- authored fixed reference page (~300 fa words + blurhash)
set -euo pipefail
cd "$(dirname "$0")"

PHOTO_SRC="${PHOTO_SRC:-$HOME/Downloads/IMG_4565.jpg}"   # override for another machine
SPEECH_SRC="../../demo_audio/level1_original.wav"
CLIP_SRC="${CLIP_SRC:-$HOME/Movies/reference_clip.mp4}"   # override for another machine

mkdir -p corpus native .markers logs artifacts

python3 make_chat_corpus.py >/dev/null

cp -f "$PHOTO_SRC" corpus/photo_ref.jpg

ffmpeg -y -v error -i "$SPEECH_SRC" -t 10 -ar 16000 -ac 1 -sample_fmt s16 \
  corpus/speech_ref_10s.wav

ffmpeg -y -v error -ss 30 -i "$CLIP_SRC" -t 5 \
  -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart \
  corpus/clip_ref_5s.mov

# manifest: name, bytes, sha256, source label
MANIFEST=corpus/manifest.tsv
printf 'name\tbytes\tsha256\tsource\n' > "$MANIFEST.tmp"
row() {
  local f="corpus/$1" label="$2"
  local bytes sha
  bytes=$(stat -f %z "$f")
  sha=$(shasum -a 256 "$f" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\n' "$1" "$bytes" "$sha" "$label" >> "$MANIFEST.tmp"
}
row chat_corpus_200.jsonl  "make_chat_corpus.py seed=53 (eval)"
row chat_train_2000.jsonl  "make_chat_corpus.py seed=54 (dict training only)"
row news_ref_page.json     "authored fixed reference page"
row photo_ref.jpg          "iPhone camera JPEG, copied unmodified"
row speech_ref_10s.wav     "level1_original.wav 0-10s, 16kHz mono s16 (real speech)"
row clip_ref_5s.mov        "real phone video, 5s @ t=30s, h264 crf18 (frozen ref)"
mv "$MANIFEST.tmp" "$MANIFEST"

# hard checks: sizes in contract ranges
photo_bytes=$(stat -f %z corpus/photo_ref.jpg)
[ "$photo_bytes" -ge 2000000 ] && [ "$photo_bytes" -le 10485760 ] \
  || { echo "photo_ref.jpg out of 2-10MB contract: $photo_bytes"; exit 1; }
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 corpus/speech_ref_10s.wav)
python3 -c "import sys; d=float('$dur'); sys.exit(0 if 9.9<=d<=10.1 else 1)" \
  || { echo "speech_ref_10s.wav duration off: $dur"; exit 1; }
cdur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 corpus/clip_ref_5s.mov)
python3 -c "import sys; d=float('$cdur'); sys.exit(0 if 4.8<=d<=5.3 else 1)" \
  || { echo "clip_ref_5s.mov duration off: $cdur"; exit 1; }

cat "$MANIFEST"
echo "CORPUS OK"
