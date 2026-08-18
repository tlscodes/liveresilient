# STATUS — a dated journal, newest entry first

> **How to read this file (added 2026-07-31, resolving documented contradictions 1, 2 and 6).**
> This is an append-only journal. **Every heading below is a snapshot of the day it
> names, not a statement about today.** The current state of the project lives in
> `docs/PROJECT_STATE_2026-07-29.md`; the current phase status lives in
> `docs/EXECUTION_PLAYBOOK.md`. Where they disagree with anything below, they win.
>
> Three specific corrections, because the stale text is kept rather than deleted:
>
> - **"DESTINATION REACHED" meant the 2026-07-22 roadmap (phases 1, 2a, 2b), not the
>   product.** Phases 9 and 11 of `docs/EXECUTION_PLAYBOOK.md` are a different,
>   longer numbering and are both **OPEN**, dated, and device/infra-blocked. The
>   playbook is authoritative on phase status because its entries carry dates and
>   named blockers; this file's headline did not.
> - **Test totals are per-date snapshots and do not sum:** 946 (2026-07-22) →
>   1632 → **2087 (2026-07-29, `tools/workspace_gate.sh`, EXIT=0)**. The 946 figure
>   predates three packages that did not exist yet. 2087 is the current number.
> - **Sealed `CallState` is DONE** (2026-07-22 entry). The "deferred by design" line
>   in the 2026-07-19 entry below was true when written and is now superseded —
>   kept, per archive-don't-delete, but it is not current.

---

# STATUS — roadmap phases 1/2a/2b closed (2026-07-22)

Every roadmap phase (1, 2a, 2b) is closed. Measured workspace gate that day:

```
apps/reference_app        56   packages/media_webrtc          82
integration_test           4   packages/media_webrtc_flutter  11
adaptive_transport       114   packages/messaging             34
call_core                127   messaging_webrtc_adapter       10
call_media_adapter        10   privacy_telemetry              23
call_signaling_adapter    61   security                       75
device_link               84   security_keychain              11
live_captions             16   signaling                      95
                               signed_config                 133
TOTAL_GREEN=946   FAIL=0   (17 test directories)
```

`dart format .` exit 0 · `flutter analyze --fatal-infos --fatal-warnings` clean.
Growth over the build: 673 → 946 green tests (+41%).

Landed on the final leg: the live-call media-adaptation driver (`31a53c4`); the
end-to-end session soak proving the path-health monitor and the adaptation driver
coexist on one clock across 30 impaired episodes (`4af0501`); and a workspace-wide gate
that replaced the per-package glob — the exact gap that had once hidden a red soak test.

**Honesty boundary.** Every number above comes from fake-time and pure-logic suites.
Real-device call quality, real network behaviour, and cloud-deploy figures are NOT
claimed here and remain unmeasured — that is the honest next frontier, not a closed gate.

---

# STATUS — roadmap PHASE 1 + PHASE 2a (2026-07-20)

Dream-roadmap progress (docs/DREAM_ROADMAP_PROMPTS.md):

- **PHASE 1 — path continuity on the live call: DONE, committed.**
  `CallController.requestRecovery()` seam (call_core, +3 tests);
  `path_health_monitor.dart` in reference_app — the live WebRTC path scored as an
  adaptive_transport `TransportChannel` (stats-delta probe → EWMA + circuit breaker via
  `PathSelector`), edge-triggered escalation into the existing reconnect/ICE-restart
  loop, active only while the call phase is `connected`; wired into the call-session
  composition root. Adapter test proves a reconnect cycle keeps envelopes flowing.
- **PHASE 2a — impaired-network soak: DONE.** `call_core/test/recovery_soak_test.dart`
  (200 failure/recovery cycles under fake time: no deadlock, bounded emissions, zero
  leaked timers, attempt counters reset every cycle) +
  `reference_app/test/path_health_soak_test.dart` (50 loss/jitter/dead-path episodes:
  exactly one escalation per dead stretch, none within tolerance). The app soak caught
  and fixed a real bug: a tripped breaker ignored probe successes while open, so after
  a reconnect the monitor now rebuilds its selector (fresh path ⇒ fresh scoring) —
  otherwise it re-escalated in a recovery storm for up to the breaker's backoff window.
- **PHASE 2b — sealed-CallState: DONE (same day, on explicit user instruction over the
  2026-07-19 deferral).** `CallState` is now a sealed hierarchy (Idle/Connecting/
  Negotiating/Connected/Reconnecting/Ending + sealed `TerminalCallState` →
  Ended/Failed). Impossible combinations are unrepresentable by construction: reconnect
  attempt/deadline exist only on `ReconnectingCallState` (attempt ≥ 1 enforced),
  `endReason` is non-nullable and exists only on terminal subtypes, and the factory now
  also rejects non-zero attempts outside reconnecting (previously silently stored).
  The unnamed factory keeps the old phase+fields calling convention and all original
  ArgumentError contracts, and base getters preserve the read surface — the whole
  123-test suite passed with ZERO test edits, then 4 new sealed-hierarchy tests pin
  exhaustive switching. All downstream consumers verified green unchanged.

**PHASE 2 CLOSED.** Suites after this pass: call_core 127, call_signaling_adapter 61,
call_media_adapter 10, reference_app 53 — all green; analyze
`--fatal-infos --fatal-warnings` clean on all touched packages.

---

# STATUS — live captions + architecture pass (2026-07-19, second pass)

Workspace gate after this pass: **943 tests green across 18 test directories**
(`tools/run_gate_loop.sh`), root + app analyze `--fatal-infos --fatal-warnings` clean.
Commits: `2ad2b66`, `077029e`, `0cbfcdb`, `a696354`.

## New capability: live translated captions (conference / live-stream use case)

- **`packages/live_captions` (new, pure Dart, 16 tests)** — engine-agnostic seams
  (`Translator`, transcript-segment stream) so real STT/MT engines plug in later;
  `CaptionPipeline` (in-order emission under out-of-order translator latency, bounded
  drop-oldest queue, per-language failure fallback that never drops a caption);
  `CaptionLog` (partial→final replacement, never downgrades committed text); hardened
  JSON `CaptionFrame` wire + `CaptionReceiver` riding the SAME ReliableMessenger as
  chat/attachments (E2E proven beside interleaved chat text).
- **reference_app integration** — caption frames route off the chat channel into the
  caption strip (never chat bubbles, never echoed); loopback demo seeds two
  English→Persian lines through the real pipeline; `ChatScreen` renders a last-two-lines
  strip in the viewer language.

## Architecture follow-ups from the 2026-07-18 core audit

- **`packages/call_media_adapter` (new, 10 tests)** — call_core `CallMediaSession` over
  media_webrtc `PeerConnectionPort` (the media twin of call_signaling_adapter). The
  app's hand-written translation file is gone; the one platform-specific op (native
  rollback) is an injected seam, so the package stays pure Dart.
- **reference_app `main.dart` split** — controllers moved to
  `src/call_demo_controller.dart` / `src/chat_demo_controller.dart`; `main.dart` is
  composition only (451 → ~130 lines).
- **CI glob gap** — verified already closed (commit `e58fcc9`; ci.yml line 64 covers
  `packages/ apps/ server/ integration_test/ tool/`).

## Dated blockers / deferrals (not claimed done)

- **2026-07-19 — sealed-CallState + call_controller decomposition DEFERRED** (1449-line
  file, 11 mutable flags, breaks every importer). Needs a dedicated solo session with
  the full 119-test call_core suite as the harness; do not start it as a session tail.
- **2026-07-19 — real STT/MT engines** for live_captions are host-app adapters by
  design (platform audio capture + a speech/translation service or on-device model);
  the in-repo pipeline is fully tested with injected fakes. YouTube/conference audio
  capture is platform work, same device-bound family as the SCTP blocker below.

---

# STATUS — chat/UX completion pass (2026-07-19)

Four gated tasks on the reference app's chat layer, each landed green and committed
separately (`acfaa1a`, `fd1657d`, `d3febae`, `5d3fe0c`). Full workspace gate after:
**922 tests green across 16 test directories** (was 913; signaling_server additionally
carries 1 pre-existing skip), `dart analyze --fatal-infos --fatal-warnings` clean in the
root workspace, `apps/reference_app`, `media_webrtc_flutter`, and `security_keychain`;
format clean.

## The four features

1. **Periodic retry driver (proven)** — the app's 500 ms `Timer.periodic` drives
   `ReliableMessenger.tick()` during chat; a `fakeAsync` test drops the first
   transmission and proves retransmission after the 2 s retry window. Enabling change:
   the messenger's default clock is now `package:clock`'s zone-scoped `clock`
   (identical outside test zones).
2. **Delivery status markers** — outbound text bubbles show pending → delivered →
   failed from the messenger's `deliveries` stream (sendText now also adds the
   outbound bubble; previously only the echo showed). Widget-tested with an ack gate
   that releases the ack mid-test.
3. **Attachment transfer progress** — `startAttachmentSend()` in `packages/messaging`
   returns an `AttachmentSendHandle` streaming `bytesSent/totalBytes` per chunk;
   `sendAttachment` delegates to it, so existing callers are untouched. Attachment
   bubbles render a determinate `LinearProgressIndicator` while < 100%.
4. **Attachment picker button** — chat screen attach button wired to an injectable
   `Future<Attachment?> Function()` seam on `ChatDemoController`; the app injects
   `file_selector`'s `openFile()`, widget tests inject fakes (no real dialog). A picked
   file becomes a bubble and transfers over the live data channel with the progress bar.

## Dated blockers (not claimed done)

- **2026-07-19** — the platform SCTP data-channel pipe still needs a real phone: all
  chat/attachment E2E here rides in-process ports (loopback + TLS relay). Real-device
  run remains scheduled with the 2026-07-18 device blockers below.
- **2026-07-19** — `pickAttachmentFile()` (real `file_selector` dialog) is exercised
  only through its injectable seam in tests; the native dialog itself needs a manual
  device/desktop run.

---

# STATUS — next-generation hardening pass (2026-07-18)

Three gated waves (scout → parallel surgeons → repo gate → commit), all landed green.
Baseline at session start: 687 tests. **Now: 855 tests, 0 analyzer findings
(`--fatal-infos --fatal-warnings`), format clean.** Rollback tags:
`pre-nextgen-wave{1,2,3}-2026-07-18`. Commits: `0cce3fb` (wave 1), `7cd96a4` (wave 2),
wave 3 in this commit.

## Per-package test counts (all green)

| package | before | after |
|---|---|---|
| adaptive_transport | 103 | 114 |
| call_core | 97 | 119 |
| call_signaling_adapter | 52 | 60 |
| device_link | 82 | 84 |
| media_webrtc | 70 | 75 |
| media_webrtc_flutter | 5 | 7 |
| messaging | 9 | 31 |
| privacy_telemetry | 21 | 23 |
| security | 63 | 75 |
| security_keychain | 8 | 11 |
| signaling | 66 | 95 |
| signed_config | 107 | 123 |
| apps/reference_app | 4 | 38 |
| **total** | **687** | **855** |

## Real bugs found and fixed (each with a regression test)

1. **signaling** — reconnect budget never reset on manual `connect()` after exhaustion:
   a user "retry" got zero retries and a stale `reconnecting` state.
2. **adaptive_transport** — `PathSelector.online` consumed circuit-breaker half-open
   probe slots on every read; polling a health indicator could permanently strand a
   recovering path. Reads are now side-effect free.
3. **media_webrtc** — `stop()`/`start()` race in `RtcStatsSampler`: an in-flight poll
   resurrected stale counters after stop, corrupting the first post-restart sample
   (fixed with an epoch guard).
4. **media_webrtc** — bandwidth estimate coerced `null→0`, so a measured zero-headroom
   reading was misread as "no estimate" and could trigger an unwarranted quality upgrade
   (now `int?` end-to-end; measured 0 blocks upgrade).
5. **media_webrtc_flutter** — camera/mic stream leaked when `create()` failed mid-`addTrack`.
6. **device_link** — programming `Error`s were swallowed into `SendStatus.transient`,
   masking bugs as retryable network failures.

## Hostile-input / memory bounds added

- messaging: capped dedup cache (4096), frame size gate before JSON parse (256 KiB),
  reassembler caps (4096 chunks, 16 pending, per-chunk byte cap), conflicting-chunk
  rejection, per-instance id tag (kills cross-reconnect dedup collision).
- signed_config: count caps on all manifest lists; opaque-URI-aware host validation for
  stun/turn entries; `malformedSignature` split from genuine crypto failure.
- security: TURN `issue()` rejects empty/colon userId; ttl/secret validation;
  key-cache `forget()`; DevFileKeyStore mutation serialization (lost-update race).
- signaling: eager validation on both reliability configs (incl. liveness > heartbeat).

## Modernized (behaviour-preserving)

Dart 3 `final class`/`sealed` sweep across packages (GuardedLinkOutcome is now a true
sealed hierarchy, source-compatible); `abstract final class XorFec`; const wire frames;
structural equality on HostPort/CallState; explicit LinkedHashMap where eviction relies
on order; single lazily-initialized secure RNG; enum-declaration-order pinning tests;
call_core dartdoc backfill 0 → ~490 doc lines.

## Wired / UI (reference_app)

`main.dart` is no longer the counter template: Material 3 app, one seeded theme
(light+dark), NavigationBar with Call/Chat tabs. Call screen renders all five states
(Idle / Connecting / Reconnecting+attempt / In-call / Ended+reason) plus an audio-only
chip and a plain privacy-status line; every control has a Semantics label; no overflow
at 320x568 and 800x1280 (tested). Chat tab runs a REAL `ReliableMessenger` pair over an
in-memory loopback port and renders text + image + file bubbles through the genuine
chunk/reassembly path. `webrtc_media_session` and `ws_connector` now have direct unit
tests (idempotency, status mapping, resolver actually used, echo round-trip).

## Dated blockers (not claimed done)

- **2026-07-18** — `FlutterWebRtcPeerConnectionPort.create()` leak fix verified by
  analyze+review only; a real-device platform-channel test is pending (no seam to fake
  `getUserMedia` without a public-API change).
- **2026-07-18** — real-device / real-network call run (TURN, push wake) still requires
  physical devices and deployed infra; all current numbers are simulator/pure-logic.
- ~~Deferred by design: sealed-`CallState` redesign (breaks every importer — needs a
  major-version decision, not a hardening pass).~~ **SUPERSEDED 2026-07-22** — the
  redesign landed the same week (see the 2026-07-22 entry, PHASE 2b). Struck, not
  deleted.
