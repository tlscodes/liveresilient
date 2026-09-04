#!/usr/bin/env bash
# journey_fixtures.sh — the REAL media fixtures of one app-journey run, made
# on the Mac once per run: a spoken voice note (`say`, then ffmpeg to IMA
# ADPCM WAV), a real PHOTOGRAPH, and a ONE-MINUTE video with real picture and
# real speech. The app-journey driver sends these over the live call; the
# phone returns the bytes it received through the hub, and journey_run.sh
# checks fixture == returned blob == the sha256 the app printed, then decodes
# the returned files with Mac tools so a person can look at and listen to
# exactly what crossed.
#
# Sources, in order:
#   JOURNEY_PHOTO_SRC / JOURNEY_VIDEO_SRC   files the operator supplies (any
#       image sips can read; any video ffmpeg can read, cut to JOURNEY_VIDEO_S)
#   otherwise a photograph from macOS's own desktop pictures (a random one of
#       the landscape scenes), and a video made from ANOTHER of them: a slow
#       pan and zoom over the picture for JOURNEY_VIDEO_S seconds with the
#       Mac's speech engine counting the seconds aloud — real picture, real
#       speech, and the count lets a listener check the sound against the clock.
# The FaceTime camera is not used: an unattended run cannot answer the
# camera permission prompt (measured: "Input/output error" from ffmpeg's
# avfoundation input on 2026-09-04).
#
# SIZES FOLLOW THE LINK, the way a real app's encoder would: the runner passes
# JOURNEY_VIDEO_BYTES (a cap the encode is sized to fit) and JOURNEY_PHOTO_PX
# (the photo's long edge). The encode picks its resolution, frame rate and
# bit rates from the cap: total kbit/s = cap x 8 / seconds x 0.85, one fifth
# of it (at most 24 kbit/s) for speech. A fixture that outgrows its cap fails
# the run here, before any shaping or hub start.
#
# USAGE  journey_fixtures.sh <run-dir> <run-id> <profile>
#   JOURNEY_VOICE_BYTES=24000  JOURNEY_VIDEO_BYTES=1600000  JOURNEY_PHOTO_PX=1280
#   JOURNEY_VIDEO_S=60  JOURNEY_SAY_RATE=190  JOURNEY_PHOTO_SRC=  JOURNEY_VIDEO_SRC=
#   The run id is the runner's 2026-09-04T13:04:05Z; only its hour and minute
#   are spoken (`say` reads the raw ISO string character by character).
# Files written: voice.wav, photo_src.jpg (the raw photograph the driver
# picks; the driver writes photo.jpg, the wire original, next to it),
# video.mp4.
set -uo pipefail

RUN=${1:?run dir}
RUN_ID=${2:?run id}
PROFILE=${3:?profile}
VOICE_CAP=${JOURNEY_VOICE_BYTES:-24000}
VIDEO_CAP=${JOURNEY_VIDEO_BYTES:-1600000}
PHOTO_PX=${JOURNEY_PHOTO_PX:-1280}
VIDEO_S=${JOURNEY_VIDEO_S:-60}
PHOTO_SRC=${JOURNEY_PHOTO_SRC:-}
VIDEO_SRC=${JOURNEY_VIDEO_SRC:-}
F="$RUN/fixtures"

fail() { echo "fixtures: $*" >&2; exit 1; }
for tool in say ffmpeg ffprobe afinfo sips; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing tool $tool"
done
mkdir -p "$F" || fail "cannot create $F"

# --- the spoken sentence ---
hh=$(printf '%s' "$RUN_ID" | sed -nE 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}):([0-9]{2}).*$/\1/p')
mm=$(printf '%s' "$RUN_ID" | sed -nE 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}):([0-9]{2}).*$/\2/p')
[ -n "$hh" ] && [ -n "$mm" ] || fail "run id $RUN_ID has no HH:MM"
hour=$((10#$hh)); minute=$((10#$mm))
if [ "$minute" -eq 0 ]; then spoken_min="hundred"
elif [ "$minute" -lt 10 ]; then spoken_min="oh $minute"
else spoken_min="$minute"; fi
# "loss10" is read as one word; a space before the digits makes it "loss ten".
spoken_profile=$(printf '%s' "$PROFILE" | sed -E 's/([a-z])([0-9])/\1 \2/g')
sentence="Journey profile $spoken_profile at $hour $spoken_min UTC. This voice note crossed the live call."

# --- voice.wav: 8 kHz mono PCM from `say`, then IMA ADPCM (4 bits per sample) ---
# IMA ADPCM at 8 kHz is ~4,030 B/s, so the 24,000 B cap allows ~5.9 s. At the
# default rate this sentence measured 6.12 s (24,670 B, over the cap) on
# 2026-09-04; at 190 words per minute it measured 5.10 s (20,574 B) for the
# longest profile names, still a natural pace.
SAY_RATE=${JOURNEY_SAY_RATE:-190}
render_voice() {  # <rate> → voice.wav; prints its byte count
  say -r "$1" -o "$F/voice_pcm.wav" --file-format=WAVE --data-format=LEI16@8000 "$sentence" \
    || fail "say could not render the voice note"
  ffmpeg -v error -y -i "$F/voice_pcm.wav" -c:a adpcm_ima_wav "$F/voice.wav" \
    || fail "ffmpeg could not encode voice.wav"
  rm -f "$F/voice_pcm.wav"
  [ -s "$F/voice.wav" ] || fail "voice.wav missing or empty"
  stat -f %z "$F/voice.wav"
}
voice_bytes=$(render_voice "$SAY_RATE")
if [ "$voice_bytes" -gt "$VOICE_CAP" ]; then
  # Measured 2026-09-04: in a batch of four runs `say` once rendered the
  # sentence at its default pace despite -r (28,766 B); a second render at a
  # faster rate stayed under the cap. One retry, reported, then the cap rules.
  echo "fixtures: voice.wav was $voice_bytes B at rate $SAY_RATE; rendering again at $((SAY_RATE + 40))" >&2
  voice_bytes=$(render_voice "$((SAY_RATE + 40))")
fi
voice_dur=$(afinfo "$F/voice.wav" 2>/dev/null | sed -nE 's/.*estimated duration: ([0-9.]+) sec.*/\1/p' | head -1)
[ -n "$voice_dur" ] || fail "afinfo gave no duration for voice.wav"
[ "$voice_bytes" -le "$VOICE_CAP" ] || fail "voice.wav is $voice_bytes B, over the cap $VOICE_CAP B"
dur_ok=$(python3 -c "print(1 if 3.0 <= float('$voice_dur') <= 8.0 else 0)" 2>/dev/null || echo 0)
[ "$dur_ok" = 1 ] || fail "voice.wav lasts $voice_dur s, outside 3.0..8.0 s"

# --- the photographs: two different real scenes, one for the photo, one for the video ---
# macOS ships these as HEIC; sips converts and scales them. The choice is
# random per run so the evidence of the matrix is not the same picture seven
# times; the file name is printed so a reader knows which scene it was.
scenes=()
for s in "/System/Library/Desktop Pictures/Sonoma.heic" \
         "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic" \
         "/System/Library/Desktop Pictures/.wallpapers/Sequoia Sunrise/Sequoia Sunrise.heic"; do
  [ -f "$s" ] && scenes+=("$s")
done
pick_scene() {  # <exclude> → a path from $scenes, not equal to <exclude> when possible
  local exclude=$1 n=${#scenes[@]} i cand
  [ "$n" -gt 0 ] || fail "no photograph source: set JOURNEY_PHOTO_SRC (no macOS desktop scene found)"
  i=$((RANDOM % n)); cand=${scenes[$i]}
  if [ "$n" -gt 1 ] && [ "$cand" = "$exclude" ]; then cand=${scenes[$(((i + 1) % n))]}; fi
  printf '%s' "$cand"
}
if [ -n "$PHOTO_SRC" ]; then
  [ -f "$PHOTO_SRC" ] || fail "JOURNEY_PHOTO_SRC not found: $PHOTO_SRC"
  photo_scene=$PHOTO_SRC
else
  photo_scene=$(pick_scene "")
fi
sips -s format jpeg -s formatOptions 85 -Z "$PHOTO_PX" "$photo_scene" --out "$F/photo_src.jpg" >/dev/null 2>&1 \
  || fail "sips could not convert the photograph $photo_scene"
[ -s "$F/photo_src.jpg" ] || fail "photo_src.jpg missing or empty"
photo_bytes=$(stat -f %z "$F/photo_src.jpg")
photo_w=$(sips -g pixelWidth "$F/photo_src.jpg" 2>/dev/null | awk '/pixelWidth/{print $2}')
photo_h=$(sips -g pixelHeight "$F/photo_src.jpg" 2>/dev/null | awk '/pixelHeight/{print $2}')

# --- video.mp4: JOURNEY_VIDEO_S seconds sized to the cap ---
# The encode model: total = cap x 8 / seconds x 0.85 kbit/s; speech gets a
# fifth (at most 24); the picture gets the rest at a resolution and frame
# rate the rate can carry. Measured 2026-09-04 on this Mac: 320x240 12 fps at
# 150+24 kbit/s → 1,336,106 B for 60 s (4 s to encode).
read -r vid_w vid_h vid_fps vid_kbps aud_kbps <<<"$(python3 - "$VIDEO_CAP" "$VIDEO_S" <<'PY'
import sys
cap, secs = int(sys.argv[1]), float(sys.argv[2])
total = cap * 8 / secs / 1000 * 0.85
audio = max(4, min(24, total / 5))
video = max(4, total - audio)
if total >= 100:   w, h, fps = 320, 240, 12
elif total >= 24:  w, h, fps = 240, 180, 8
else:              w, h, fps = 160, 120, 8
print(w, h, fps, int(video), int(audio))
PY
)"
if [ -n "$VIDEO_SRC" ]; then
  [ -f "$VIDEO_SRC" ] || fail "JOURNEY_VIDEO_SRC not found: $VIDEO_SRC"
  video_scene=$VIDEO_SRC
  ffmpeg -v error -y -i "$VIDEO_SRC" -t "$VIDEO_S" \
    -vf "scale=${vid_w}:${vid_h}:force_original_aspect_ratio=decrease,pad=${vid_w}:${vid_h}:(ow-iw)/2:(oh-ih)/2,fps=${vid_fps},format=yuv420p" \
    -c:v libx264 -preset veryfast -b:v "${vid_kbps}k" -maxrate "$((vid_kbps * 3 / 2))k" -bufsize "$((vid_kbps * 2))k" \
    -c:a aac -ac 1 -ar 16000 -b:a "${aud_kbps}k" -movflags +faststart "$F/video.mp4" \
    || fail "ffmpeg could not transcode $VIDEO_SRC"
else
  video_scene=$(pick_scene "$photo_scene")
  sips -s format jpeg -s formatOptions 90 -Z 1280 "$video_scene" --out "$F/video_src.jpg" >/dev/null 2>&1 \
    || fail "sips could not convert the video scene $video_scene"
  # The count: "one [[slnc 250]] two ..." lands at ~61 s for 60 numbers.
  count=$(seq 1 "${VIDEO_S%.*}" | sed 's/$/ [[slnc 250]]/' | tr '\n' ' ')
  say -o "$F/count.wav" --file-format=WAVE --data-format=LEI16@16000 "$count" \
    || fail "say could not render the count"
  ffmpeg -v error -y -loop 1 -framerate "$vid_fps" -i "$F/video_src.jpg" -i "$F/count.wav" -t "$VIDEO_S" \
    -filter_complex "[0:v]scale=1280:-2,zoompan=z='1.0+0.0035*on':x='iw/2-(iw/zoom/2)+on*0.4':y='ih/2-(ih/zoom/2)':d=1:s=${vid_w}x${vid_h}:fps=${vid_fps},format=yuv420p[v]" \
    -map "[v]" -map 1:a -c:v libx264 -preset veryfast -b:v "${vid_kbps}k" -maxrate "$((vid_kbps * 3 / 2))k" -bufsize "$((vid_kbps * 2))k" \
    -c:a aac -ac 1 -ar 16000 -b:a "${aud_kbps}k" -shortest -movflags +faststart "$F/video.mp4" \
    || fail "ffmpeg could not encode video.mp4"
fi
[ -s "$F/video.mp4" ] || fail "video.mp4 missing or empty"
video_bytes=$(stat -f %z "$F/video.mp4")
# x264 overshoots a very low target (measured 2026-09-04: v13k+a4k at
# 160x120 gave 169,647 B for a 150,000 B cap). Re-encode with the video rate
# scaled by the miss, twice at most; the kept file is the one under the cap.
for _ in 1 2; do
  [ "$video_bytes" -gt "$VIDEO_CAP" ] || break
  vid_kbps=$(python3 -c "import sys; v,c,a=map(float,sys.argv[1:4]); print(max(4, int(v * c * 0.9 / a)))" "$vid_kbps" "$VIDEO_CAP" "$video_bytes")
  echo "fixtures: video.mp4 was $video_bytes B over the cap $VIDEO_CAP B; re-encoding at v${vid_kbps}k" >&2
  if [ -n "$VIDEO_SRC" ]; then
    ffmpeg -v error -y -i "$VIDEO_SRC" -t "$VIDEO_S" \
      -vf "scale=${vid_w}:${vid_h}:force_original_aspect_ratio=decrease,pad=${vid_w}:${vid_h}:(ow-iw)/2:(oh-ih)/2,fps=${vid_fps},format=yuv420p" \
      -c:v libx264 -preset veryfast -b:v "${vid_kbps}k" -maxrate "$((vid_kbps * 3 / 2))k" -bufsize "$((vid_kbps * 2))k" \
      -c:a aac -ac 1 -ar 16000 -b:a "${aud_kbps}k" -movflags +faststart "$F/video.mp4" \
      || fail "ffmpeg could not re-encode $VIDEO_SRC"
  else
    ffmpeg -v error -y -loop 1 -framerate "$vid_fps" -i "$F/video_src.jpg" -i "$F/count.wav" -t "$VIDEO_S" \
      -filter_complex "[0:v]scale=1280:-2,zoompan=z='1.0+0.0035*on':x='iw/2-(iw/zoom/2)+on*0.4':y='ih/2-(ih/zoom/2)':d=1:s=${vid_w}x${vid_h}:fps=${vid_fps},format=yuv420p[v]" \
      -map "[v]" -map 1:a -c:v libx264 -preset veryfast -b:v "${vid_kbps}k" -maxrate "$((vid_kbps * 3 / 2))k" -bufsize "$((vid_kbps * 2))k" \
      -c:a aac -ac 1 -ar 16000 -b:a "${aud_kbps}k" -shortest -movflags +faststart "$F/video.mp4" \
      || fail "ffmpeg could not re-encode video.mp4"
  fi
  video_bytes=$(stat -f %z "$F/video.mp4")
done
rm -f "$F/video_src.jpg" "$F/count.wav"
# ffprobe's csv line carries a trailing comma on this clip ("720,"); keep the digits.
video_frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$F/video.mp4" 2>/dev/null | head -1 | tr -cd '0-9')
video_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F/video.mp4" 2>/dev/null | head -1 | tr -cd '0-9.')
[ "$video_bytes" -le "$VIDEO_CAP" ] || fail "video.mp4 is $video_bytes B, over the cap $VIDEO_CAP B (encode ${vid_w}x${vid_h}@${vid_fps} v${vid_kbps}k a${aud_kbps}k)"
[ "${video_frames:-0}" -ge 24 ] 2>/dev/null || fail "video.mp4 has ${video_frames:-?} frames, fewer than 24"
dur_ok=$(python3 -c "import sys; print(1 if float(sys.argv[1] or 0) >= float(sys.argv[2]) * 0.9 else 0)" "$video_dur" "$VIDEO_S" 2>/dev/null || echo 0)
[ "$dur_ok" = 1 ] || fail "video.mp4 lasts ${video_dur:-?} s, shorter than 90% of $VIDEO_S s"

echo "fixture voice.wav $voice_bytes B $voice_dur s"
echo "fixture photo_src.jpg $photo_bytes B ${photo_w}x${photo_h} from $(basename "$photo_scene")"
echo "fixture video.mp4 $video_bytes B $video_frames frames $video_dur s ${vid_w}x${vid_h}@${vid_fps} v${vid_kbps}k a${aud_kbps}k from $(basename "$video_scene")"
