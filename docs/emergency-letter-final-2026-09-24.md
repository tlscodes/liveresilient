# Emergency letter — the final settings and the closed matrix (2026-09-24)

The emergency letter carries text, a photo, a voice take or a video through
the DNS TXT door when the live call is out. This page records the settings
the owner accepted, the eight-row acceptance matrix that proves them on the
rig (iPhone 11 Pro Max ↔ Intel iMac), and where each part lives. It follows
`emergency-letter-record-2026-09-20.md`.

## The laws that did not move

- One letter is at most **4096 B** (29 B parts header, 4067 B payload).
- A longer item rides as **parts**: three in flight, each index retried on
  its own; the responder reassembles (`letter_parts.dart`, `tools/t2/letter_parts.py`).
- No new public domain or port. The datagram lane is untouched.

## The frozen settings

| kind | codec | cap | letters | where |
|---|---|---|---|---|
| text | UTF-8 | 4096 B per letter, parts beyond | as needed | `letter_composer.dart` |
| photo | **AVIF** (one AV1 keyframe, phone's SVT-AV1), JPEG fallback | edge ladder 2048 → 48 | ≤ 30 (121500 B) | `photo_letter_picker.dart`, `avif_writer.dart` |
| voice | **Opus** mode 7 (hybrid, 48 kHz) ≥ 15 kbit/s, else mode 6 (SILK WB VBR, 16 kHz); NoLACE on playback | **50 s**, longer is refused | ≤ 20 (81340 B) | `voice_letter_recorder.dart`, `opus_ffi.dart` |
| video | **AV1** 288×512 @ 4 fps (motion band) + 648×1152 page frames when the camera holds still (two-band); Opus WB tail 12 kbit/s (8 with a page) | **39 s**, chosen from the library, trimmed by a slider | ≤ 100 (406700 B) | `av1_encoder.dart`, `two_band_video.dart`, `video_letter_picker.dart` |

`letterMaxParts` is 100 (Dart and Python). The photo keeps its own
thirty-letter cap so a picture never becomes a long carry.

## What the person sees

- A **percentage bar** in the letter banner climbs from 1 to 100 while the
  letter goes through the door.
- **Video** opens the photo library; a clip longer than 39 s shows a slider
  and "Use this part".
- A Send window that closes empty **sends nothing** (never a default letter).
- A new window starts clean; an iCloud-only photo says so in plain words.

## Measured quality (the numbers behind the choices)

| change | before | after | how |
|---|---|---|---|
| photo JPEG → AVIF (real phone photo 591×1280) | ssim 0.9727 at 113532 B | 0.9826 at 113926 B | ffmpeg ssim vs source |
| photo on the rig | 591×1280 JPEG | **2048×1536 AVIF**, 112034 B, 28 letters | row a6760900 |
| voice | Codec2 3200 "noisy" | Opus WB + NoLACE "excellent" (owner) | rows 83314d80, 2ced5233 |
| video geometry (real 39 s clip) | 216×384@6, 60 letters: VMAF 15.6 | **288×512@4, 100 letters: VMAF 30.3** | phone's own builder on the Mac, libvmaf at 864×1536 |
| video page band (held moment) | ssim 0.8417 | 0.9547 | two_band_demo + open_video_letter.sh |

The review of every Fable consult on video (ultracode, 2026-09-23) found the
picture is limited by bytes per second, not by the codec; encoder presets and
receiver filters each move less than one crf step.

## The closed matrix (LETTER_ONLY, both directions)

| kind | Mac → phone (decoded on the phone) | phone → Mac |
|---|---|---|
| text | cfedf0cc — 7241 B Persian, shown in full | WDDRJE — typed, Done + Send |
| photo | d8e5b9c6 — 76632 B, 1024×768 decoded in 9 ms | a6760900 — AVIF 2048×1536, 112034 B |
| voice | ba6251fe — mode 7, 67783 B, 48 kHz on the phone | 2ced5233 — 50 s, 70776 B, 18 letters |
| video | 4c5e6ff8 — 288×512@4, 387341 B, 156 frames in 248 ms | 62123358 — 38.8 s, 406254 B, 100 letters, crf 33 |

Every row is in `tools/dossier/app_journey_results.tsv`; `tools/dossier/manifest.tsv`
verifies (`tail -n +2 tools/dossier/manifest.tsv | awk -F'\t' '{print $3"  "$1}' | shasum -a 256 -c`).

## Tools

- `tools/t2/journey_run.sh dnsvalve` with `JOURNEY_VALVE_LETTER_ONLY=1`,
  `JOURNEY_VALVE_CHAT_SOURCE=mac|phone`, `JOURNEY_VALVE_PHONE_WAIT_S=120`,
  `JOURNEY_VALVE_CARRY_BUDGET_S=600` for video.
- `tools/t2/open_video_letter.sh` — opens any video letter (mixed frame
  sizes, NoLACE audio) as an mp4.
- `packages/broadcast_media/tool/build_video_letter.dart`, `two_band_demo.dart`
  — the phone's builder on the Mac, for measuring.
- `tools/t2/hf_gap.sh` — does a "wideband" tail carry the 4–8 kHz band.

## Traps found the hard way

- Never uninstall the rig peer: it wipes the microphone grant.
- An iCloud-only photo cannot be read in airplane mode; pick one stored on the phone.
- Apple's `iconv` fails writing to `/dev/null` above ~1 KB; the runner decodes text with python.
- A rejected run stops the Mac side at once while the phone keeps its window open — let a run finish.
- A crf wall set from a steady talking head refuses real hand-held clips; the wall is 40.

## Open

- Not pushed (the owner decides when).
- The phone has a basic player (commit 0cda839): "Play the letter" plays a decoded voice or video letter — sound through AVAudioEngine with NoLACE, frames from dav1d in step. The owner played it on the phone (2026-09-25). No scrubbing or pause yet.
