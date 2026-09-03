# Brief — connect the reference app to a real session

Paste the block below into a terminal session running on Fable 5.1, from the
repository root. It is written to be self-contained: every claim in it was
verified in the codebase on 2026-09-03, and every anchor is a real file and
line.

---

```
Work in /Users/behnam/Downloads/voice_call_kit_v3 on branch plan-v4-waves-1-to-6.

GOAL
The reference app's call screen must place a real call and chart the path's
measured statistics. Today it does neither: the screen is driven by a demo
controller with no network, and the quality gauge shows a scripted profile.

WHAT IS ALREADY DONE — do not rebuild it
The measurement path is complete and tested up to the last hop:
  packages/media_webrtc/lib/src/rtc_stats_sampler.dart   RtcStatsSampler, real
    WebRTC counters -> RtcStatsSample (loss, rttMs, jitter, in/out bitrate)
  apps/reference_app/lib/src/media_adaptation_driver.dart:55  exposes
    `Stream<RtcStatsSample> get samples`
  apps/reference_app/lib/src/live_quality_feed.dart  readingFromSample(),
    projection tested in apps/reference_app/test/live_quality_feed_test.dart
  apps/reference_app/lib/src/call_session.dart  CallSessionHandle carries
    `qualityReadings`, already wired from adaptationDriver.samples
  apps/reference_app/lib/src/ui/source_chip.dart  SourceChip, shown beside the
    gauge; its text says whether readings are live or synthetic

THE EXACT GAP
  apps/reference_app/lib/main.dart:164  `Stream<CallQualityReading>? _liveQuality`
    is declared, read at :168 and :171, and NEVER ASSIGNED.
  apps/reference_app/lib/main.dart:520  devConnectToLocalRelay() returns a
    CallSessionHandle with real readings — and `git grep` shows nothing outside
    main.dart's own definitions ever calls it. The UI never opens a session.
  apps/reference_app/lib/src/call_demo_controller.dart:14  CallDemoController is
    UI state only: placeCall() changes a phase enum, no network.

There is a comment at main.dart:450 recording the same class of mistake made
before — a banner claimed imported settings were in use while the manifest was
held in state and never passed to a connect call. Read it before you start; the
lesson it records is the one to avoid repeating.

WHAT TO BUILD
1. The call screen places a real call. Replace or wrap CallDemoController so
   onCall opens a session through devConnectWithStartupManifest (main.dart:634,
   which resolves the startup manifest first), holds the CallSessionHandle in
   state, and drives the screen's phase from handle.controller rather than from
   a local enum.
2. Assign _liveQuality from handle.qualityReadings when the session exists, and
   null it on teardown. The existing getters at :168 and :171 then do the rest —
   the gauge charts measured readings and the chip reads "live path stats".
3. Lifecycle, and this is the part that will actually be hard: hang up, call
   failure, reconnect, and app backgrounding must each dispose the handle
   exactly once and leave no stream subscription behind. handle.dispose exists.
4. The demo feed stays as the fallback for when no session is open, with its
   existing label. Do not delete it and do not silence the chip.

CONSTRAINTS — these are project rules, not preferences
- Every claim of "done" needs a passing verifier in the same turn. No exceptions.
- No number may reach a document or a screen without a source; a figure with no
  live source needs a visible label rather than a comment.
- Back up each file to .backups/NNN-<path>.bak before editing it.
- The pre-commit hook is enabled (git config core.hooksPath .githooks) and will
  format and analyse exactly what you stage. Do not bypass it with --no-verify.
- Do not weaken or delete a test to make something pass.

HOW TO TEST IT FOR REAL, in the terminal
Two terminals. The relay first — ON PORT 4443, because that is the port the
app's dev entry point dials (main.dart, devConnectToLocalRelay) while the
server's own default is 8443; run without --port and the app never connects:

  dart run server/signaling_server/bin/signaling_server.dart --port 4443

Then the app against it. The datagram relay is separate if the run needs it:

  dart run server/signaling_server/bin/datagram_relay.dart

Then place a call between two instances: on the first, tap Call and read the
"Call key" the screen shows; on the second, tap "Join with key" and enter it
(the second instance joins as the receiver). Confirm on screen that the chip
reads "live path stats" and that the numbers move with the network rather than
on a timer. Prove the difference: shape the link or pull the network mid-call
and watch the gauge follow. A scripted feed recovers on schedule no matter what
you do to the link — that is the test that tells the two apart, and it is the
one that matters.

The same journey, terminal-driven and self-contained (the relay is bound
in-process on 4443, the second peer is a headless real stack that joins the
key read off the screen; every number is printed as evidence):

  cd apps/reference_app && flutter test integration_test/app_live_call_test.dart -d macos

VERIFY BEFORE YOU CALL IT DONE
  cd apps/reference_app && dart analyze lib
  cd apps/reference_app && flutter test           (311 passing today)
  dart format --output=none --set-exit-if-changed .   (640 files, 0 changed)
  cd tools/trace_gate && dart test                (10 passing)

Add at least one widget test proving the gauge shows the live label when a
session supplies readings, and the synthetic label when none does. That test is
the point of the change: without it, the next person cannot tell whether the
gauge is honest, which is exactly the state this work is fixing.

IF YOU GET STUCK
Two failed attempts on the same thing means stop and say the approach is wrong
rather than trying a third. Report what you could not do and why, in plain
terms, with the verbatim error. An honest "this part is not done" is worth more
here than a green screen nobody can trust.
```

---

## Why this is worth doing carefully

The gauge is what a person looks at on a bad link to decide whether to keep
talking. Until this lands it shows a script that recovers on schedule whatever
the network does, and the only thing standing between that and a confident lie
is the small grey chip added yesterday. Removing the chip without doing this
work would be the worst possible outcome.
