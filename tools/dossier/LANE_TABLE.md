# Which lane carries what, and which lane the measurements used

## Provenance

```
regenerated   2026-09-07
from commit   84198af   (git -C . rev-parse --short HEAD)
on branch     plan-v4-waves-1-to-6
supersedes    the 2026-09-02 version, written against commit 88d3c41
```

The previous version of this file was stale, and stale in the project's own
favour, which is the worst direction. It told a reviewer to run a grep and said
that grep "returns nothing"; the grep now returns a line. It listed photo and
video note as having no production caller; both have had one since 2026-09-04
(`dbd357f`, "feat(journey): chat, photo, voice and video notes ride the live
call"). It also pointed at three anchors that no longer resolve:
`call_session.dart:543` (the code is now at 640), `chat_demo_controller.dart:34`
(a blank line), and `NLNET_SUBMISSION_READY.md` at the repository root (the file
is at `tools/dossier/NLNET_SUBMISSION_READY.md`).

Every row and every self-check below was re-run on 2026-09-07 against `84198af`.
The outputs pasted under each command are that run's real output, not a
description of it.

## The table

Two different things get measured in this project and they must not be confused:
the **transport and codecs** over the rig's own datagram lane, and the
**application's own path** through its own screens. The table says, per feature,
which production lane carries it today and where each was measured.

```
feature       wired into the app today          production lane        measured
------------  --------------------------------  ---------------------  -----------------------
chat text     YES  main.dart:305,319             WebRTC data channel    harness: e2e_ios_results.tsv
                   call_session.dart:640-641     vck-chat, id 2         app:     app_journey_results.tsv

photo         YES  main.dart:310,320             WebRTC data channel    harness: e2e_ios_results.tsv
                   call_session.dart:642-645     vck-photo, id 9        app:     app_journey_results.tsv

video note    YES  main.dart:311,321             WebRTC data channel    harness: e2e_ios_results.tsv
                   call_session.dart:646-649     vck-video, id 1        app:     app_journey_results.tsv

voice note    YES  main.dart:554                      rides the chat    harness: e2e_ios_results.tsv
                   chat_demo_controller.dart:707,635  lane as a         app:     app_journey_results.tsv
                   chat_demo_controller.dart:52,128   chunked           (see the caveat below)
                                                      attachment

news page     NO   no caller in the app          none                   harness only
                   codec: packages/broadcast_media/lib/src/compact_news_codec.dart

push-to-talk  NO   no caller in the app          none                   harness only
                   engine: packages/adaptive_transport/lib/src/ptt_engine.dart:32,99

call media    YES  the WebRTC media path         DTLS-SRTP              app: call_connect rows
```

Four of the six features are wired; two are not. The 2026-09-02 version said
three of six were not wired, and `README.md:38` still repeats that number.

Lane identities are declared in one table,
`packages/messaging_webrtc_adapter/lib/src/call_lanes.dart:16-52`: `messaging`
(the default config, line 19), `chat` (`vck-chat`, negotiated id 2, ordered,
lines 24-27), `photo` (`vck-photo`, id 9, unordered, lines 31-35) and `video`
(`vck-video`, id 1, unordered, lines 39-43).

### On the wire

```
lane                        encrypted?
--------------------------  ----------------------------------------------
the four data channels      yes — DTLS/SCTP
the WebRTC media path       yes — DTLS-SRTP
the rig's datagram lane     no  — plain UDP, by design
```

The rig's lane says so itself, at
`apps/reference_app/integration_test/support/datagram_lane_port.dart:13-22`:
"Deliberately NO reliability logic here"; the room key is derived from the callId
because that "keeps the app free of a crypto dependency".

Two caveats on the encrypted column, both already in `SECURITY.md`. Nothing
verifies the DTLS fingerprint out of band (`SECURITY.md:37-41`), so DTLS protects
against an observer on the network and not against the server that relays the
session description. And the datagram lane's own encryption is milestone one of
the funding application — it does not exist yet in any form.

## Self-checks

Run these from the repository root. Each is followed by its real output on
`84198af`.

**1. The photo lane has a production caller.** This is the check the previous
version got backwards.

```
$ grep -rn "photoLanePort:" apps/reference_app/lib
apps/reference_app/lib/main.dart:320:          photoLanePort: photoPort,
```

**2. All three lane-opening ports are declared, implemented and called.**

```
$ grep -rn "openChatPort\|openPhotoLanePort\|openVideoLanePort" apps/reference_app/lib
apps/reference_app/lib/main.dart:305:    final openChat = handle?.openChatPort;
apps/reference_app/lib/main.dart:310:        final photoPort = await handle.openPhotoLanePort?.call();
apps/reference_app/lib/main.dart:311:        final videoPort = await handle.openVideoLanePort?.call();
apps/reference_app/lib/src/chat_demo_controller.dart:10:/// - Call mode (`callChannelPort` from `CallSessionHandle.openChatPort`):
apps/reference_app/lib/src/call_session.dart:48:    this.openChatPort,
apps/reference_app/lib/src/call_session.dart:49:    this.openPhotoLanePort,
apps/reference_app/lib/src/call_session.dart:50:    this.openVideoLanePort,
apps/reference_app/lib/src/call_session.dart:92:  final Future<DataChannelPort> Function()? openChatPort;
apps/reference_app/lib/src/call_session.dart:98:  final Future<DataChannelPort> Function()? openPhotoLanePort;
apps/reference_app/lib/src/call_session.dart:99:  final Future<DataChannelPort> Function()? openVideoLanePort;
apps/reference_app/lib/src/call_session.dart:640:    openChatPort: () async =>
apps/reference_app/lib/src/call_session.dart:642:    openPhotoLanePort: () async => MediaChannelDataPort(
apps/reference_app/lib/src/call_session.dart:646:    openVideoLanePort: () async => MediaChannelDataPort(
```

Lines 305-321 of `main.dart` are the whole binding: `_syncLiveChat` awaits the
three ports and hands them to the live thread as `callChannelPort` (319),
`photoLanePort` (320) and `videoLanePort` (321). The thread is opened from the
conversations list at `main.dart:515-516`, under the title "Call peer".

**3. The news page has no caller in the app.** Empty output, exit 1.

```
$ grep -rniE "newsLanePort|newsPage|NewsLane" apps/reference_app/lib ; echo "exit=$?"
exit=1
```

The codec is real and tested at package level
(`packages/broadcast_media/lib/src/compact_news_codec.dart`, exercised by
`packages/broadcast_media/test/compact_news_codec_test.dart`); nothing in the
application calls it:

```
$ grep -rn "encodeNewsPage\|decodeNewsPage" apps/reference_app/lib ; echo "exit=$?"
exit=1
```

**4. Push-to-talk has no caller in the app.** Empty output, exit 1.

```
$ grep -rniE "pushToTalk|pttPort|pttLane" apps/reference_app/lib ; echo "exit=$?"
exit=1
```

The bundling engine exists as wire logic only — its own header says so at
`packages/adaptive_transport/lib/src/ptt_engine.dart:3` — and has no application
caller:

```
$ grep -rn "PttBundler\|PttUnbundler" apps/reference_app/lib ; echo "exit=$?"
exit=1
```

**5. `TokenVoiceLane` is not the voice-note path, and is not constructed in
production.** The 2026-09-02 version listed `token_voice_lane` as the voice
note's production path. It is a different thing — the degraded-mode token voice
lane — and it is built only by tests.

```
$ grep -rn "TokenVoiceLane(" apps/reference_app/lib apps/reference_app/test
apps/reference_app/lib/src/token_voice_lane.dart:20:  TokenVoiceLane({
apps/reference_app/test/token_voice_lane_test.dart:48:    final near = TokenVoiceLane(
apps/reference_app/test/token_voice_lane_test.dart:57:    final far = TokenVoiceLane(
apps/reference_app/test/token_voice_lane_test.dart:109:      final lane = TokenVoiceLane(
```

The voice note's real path is the chat lane: `main.dart:554` wires the recorder
control to `ChatDemoController.sendVoiceNote`
(`chat_demo_controller.dart:707`), which sends through the generic attachment
chunker (`chat_demo_controller.dart:635`) on the messenger bound to the chat port
(`chat_demo_controller.dart:52,128`).

**6. Two chat threads exist, and only one is bound to the call.** `main.dart:199`
builds a loopback demo controller with no call port; `main.dart:318` builds the
live one from the call's lanes. The conversations list opens the live thread for
`summary.id == 'live'` and the loopback thread for `'loopback'`
(`main.dart:513-528`). A reviewer looking at the app should check the title bar:
"Call peer" is the live thread, "Loopback peer" is the demo.

## What the harness measured

The six device rows in `tools/dossier/e2e_ios_results.tsv` were all measured over
`DatagramLanePort`, the test-support class above — raw UDP, no encryption of its
own, phone → Mac relay → phone.

```
$ grep -n "_lanePair(" apps/reference_app/integration_test/e2e_matrix_test.dart
47:Future<(DatagramLanePort, DatagramLanePort)> _lanePair(String call) async {
175:      final (tx, rx) = await _lanePair('t3-barrier');
218:      final (tx, rx) = await _lanePair('t3-chat');
263:      final (tx, rx) = await _lanePair('t3-news');
305:      final (tx, rx) = await _lanePair('t3-voice');
355:      final (tx, rx) = await _lanePair('t3-photo');
406:      final (tx, rx) = await _lanePair('t3-video');
459:      final (tx, rx) = await _lanePair('t3-ptt');
```

Those numbers are not wrong. They measure what they were built to measure:
whether these payload sizes survive a shaped link on a transport with no
loss-reactive control loop underneath. That is the project's central claim and
the rows support it. What they do not measure is the application's own path — and
since 2026-09-04 there is a separate file that does.

## What the application measured

`tools/dossier/app_journey_results.tsv` drives the reference app through its own
screens. Header and one full row, verbatim:

```
feature	profile	wire_B	budget_s	measured_s	status	note

photo	normal	234241	106	36.5	PASS	sender_ms=36501 peer_ms=36501 sha_match=true
media=realAudio real photograph from the runner (JOURNEY PHOTO FILE),
decoded=ok(1280x720) run=2026-09-04T21:26:27Z bw=- delay=40 plr=0.0
icmp_rtt=81.002 icmp_loss=0.0% scope=udp+icmp on bridge100, relay TCP unshaped
```

(That row is line 419 of the file; the `note` column is one field on one line
there — it is wrapped here only to fit the page.)

**Which features it contains, and how many rows.** 426 data rows plus the header.
Six application features, 70 rows each, plus six rows of a later store-and-forward
gate:

```
$ awk -F'\t' 'NR>1 {print $1}' tools/dossier/app_journey_results.tsv | sort | uniq -c | sort -rn
  70 voice_note
  70 video_note
  70 photo
  70 monitor_bar
  70 chat_text
  70 call_connect
   4 blackout_gate
   2 blackout_message
```

Note which six those are. They are **not** the same six as the harness file:
`call_connect` and `monitor_bar` are here, and `news` and `ptt` are absent —
consistent with the table above, because there is nothing in the app to drive for
those two.

**The file accumulates runs; it is not a single run.** 75 distinct `run=` stamps
between 2026-09-03 and 2026-09-06:

```
$ grep -oE 'run=[0-9T:Z-]+' tools/dossier/app_journey_results.tsv | sort -u | wc -l
      75

$ grep -oE 'run=[0-9T:Z-]+' tools/dossier/app_journey_results.tsv | sed 's/run=//' | cut -dT -f1 | sort | uniq -c
  74 2026-09-03
 266 2026-09-04
   3 2026-09-05
   1 2026-09-06
```

That second count is rows, not runs: 344 of the 426 rows carry a `run=` stamp.

**80 rows in it say NOT_WIRED, and every one of them predates the wiring.** They
are lines 4-121, they carry no `run=` stamp, and their note is the 2 September
state — "chat tab is the loopback demo thread (ChatDemoController), not bound to
the live call". They are kept as history; they are not the current verdict.

```
$ awk -F'\t' 'NR>1 && $6=="NOT_WIRED" {print $1}' tools/dossier/app_journey_results.tsv | sort | uniq -c
  20 chat_text
  20 photo
  20 video_note
  20 voice_note
```

**The current sweep is 42 rows: seven impairment profiles by six features.** These
are the most recent run of each profile that recorded all six features, all on
2026-09-04:

```
$ grep -cE 'run=2026-09-04T(16:25:44|16:31:35|18:13:54|20:19:23|21:01:41|21:17:40|21:26:27)Z' tools/dossier/app_journey_results.tsv
42

$ grep -E 'run=2026-09-04T(16:25:44|16:31:35|18:13:54|20:19:23|21:01:41|21:17:40|21:26:27)Z' tools/dossier/app_journey_results.tsv | cut -f2 | sort | uniq -c
   6 bandwidth
   6 extreme
   6 latency
   6 loss10
   6 loss60
   6 narrow
   6 normal

$ grep -E 'run=2026-09-04T(16:25:44|16:31:35|18:13:54|20:19:23|21:01:41|21:17:40|21:26:27)Z' tools/dossier/app_journey_results.tsv | cut -f1,6 | sort | uniq -c
   7 call_connect	PASS
   7 chat_text	PASS
   4 monitor_bar	INFO
   3 monitor_bar	PASS
   7 photo	PASS
   7 video_note	PASS
   7 voice_note	PASS
```

38 PASS, 4 INFO, no FAIL and no NOT_WIRED in that set. `INFO` is the monitor-bar
row on profiles where it carries no budget to be judged against — it records what
the bar showed (`monitor_bar bandwidth ... chip_live=87 chip_demo=0 rtt=62..1806ms
loss_max=36.4% reconnects=1`, line 411), it is not a pass being reported as
something else.

Most of the other 302 run-stamped rows are earlier attempts of the same
profiles, including failures fixed along the way — but not all of them are
earlier, and saying so plainly matters more than a tidy sentence. Six rows carry
the `blackout` profile and are LATER than the sweep's last run of 21:26:27Z:
`2026-09-04T23:33:26Z`, `23:36:50Z`, `2026-09-05T07:15:44Z`, `07:29:41Z`,
`09:49:01Z` and `2026-09-06T02:51:53Z`. Two of them are FAIL, and one of those is
the newest row in the whole file: `gate_fail=window 1 util_carried=82.5% < gate
90%`. That gate has not been met. Nothing here should be read as "everything red
is historical". Counting the whole file as one result would overstate it in both
directions; the selection rule above is stated so it can be checked.

## What is still not proven

- **The voice note's audio content is not production content.** In the measured
  rows the recorder source is injected by the rig — "recorded 6s with the composer
  mic control ... spoken by the Mac speech engine (`say`), IMA ADPCM WAV" (line
  420). The application ships with no recorder dependency, and
  `chat_demo_controller.dart:700-706` says so at the definition: without a source
  the bytes are "a demo placeholder sized to the recording length". The transfer
  is real; the audio is not yet captured from a microphone in production.
- **The results file records no handset.** It records the shaping scope
  (`scope=udp+icmp on bridge100`) and `app_relay=localhost(unshaped)`, and nothing
  that identifies the device. Read the app rows as app-level, not as a device
  claim; the device claim belongs to `e2e_ios_results.tsv`.
- **The journey logs behind these rows are not in the repository.**
  `.gitignore:28` excludes `*.log`, so `tools/dossier/logs/journey/*.log` are not
  committed and a reviewer cloning this repository cannot open them. The two TSVs
  are committed and are the checkable evidence.
- **Nothing here measures encryption.** See the caveats above and `SECURITY.md`.

## What follows for the beta

The instruction "ship calls and text only, disable the bulk lane" still means:
ship the WebRTC paths, ship nothing that rides `DatagramLanePort`. That lane is
test-support code under `integration_test/` and is not in the application binary
in the first place.

The 2026-09-02 version said a beta could not advertise the measured numbers
because the app's chat went over a different lane than the one that produced the
2.5 s chat figure in `e2e_ios_results.tsv`. That instruction has been carried out:
the application's own path now has its own numbers, in
`app_journey_results.tsv`. Quote the app file for what the application's own path
does and the harness file for what the transport and codecs do, and never one for
the other.

Neither file answers what a user experiences, and this table must not be read as
if it does. "Wired into the app today" means the lane is opened and carried by
the app's own call path — it does not mean a user can reach it. The only
signalling endpoint in the application is `wss://localhost:4443`
(`main.dart:784`, `startup_manifest.dart:166`), reached through
`devConnectToLocalRelay` (`main.dart:751`), and `main.dart:4-5` says so in the
file's own header: the real device and network wiring "is kept available but
only from the clearly-marked dev entry point at the bottom of this file". So
these rows describe a path the project can drive end to end, against a relay it
runs itself. Measuring the path a user would take is exactly what milestone M4's
supervised pilot exists to do, and until that happens no figure in either file
may be quoted to anyone outside the project as what a user will experience.

## What this table changes elsewhere

```
README.md:38                            FIXED 2026-09-07 — said "three of the six
                                        have no production wiring yet"; it is two,
                                        news page and push-to-talk, and the four
                                        others are named as dev-entry-point only
tools/BRIEF_matrix_app_journey.md:26    FIXED 2026-09-07 — same stale figure. The
                                        figure is on :26; an earlier draft of this
                                        list said ":25,61", and neither of those
                                        lines carries it
tools/dossier/PROBLEM_STATEMENT.md:91   cites this file for the transport/app
                                        distinction — still correct
tools/dossier/APPLICATION_NLNET.md:41   cites this file for "which are wired
                                        today"; the count it points at has changed
tools/dossier/APPLICATION_DDP.md:123    cites this file for "over the test
                                        harness lane" — still correct
tools/dossier/NLNET_SUBMISSION_READY.md moved here from the repository root
PLAN_HARDENING.md                       week 4's pilot must measure the app's path
                                        — done for seven profiles on 2026-09-04,
                                        on the project's own path, not a user's
```

Those are not corrected by this file. Each one is its own edit, and until it is
made, this file and that line disagree — with this file being the one that was
re-derived from the code today.
