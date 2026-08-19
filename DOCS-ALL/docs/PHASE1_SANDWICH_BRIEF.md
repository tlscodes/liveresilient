# Phase 1 — Sandwich Brief (Buildable Foundation + CI)

Operating recipe for the first growth wave. Fable writes the per-task brief, Sonnet
surgeons + testers execute in parallel on disjoint targets, CI is the mechanical
gate, Fable does the active finish. CI (`.github/workflows/ci.yml`) already exists —
it is the gate every task below flows through.

## Goal
Turn the scaffold into a workspace that compiles and passes a green CI gate. No new
features. This closes the 7 Release Blockers that make the repo un-buildable.

## Parallel targets (disjoint — one surgeon + one tester each)
| # | Surgeon target | Tester target |
|---|----------------|---------------|
| A | `call_core`: pick one canonical `CallState` + `ReconnectPolicy`; remove the duplicate defs from `call_controller.dart`; fix barrel exports | unit test: importing `package:call_core/call_core.dart` compiles; state-machine transitions |
| B | Add real, pinned deps after license/security check (WebRTC adapter, WSS/HTTP client, crypto lib, secure storage, test+fake_clock+mocking) | `flutter pub get` resolves; no version conflicts |
| C | `rtc_stats_sampler.dart` single-flight guard; `_negotiating` timeout + `try/finally`; circuit-breaker half-open probe | property tests: no concurrent `_tick`; negotiation always releases; open-state success does not skip the cooldown |
| D | `architecture_guard.dart`: resolve workspace root independent of CWD; fix redaction regex order (IPv4 before phone) | test: guard finds root from any CWD; redactor labels IPv4 vs phone correctly |

## Hidden contradictions to catch (the part a cheap model misses)
- `pubspec.lock` is git-ignored but CI must be reproducible → pin SDK + dep versions in `pubspec.yaml`, not via lock.
- Native pub `workspace:` vs melos: use ONE resolver. CI uses `flutter pub get` at root (native workspace) — do not also require `melos bootstrap`.
- "Add tests" with zero real deps → tests of crypto interfaces need the concrete impls (Phase 4). In Phase 1 test only pure logic (state machine, outbox, policy), not crypto/WebRTC.

## Decision criteria
- Keep a symbol only if greped as used; a duplicate export is removed, never both kept.
- A dep is added only with a named standard purpose + license check; no dep "just in case".

## Worked success path
1. Fix export conflict (target A) → `dart analyze` drops the barrel error.
2. Add deps + pin SDK (B) → `flutter pub get` passes.
3. Concurrency fixes + guard (C, D) → analyzer clean.
4. Testers add pure-logic tests → `flutter test` green.
5. Push → CI gate green → Fable finish review.

## Acceptance checklist (mechanical — the CI gate)
- [ ] `flutter pub get` succeeds
- [ ] `dart format --output=none --set-exit-if-changed .` passes
- [ ] `dart analyze --fatal-infos --fatal-warnings` → 0 issues
- [ ] `flutter test` green (pure-logic tests only this phase)
- [ ] `dart run tool/architecture_guard.dart` passes
- [ ] no duplicate `CallState` / `ReconnectPolicy` definitions remain
