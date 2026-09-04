#!/usr/bin/env bash
# journey_fixtures.sh — the REAL media fixtures of one app-journey run, made
# on the Mac once per run: a spoken voice note (`say`, then ffmpeg to IMA
# ADPCM WAV) and a short H.264 video note (ffmpeg test pattern plus a 440 Hz
# tone). The app-journey driver sends these files over the live call; the
# phone returns the bytes it received through the hub, and journey_run.sh
# checks fixture == returned blob == the sha256 the app printed, then decodes
# both with Mac tools. Nothing here is synthetic noise: the voice note is a
# sentence naming the profile and the run's time, the video is a moving test
# pattern with sound.
#
# The byte figures are CAPS, not sizes (the row's wire_B column is what the
# app printed): a fixture that outgrows its cap fails the run here, before
# any shaping or hub start. Measured on this Mac (2026-09-04): voice.wav
# 21,598 B for 5.36 s; video.mp4 73,780 B, 48 frames. This ffmpeg build has
# no drawtext filter, so the video carries no burned-in text.
#
# USAGE  journey_fixtures.sh <run-dir> <run-id> <profile>
#        JOURNEY_VOICE_BYTES=24000 JOURNEY_VIDEO_BYTES=96000 override the caps.
#        The run id is the runner's 2026-09-04T13:04:05Z; only its hour and
#        minute are spoken (`say` reads the raw ISO string character by
#        character).
set -uo pipefail

RUN=${1:?run dir}
RUN_ID=${2:?run id}
PROFILE=${3:?profile}
VOICE_CAP=${JOURNEY_VOICE_BYTES:-24000}
VIDEO_CAP=${JOURNEY_VIDEO_BYTES:-96000}
F="$RUN/fixtures"

fail() { echo "fixtures: $*" >&2; exit 1; }
for tool in say ffmpeg ffprobe afinfo; do
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
say -r "$SAY_RATE" -o "$F/voice_pcm.wav" --file-format=WAVE --data-format=LEI16@8000 "$sentence" \
  || fail "say could not render the voice note"
ffmpeg -v error -y -i "$F/voice_pcm.wav" -c:a adpcm_ima_wav "$F/voice.wav" \
  || fail "ffmpeg could not encode voice.wav"
rm -f "$F/voice_pcm.wav"
[ -s "$F/voice.wav" ] || fail "voice.wav missing or empty"
voice_bytes=$(stat -f %z "$F/voice.wav")
voice_dur=$(afinfo "$F/voice.wav" 2>/dev/null | sed -nE 's/.*estimated duration: ([0-9.]+) sec.*/\1/p' | head -1)
[ -n "$voice_dur" ] || fail "afinfo gave no duration for voice.wav"
[ "$voice_bytes" -le "$VOICE_CAP" ] || fail "voice.wav is $voice_bytes B, over the cap $VOICE_CAP B"
dur_ok=$(python3 -c "print(1 if 3.0 <= float('$voice_dur') <= 8.0 else 0)" 2>/dev/null || echo 0)
[ "$dur_ok" = 1 ] || fail "voice.wav lasts $voice_dur s, outside 3.0..8.0 s"

# --- video.mp4: 4 s of a moving test pattern at 320x240, 12 fps, with a tone ---
ffmpeg -v error -y -f lavfi -i "testsrc2=size=320x240:rate=12" \
  -f lavfi -i "sine=frequency=440:sample_rate=16000" -t 4 \
  -c:v libx264 -preset veryfast -b:v 120k -pix_fmt yuv420p \
  -c:a aac -b:a 16k -movflags +faststart "$F/video.mp4" \
  || fail "ffmpeg could not encode video.mp4"
[ -s "$F/video.mp4" ] || fail "video.mp4 missing or empty"
video_bytes=$(stat -f %z "$F/video.mp4")
video_frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$F/video.mp4" 2>/dev/null | head -1)
[ "$video_bytes" -le "$VIDEO_CAP" ] || fail "video.mp4 is $video_bytes B, over the cap $VIDEO_CAP B"
[ "${video_frames:-0}" -ge 24 ] 2>/dev/null || fail "video.mp4 has ${video_frames:-?} frames, fewer than 24"

echo "fixture voice.wav $voice_bytes B $voice_dur s"
echo "fixture video.mp4 $video_bytes B $video_frames frames"
