# Handoff — PLAN_five_tickets_v4, waves 1–7

Written 2026-08-16 at the end of the session that built waves 1–6, ran the
work on a physical device, and applied a per-class review pass.

Start a new session by reading this file, then `docs/PLAN_five_tickets_v4.md`
(the build ledger lives inside it, one dated row per wave with its verifier
output).

---

## 1. Where the work is

```
branch   plan-v4-waves-1-to-6      (cut from main; main is untouched)
commit   3704dd6                   "plan v4: waves 1-6, every gate green with its verifier"
tag      wave-6-safe
```

The commit holds 42 files, +9067/-106. Everything after it is uncommitted in
the working tree — see §4.

IMPORTANT: the repository was ALREADY dirty before this session began
(`ci.yml`, `README.md`, `ios/Podfile`, several `intelligence/` files, and
more). None of that was committed. It is still in the working tree exactly as
it was. Do not sweep it into a commit without checking with the owner.

---

## 2. Verified state

Every number below came from a command in the same turn it was written.

```
signed_config       205 tests    analyze clean
adaptive_transport  485 tests    analyze clean
reference_app       287 tests    analyze clean
media_webrtc        116 tests    analyze clean
call_core           169 tests    analyze clean
                   ───────────
                   1262 tests green
```

On the physical iPhone (`00008030-001215003AF2802E`, iOS 26.0):

```
flutter build ios --debug              Xcode build done, 59.7s
flutter install -d <id>                installed
xcrun devicectl device info apps       Voice Call Kit  com.tlscodes.referenceApp  1.0.0
xcrun devicectl device process launch  Launched
integration_test/loopback_call_test.dart -d <id>   All tests passed (01:20)
```

That loopback run produced real evidence, not just a pass mark: 8 `typ host`
candidates over 4 interfaces, both peers reaching `connected`, an ICE restart
producing 4 fresh candidates, a clean hangup, and relay rooms draining to 0.

---

## 3. What is NOT proven — read before claiming anything

- **Gate 3f on the device: CLOSED GREEN 2026-08-16 — see §8.** The four
  invalid runs above were diagnosed and fixed: the harness's
  `create(audio: true)` blocked inside `getUserMedia` on the microphone
  permission dialog of a freshly installed build (both tests hung their
  full 2-minute timeouts with nobody at the screen). The harness was
  rewritten capture-free (receive-only transceiver, completion at
  gathering-complete) and produced a valid green with a non-vacuous
  baseline. Ledger row «موج ۷ · دروازه‌ی 3f روی دستگاه» in the plan.
  The PACKET-CAPTURE half of 3f is still open — that dated blocker stays.
- **Ticket 4** is out of the wave sequence entirely, blocked on a native
  binding that has not been chosen. See the plan's blocked-work register.
- **Packet capture** for 3f was never taken.
- The 40-byte and 66-byte carrier figures are models, not captures. A review
  finding says the 40-byte figure under-counts SRTP auth tags, negotiated RTP
  header extensions, and IPv6 — unresolved, recorded, not silently changed.

---

## 4. Uncommitted work in the tree (this session, after commit 3704dd6)

Applied from the per-class Fable 5 review, all verified green:

```
packages/media_webrtc/lib/src/sdp/opus_sdp_transform.dart
    OpusSilenceHandling enum replaces the dtx/constantBitrate boolean pair,
    so the impossible combination is unwritable and the guard moved from a
    runtime throw to the compiler. Numeric validation moved to
    applyOpusPolicy so the type could stay const.
packages/media_webrtc/lib/src/opus_wire_budget.dart
    minimumBandwidthBps is nullable and null under the responsiveness cause.
packages/media_webrtc/test/opus_cbr_dtx_test.dart
packages/media_webrtc/test/opus_wire_budget_test.dart
packages/media_webrtc/test/sdp/opus_sdp_transform_test.dart
packages/call_core/lib/src/connection_budget.dart
    SchedulerStepAdmissible's assert became a real check.
packages/signed_config/lib/src/lookup_cache.dart
    In-flight marker installed before the body runs (sync-throw poisoning).
packages/signed_config/lib/src/https_name_lookup.dart
    Aggregate deadline over the whole lookup.
packages/signed_config/test/lookup_cache_test.dart
packages/signed_config/test/https_name_lookup_test.dart
packages/adaptive_transport/lib/src/probe_defense/relay_key_rotation.dart
    rotate() refuses a second rotation inside the overlap window.
packages/adaptive_transport/test/probe_defense/relay_key_rotation_test.dart
apps/reference_app/lib/main.dart
    const default restored after the enum change.
apps/reference_app/integration_test/host_candidate_device_test.dart   NEW
docs/PLAN_five_tickets_v4.md                                          ledger rows
```

---

## 5. Files this session created

New production code:

```
packages/signed_config/lib/src/https_name_lookup.dart
packages/signed_config/lib/src/lookup_cache.dart
apps/reference_app/lib/src/startup_manifest.dart          (gate + policy added)
```

New tests:

```
packages/signed_config/test/manifest_time_floor_test.dart
packages/signed_config/test/manifest_byte_cap_test.dart
packages/signed_config/test/strict_relay_unsatisfiable_test.dart
packages/signed_config/test/host_candidate_exposure_test.dart
packages/signed_config/test/https_name_lookup_test.dart
packages/signed_config/test/lookup_cache_test.dart
packages/media_webrtc/test/opus_cbr_dtx_test.dart
packages/call_core/test/scheduler_step_bound_test.dart
packages/adaptive_transport/test/fixed_tick_emitter_test.dart
packages/adaptive_transport/test/length_histogram_buckets_test.dart
packages/adaptive_transport/test/key_epoch_overlap_test.dart
apps/reference_app/test/ice_failure_ledger_test.dart
apps/reference_app/test/startup_gate_test.dart
apps/reference_app/test/resolver_wiring_architecture_test.dart
apps/reference_app/integration_test/host_candidate_device_test.dart
```

New tooling and documents:

```
tools/plan_sweep.py            sweeps the repo against the plan: anchor
                               validity, named-symbol presence, dead symbols,
                               and IDF-ranked files the plan never mentions
docs/PLAN_five_tickets_v4.md   the plan and its build ledger
.autorun/run.json              the run's steps with their verify commands
~/.claude/knowledge/successes/pairwise-decomposition-for-blocked-adjudication.md
```

---

## 6. How this session worked, and what to keep doing

- Every code change was adjudicated by Fable 5 BEFORE it was written, and the
  ledger records which rows Fable wrote versus which the conductor typed from
  Fable's design after a dispatch was stopped. Keep that distinction; it is
  the difference between a claim and a record.
- Roughly a third of Fable dispatches in this domain are stopped by the
  review pass. The technique that works is decomposition: ask the question
  the big question breaks into, with only that question's own inputs. See the
  knowledge-tree file above for the honesty test that keeps this from
  becoming euphemism.
- A subagent has its own consult record, so a gate that opens on a completed
  consult will still block it. The right response is the one the agent took:
  stop, report the block and the design, let the parent type it.
- Read command OUTPUT, not just exit codes. `flutter install` printed
  "Install failed" and exited 0.

---

## 7. The immediate next action

Get gate 3f to a valid green on the device, or record why it cannot be.

1. Re-run the known-good scenario first to separate device state from the
   test file:
   `flutter test integration_test/loopback_call_test.dart -d 00008030-001215003AF2802E`
2. If that also fails to start, the device or toolchain is wedged — a device
   restart is the owner's call, not something to keep retrying.
3. If it passes, the difference is in `host_candidate_device_test.dart`.
   The most likely remaining cause is the microphone permission prompt on a
   freshly installed build: `gather()` calls `getUserMedia` with audio, and
   the app was uninstalled during debugging, so the grant is gone.
4. Only when the baseline test (`policy 'all'` produces host candidates)
   passes does the relay-only result mean anything. Do not report the second
   test alone.

Then commit the §4 work and tag it.

---

## 8. DONE — 2026-08-16 (the session after this handoff was written)

Every step of §7 was executed, in order, with its verifier:

```
1  loopback re-run          00:36 +1: All tests passed!    exit 0
2  (not needed — device fine)
3  hypothesis CONFIRMED     3f run: both tests hung 2:00 in getUserMedia,
                            zero evidence lines — the permission dialog
                            with nobody at the screen. Loopback proved
                            nothing about the microphone: it takes no
                            local audio source (its line 126 says so).
4  harness rewritten        capture-free: recvonly audio transceiver +
                            buildPeerConnectionConfig verbatim + completion
                            at RTCIceGatheringStateComplete (8s backstop) +
                            callbacks detached before close
   valid green              policy all   -> 16 host candidates, 4 addrs,
                                            gatheringComplete=true
                            policy relay -> 0 candidates AT gathering-
                                            complete (strong absence form)
                            00:04 +2: All tests passed!    exit 0
5  committed + tagged       fd21ede  (14 files: §4 list + harness + ledger)
                            tag wave-7-3f-device-green
                            pre-existing dirty tree untouched (215 entries)
```

Design provenance: conductor (Fable 5) designed the harness; the consult
gate was opened by a completed synchronous Fable 5 review dispatch
(verdict sound-with-corrections; all three corrections applied before the
run); `fable-purity.py` audited the dispatch PURE. Full record in the
ledger row «موج ۷ · دروازه‌ی 3f روی دستگاه» in `docs/PLAN_five_tickets_v4.md`.

Still open after this session: the 3f PACKET-CAPTURE blocker (needs the
rig, dated 2026-08-13) and ticket 4 (native binding not chosen). The
uncommitted pre-existing changes (ci.yml, README, Podfile, intelligence/,
and more — 215 entries) remain exactly as found; sweeping them needs the
owner's explicit word.
