# Fable 5 session prompt — test · modernize · wire · UI pass

Copy the block below into Fable 5 (Claude Code) at the repo root
`$REPO`. It is phased and gated: each phase must end
green (`dart format .` clean, `dart analyze --fatal-infos --fatal-warnings` = 0,
`dart test` per touched package passing) before the next phase starts. No new features —
this is hardening, wiring, and a visual pass only.

```text
Work at the repo root of a Dart/Flutter monorepo (native pub workspace). Follow the phases
in order. After EACH phase run, from the repo root:
  dart format .
  dart analyze --fatal-infos --fatal-warnings
  dart test        (and `flutter test` inside apps/reference_app)
A phase is done only when all three are clean/green. If a check fails, fix it before moving
on. Do not add new product features; this is stabilization, wiring, and UI polish. Commit
after each green phase with a clear message. Never weaken a test to make it pass; never
delete test coverage.

PHASE 1 — Full green baseline.
Run the three checks across every package. Record any failure and fix the root cause. Goal:
the whole workspace formats, analyzes with zero issues (infos fatal), and every package's
tests pass.

PHASE 2 — Modernize (behaviour-preserving only).
Apply modern Dart idioms where they improve clarity WITHOUT changing behaviour: prefer
sealed classes + exhaustive switch, records for small tuples, pattern matching, collection-
if/for, super parameters, const where possible, and `dart fix --apply`. Do not rename public
APIs. Re-run the checks; behaviour must be identical (tests unchanged and still green).

PHASE 3 — Wire the packages end to end.
Verify the packages actually connect: call_core ↔ signaling (via call_signaling_adapter),
media_webrtc(+_flutter), adaptive_transport, signed_config, security(+_keychain),
privacy_telemetry, and messaging. Add a small integration test in apps/reference_app (or
integration_test/) that drives a call-setup path end to end against fakes/loopback (no real
device), proving the wiring holds. Add missing barrel exports so each package's public API is
reachable from its top-level import.

PHASE 4 — Global visual / UX pass on apps/reference_app.
Make the reference app clean and consistent: a single theme (light + dark) via ThemeData /
ColorScheme.fromSeed, consistent spacing scale, one call-screen layout with clear states
(Idle, Connecting, Reconnecting, In-call, Ended), a chat screen showing text + attachment
bubbles (photo/video/file), an audio-only-degrade indicator, and a plain privacy-status line.
Every interactive control must have a semantics label (accessibility). Use standard Material
3 widgets; keep it responsive with relative sizing. Widget-test the key screens (states
render, no overflow).

PHASE 5 — Final gate + report.
Run the three checks once more across everything. Write docs/STATUS.md summarizing: per-
package test counts, what was modernized, what was wired, screens added, and any item that
still needs a real device or deployment (list it as a dated blocker, do not claim it done).
```

Notes for the session:
- Keep prose plain and technical; describe operations by what they do.
- If any package lacks a `test/` dir it should gain minimal coverage in Phase 1 or 3.
- Attachments already exist in `packages/messaging` (chunker + reassembler) — Phase 4 only
  needs to render them, not re-implement.
