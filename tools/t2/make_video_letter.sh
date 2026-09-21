#!/usr/bin/env bash
# make_video_letter_v2.sh — video letter v2: better audio AND better video in the
# same 20 / 30 letters. Same wire as v1 (12 B header, 3 B-prefixed AV1 frames,
# raw audio) — the ONLY wire change is the flags byte, low nibble = audio mode.
#
# USAGE  make_video_letter_v2.sh <src> <seconds> <out.bin> [letters] [w h fps]
#        env: AUDIO=700C|1200|1600|2400|3200|opus  (overrides the per-budget pick)
#             PRESET=3 (SVT-AV1 preset; 2 doubles the time for ~2-3 % bytes)
#             GRAIN=6  (--film-grain level; 0 = off)
#
# BUDGET SPLIT (ESTIMATES for a 30 s letter; part payload 4067 B, cap untouched):
#   letters  budget   audio pick   audio B   video B   video kbit/s  shape ladder start
#   10       40670    Codec2 1200    4500     36158        9.6       160x120@5
#   20       81340    Codec2 2400    9000     72328       19.3       192x144@6
#   30      122010    Codec2 3200   12000    109998       29.3       224x168@6
#   30 (AUDIO=opus)   Opus 6k CBR   22500     99498       26.5       224x168@6 (crf higher)
# Shape is chosen from the VIDEO bitrate actually available (budget − audio −
# header) so a shorter/longer letter still lands on the right rung:
#   < 12 kbit/s 160x120@5 · <16 176x132@6 · <22 192x144@6 · <30 224x168@6 · ≥30 256x192@6
# If the crf ladder (29..63 step 3, LOWEST crf that fits) fails at crf 63 the
# script drops ONE rung and retries once; exit 3 if it still does not fit.
#
# ENCODER (every flag checked against SvtAv1EncApp v4.2.0 --help):
#   --preset 3        real gain over 4 at these sizes (better partitioning/TX search),
#                     still seconds per pass on a 2015 iMac for 180 frames.
#   --tune 0          VQ (subjective), as v1.
#   --keyint -1       one keyframe; --scd 1 so a real cut in the clip still gets a key
#                     instead of a smeared inter frame.
#   --lookahead 120   --enable-tf 1  temporal filtering on (as v1).
#   --film-grain 6 --film-grain-denoise 0
#                     grain SYNTHESIS: a few hundred bytes of frame-header params buy
#                     decode-side texture that hides flat blocks and banding at
#                     ~20 kbit/s. Level 6 (not 10-20): the source is already hqdn3d'd,
#                     so the estimated grain is subtle; denoise 0 = we denoise upstream.
#   --enable-qm 1 --qm-min 0
#                     quant matrices: bytes go to low frequencies people see, not to
#                     high-frequency noise — a known perceptual win at low bitrates.
#   --enable-overlays 0  overlay frames cost bytes at every ALT-REF; at ≤30 kbit/s
#                     they were judged not worth it (flip to 1 to measure).
# PRE-FILTER: hqdn3d 4:3:6:4.5 (luma spatial a touch stronger than v1 — noise is the
# most expensive thing an encoder can be asked to keep), then AREA downscale with
# aspect fill + centre crop (no bars, subject larger), then fps. No sharpening before
# the downscale (it would re-create the noise we just removed) and no deband (grain
# synthesis covers banding for free on the receiver).
set -euo pipefail
SRC=${1:?src}; SECS=${2:?seconds}; OUT=${3:?out}
LETTERS=${4:-20}
PRESET=${PRESET:-3}; GRAIN=${GRAIN:-0}   # grain 6 cost ~6 VMAF at 20 letters (measured 2026-09-21): off by default
HERE=$(cd "$(dirname "$0")" && pwd)
PACK="$HERE/pack_video_note_v2.py"
PART_PAYLOAD=4067
BUDGET=$((LETTERS * PART_PAYLOAD))
for tool in ffmpeg SvtAv1EncApp c2enc python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not installed" >&2; exit 2; }
done

# ---- audio pick per budget (env AUDIO overrides) -----------------------------
if [ -z "${AUDIO:-}" ]; then
  if   [ "$LETTERS" -le 10 ]; then AUDIO=1200
  elif [ "$LETTERS" -le 20 ]; then AUDIO=2400
  else                             AUDIO=3200; fi
fi
case "$AUDIO" in
  700C) ABPS=700 ;; 1200) ABPS=1200 ;; 1600) ABPS=1600 ;; 2400) ABPS=2400 ;; 3200) ABPS=3200 ;;
  opus) ABPS=6000 ;;
  *) echo "ERROR: AUDIO must be 700C|1200|1600|2400|3200|opus" >&2; exit 2 ;;
esac
AUDIO_EST=$(( ABPS * SECS / 8 ))
VIDEO_BUDGET=$(( BUDGET - AUDIO_EST - 12 ))
VKBPS=$(( VIDEO_BUDGET * 8 / SECS / 1000 ))

# ---- shape ladder from the video bitrate actually available --------------------
LADDER=("160 120 5" "176 132 6" "192 144 6" "224 168 6" "256 192 6")
if   [ "$VKBPS" -lt 12 ]; then RUNG=0
elif [ "$VKBPS" -lt 16 ]; then RUNG=1
elif [ "$VKBPS" -lt 22 ]; then RUNG=2
elif [ "$VKBPS" -lt 30 ]; then RUNG=3
else                            RUNG=4; fi
if [ $# -ge 7 ]; then FORCED=1; W=$5; H=$6; FPS=$7; else FORCED=0; read -r W H FPS <<< "${LADDER[$RUNG]}"; fi

# Keep the SOURCE's aspect (a phone video is portrait): the rung gives a
# pixel budget (w*h), the shape takes the source's aspect at that budget,
# rounded to multiples of 8, and nothing is cropped or squashed. (The first
# v2 cut fill+cropped a 9:16 clip to 4:3 and lost a quarter of the frame;
# v1 squashed it.)
read -r SW SH <<< "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$SRC" | tr ',' ' ')"
if [ "$FORCED" = 0 ] && [ -n "${SW:-}" ] && [ -n "${SH:-}" ]; then
  read -r W H <<< "$(python3 -c "
import math
area=$W*$H; ar=$SW/$SH
w=max(8,int(round(math.sqrt(area*ar)/8))*8); h=max(8,int(round(math.sqrt(area/ar)/8))*8)
print(w,h)")"
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- audio ---------------------------------------------------------------------
if [ "$AUDIO" = opus ]; then
  command -v ffmpeg >/dev/null
  ffmpeg -y -v error -i "$SRC" -t "$SECS" -vn -ac 1 -ar 8000 \
    -c:a libopus -b:a 6k -vbr off -frame_duration 60 -application voip -compression_level 10 \
    "$T/a.opus"
  python3 "$PACK" opus-extract "$T/a.opus" "$T/a.bits" 45 >/dev/null
else
  ffmpeg -y -v error -i "$SRC" -t "$SECS" -vn -ac 1 -ar 8000 -f s16le "$T/a.raw"
  c2enc "$AUDIO" "$T/a.raw" "$T/a.bits" >/dev/null 2>&1
fi

# ---- video: pre-filter once per shape, crf ladder, one rung of fallback ----------
encode_shape() {  # $1=W $2=H $3=FPS -> sets FIT (crf) or ""
  local w=$1 h=$2 fps=$3 crf
  ffmpeg -y -v error -i "$SRC" -t "$SECS" \
    -vf "hqdn3d=4:3:6:4.5,scale=${w}:${h}:flags=area,fps=${fps}" \
    -pix_fmt yuv420p "$T/v.y4m"
  FIT=""
  for crf in 29 32 35 38 41 44 47 50 53 56 60 63; do
    SvtAv1EncApp --preset "$PRESET" --tune 0 --keyint -1 --scd 1 --lookahead 120 --enable-tf 1 \
      --film-grain "$GRAIN" --film-grain-denoise 0 --enable-qm 1 --qm-min 0 --enable-overlays 0 \
      --crf "$crf" -i "$T/v.y4m" -b "$T/v.ivf" >/dev/null 2>&1
    python3 "$PACK" pack "$T/v.ivf" "$T/a.bits" "$T/note.bin" "$fps" "$w" "$h" "$AUDIO"
    local total; total=$(stat -f%z "$T/note.bin")
    if [ "$total" -le "$BUDGET" ]; then FIT=$crf; cp "$T/note.bin" "$OUT"; break; fi
  done
}
encode_shape "$W" "$H" "$FPS"
if [ -z "$FIT" ] && [ "$FORCED" = 0 ] && [ "$RUNG" -gt 0 ]; then
  RUNG=$((RUNG - 1)); read -r W H FPS <<< "${LADDER[$RUNG]}"
  echo "note: dropping one rung to ${W}x${H}@${FPS}" >&2
  encode_shape "$W" "$H" "$FPS"
fi
[ -n "$FIT" ] || { echo "ERROR: ${W}x${H}@${FPS} + $AUDIO does not fit $LETTERS letters even at crf 63" >&2; exit 3; }

read -r TOTAL HDRB VIDEO AUDIOB NFRAMES MODE <<< "$(python3 "$PACK" stats "$OUT")"
NEED=$(( (TOTAL + PART_PAYLOAD - 1) / PART_PAYLOAD )); [ "$TOTAL" -le 4096 ] && NEED=1
echo "video letter v2 ${W}x${H}@${FPS} crf $FIT preset $PRESET grain $GRAIN audio $MODE, ${SECS}s: $TOTAL B (video $VIDEO, audio $AUDIOB, $NFRAMES frames) -> $NEED letter(s) of $LETTERS"
