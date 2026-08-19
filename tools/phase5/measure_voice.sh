#!/bin/bash
# Peak 3 measurer — 10s reference speech -> Codec2 wire bytes + decode +
# audible artifact. measured-on-host: c2enc/c2dec from brew codec2.
# Wire accounting matches voice_note_codec.dart: 4B header + bit-packed
# frames. 700C emits 28 bits per 40ms frame -> 10s = 250 frames = 875B
# packed + 4B header = 879B. c2enc's file output pads each frame to 4 bytes;
# the packed size is computed from the honest bit count, and decode runs on
# the same c2enc output the packing is derived from.
# Fallback (labeled): codec2 1200 mode if 700C fails to decode.
# Prints: wire_bytes codec_label decode(ok|FAIL) artifact_path
set -euo pipefail
SRC="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIR/artifacts"

# Codec2 wants 8kHz s16 mono raw
ffmpeg -y -v error -i "$SRC" -ar 8000 -ac 1 -f s16le "$WORK/in.raw"

try_mode() { # mode_name c2_mode bits_per_frame frame_ms label
  local c2mode="$1" bpf="$2" frame_ms="$3" label="$4"
  c2enc "$c2mode" "$WORK/in.raw" "$WORK/enc.bit" >/dev/null 2>&1 || return 1
  c2dec "$c2mode" "$WORK/enc.bit" "$WORK/dec.raw" >/dev/null 2>&1 || return 1
  # frames = duration / frame_ms; duration from input bytes (8000 Hz * 2B)
  local in_bytes frames packed wire
  in_bytes=$(stat -f %z "$WORK/in.raw")
  frames=$(python3 -c "print(int(round($in_bytes/16000*1000/$frame_ms)))")
  packed=$(python3 -c "import math; print(math.ceil($frames*$bpf/8))")
  wire=$((packed + 4))
  ffmpeg -y -v error -f s16le -ar 8000 -ac 1 -i "$WORK/dec.raw" \
    "$DIR/artifacts/voice_ref_${label}.wav"
  echo "$wire $label ok $DIR/artifacts/voice_ref_${label}.wav"
  return 0
}

try_mode 700C 28 40 codec2-700c && exit 0
try_mode 1200 48 40 codec2-1200 && exit 0
echo "0 none FAIL -"
exit 1
