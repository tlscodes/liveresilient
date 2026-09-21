#!/usr/bin/env bash
# hf_gap.sh <audio> — full-band mean, 4.5 kHz-highpassed mean, and the gap
# between them (dB): the one number that says whether a "wideband" letter
# actually carries the 4-8 kHz band. Raw input:
#   INFLAGS="-f s16le -ar 48000 -ac 1" hf_gap.sh video_letter.s16le
# PASS for a speech take (same owner, same room):
#   gap(video tail wav, NoLACE decode) <= gap(the voice letter's wav) + 6
#   gap(reader s16le) within 3 dB of gap(tail)  (else the loss is upstream of Opus)
# Measured 2026-09-22 on the first phone video with a raw, unnormalised
# tail (eccf9eb0.mp4): gap 37.3 dB (-36.5 vs -73.8) — SILK starved the
# high band on a -36 dB input. (Fable 5.1's acceptance check.)
set -euo pipefail
IN=${1:?audio}
mean() {
  ffmpeg -v info ${INFLAGS:-} -i "$IN" -af "$1" -f null - 2>&1 \
    | grep -oE 'mean_volume: [-0-9.]+' | grep -oE '[-0-9.]+' | tail -1
}
FULL=$(mean volumedetect)
HP=$(mean "highpass=f=4500:p=2,volumedetect")
echo "full $FULL dB  hp4500 $HP dB  gap $(python3 -c "print(round($FULL-($HP),1))") dB"
