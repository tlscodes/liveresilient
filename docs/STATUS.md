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

Dart 3 `final class`/`sealed` sweep across packages (GuardedMeshOutcome is now a true
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
- Deferred by design: sealed-`CallState` redesign (breaks every importer — needs a
  major-version decision, not a hardening pass).
