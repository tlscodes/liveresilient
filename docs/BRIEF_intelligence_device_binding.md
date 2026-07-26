# Work Order — Wire the connectivity-intelligence circuit to real device services and the live UI

**Model to run this:** Fable 5, effort `high`.
**Repo:** `voice_call_kit_v3` (Dart pub-workspace monorepo; Flutter app at `apps/reference_app`).
**Gate:** `bash tools/run_gate_loop.sh` must print `GATE LOOP OK` (runs `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, and every package's tests). Infos are fatal.

---

## 0. Ground truth — read before writing a line

The abstract circuit is already built and green. Do **not** re-invent it; bind it. Actual API (verify by reading, do not assume):

- `packages/connection_orchestrator/lib/connection_orchestrator.dart` — `ConnectionFabric`, `DeliveryPlanner`, `LaneExperience`, `TrendSentinel`, `MicroLearner`, `LaneProfile`, `LaneKind`, `DeliveryOutcome`.
- `packages/on_device_assistant/lib/on_device_assistant.dart` — `OnDeviceAssistant`, `RuleBasedAssistant`, `LlmBackedAssistant`, `LlmEngine`, `ModelLifecycleManager`.
- `apps/reference_app/lib/src/intelligence/`:
  - `intelligence_hub.dart` — **entry point is the static factory `IntelligenceHub.start({experienceStorage, learnerStorage, resolver, llmEngine})`**, which restores both persisted brains from disk before returning. There is no bare `IntelligenceHub(...)` constructor and no `hydrate()` method — `start()` already hydrates.
  - `intelligence_boot.dart` — `bootIntelligence({storageDirFactory, resolver, llmEngine, primaryLane, localLinkLane, nowMs})` composes hub + fabric + director and is the single boot seam `main()` calls.
  - `disk_json_storage.dart` — `DiskJsonStorage({required directoryFactory, required fileName})` (atomic tmp+rename, corrupt-safe). Takes a `Directory Function()`, not a bare filename.
  - `network_name_resolver.dart` — `HardwareNetworkResolver({required transportProbe, wifiNameProbe, carrierNameProbe})` wrapped by `CachingNetworkResolver(inner, {required nowMs, ttlMs})`. The probes are injected closures — the app binds them to real plugins.
  - `gemma_llm_engine.dart` — `GemmaLlmEngine({required modelPath, required binding, required memoryProbe, minimumMemoryBytes, callTimeout, maxPromptChars})`. It needs a `NativeLlmBinding` and a `memoryProbe`; `modelPath` alone is not a valid constructor call.
  - `device_bindings.dart` — the seam that returns `buildLocalLinkLane({binding, consent})` and `buildLlmEngine()`, both `null` in the demo/gate build. **This is where real plugins attach.**
  - `intelligence_director.dart` — `IntelligenceDirector` (ChangeNotifier) exposing `DirectorAdvisory advisory {level, headline, detail, actionTaken}`.
  - `foresight_card.dart` — `ForesightCard({required director})`, hidden while calm.
  - `assistant_view.dart` — `AssistantView({required director})`, always visible.

**Constraint that is non-negotiable:** `tool/architecture_guard.dart` is an architecture-guard test that fails the gate unless the transport stays a standard stack (DTLS-SRTP media, WSS signalling, plain DTN store-and-forward). Keep every identifier a literal description of what it does.

**CI-safety rule:** real plugins (`flutter_gemma`, `connectivity_plus`, `network_info_plus`, `path_provider`, a Wi-Fi Direct/BLE plugin, `get_it`) cannot run in the gate. They are wired **only** behind the `device_bindings.dart` seam and guarded so the demo/test build stays plugin-free and green. Adding them as hard dependencies that the gate imports is a failure.

---

## Task 1 — Real device binding at app boot

Goal: on a physical device, `main()` starts the intelligence circuit with real disk, real network-name probes, and (when a model file is present) a real language-model engine; in the gate/demo build it degrades to the deterministic rule-based path with zero plugin deps.

1. **Keep `bootIntelligence` as the single composition seam.** Do not hand-inline hub construction in `main()`; extend `device_bindings.dart` instead so `main()` stays declarative:
   - `buildLlmEngine()` — on device: resolve the model path with `path_provider.getApplicationDocumentsDirectory()`, confirm the model file exists, construct `GemmaLlmEngine(modelPath: ..., binding: <flutter_gemma NativeLlmBinding>, memoryProbe: <real RAM probe>)`; return `null` when the file is absent so the assistant falls back to `RuleBasedAssistant`.
   - Add `buildNetworkResolverProbes()` returning the three real closures (`transportProbe` over `connectivity_plus`, `wifiNameProbe`/`carrierNameProbe` over `network_info_plus`), or `null` to keep the current wifi-stub default.
   - `buildLocalLinkLane({binding, consent})` already exists — fill the three `LocalLinkBinding` closures from the chosen Wi-Fi Direct/BLE plugin.
2. **Service locator (optional, gate-safe).** If you introduce `get_it`, register `IntelligenceHub`, `ConnectionFabric`, and `NetworkNameResolver` singletons **after** `bootIntelligence` returns, and read them through an app-level accessor so widget tests that construct screens directly still pass without a registered locator (guard every `GetIt.I<...>` access, or inject via constructor as today). Do not make the locator a hard requirement of any widget.
3. **Model lifecycle.** Gate the model download through the existing `ModelLifecycleManager` (unmetered-network + charging + checksum blockers). The engine must never block first frame: hydrate brains before `runApp`, but acquire/load the model lazily off the UI thread and let the assistant serve rule-based output until the engine reports ready.
4. **Tests (gate-safe):** a boot test with a fake `LlmEngine` and fake resolver probes proving the circuit comes up, both brains restore across a reboot, and a missing model cleanly yields the rule-based assistant. No real plugin in any test.

## Task 2 — Live intelligence → reactive UI (Smart Lane)

Goal: the circuit's judgment and narration reach the user as reactive widgets driven only by `IntelligenceDirector` (a `ChangeNotifier`), no polling.

1. **Foresight Card** — already exists and hides while calm; extend it so a `TrendSentinel` `slipping`/`failingSoon` verdict or a `MicroLearner`/`applyPlaceForecast` prediction surfaces a "connection may weaken soon" state **before** the mode actually degrades. Show the forecast reason and the self-heal action the director already took (`advisory.actionTaken`).
2. **Assistant View** — already always-visible; upgrade it from a static line to a **streaming** panel:
   - Consume the assistant's streaming output (`OnDeviceAssistant.draftReply(...)` returns a token stream) and render tokens as they arrive.
   - Add an **offline-backlog summary**: when the fabric is in store-and-forward/offline mode, call `assistant.summarizeOfflineBacklog(pendingIds)` and show a human-language summary of what is queued and will send on reconnect.
3. **Team-leader behaviour** — the director already classifies, self-heals (`fabric.refresh()` under cooldown), and narrates. Extend its judgment so it also **acts on foresight** (pre-warm/re-rank a fallback lane when a slide is predicted, not only after a drop) and records each decision so the UI shows a short "what I did and why" line. Keep every action idempotent and cooldown-bounded so a flapping path cannot cause thrash.
4. **Tests:** widget tests driving the director through calm → predicted-slip → degraded → offline, asserting the Foresight Card appears on prediction, the Assistant View streams text and shows the backlog summary offline, and the director's action line updates. Real async fabric I/O inside `testWidgets` must be wrapped in `await tester.runAsync(() async {...})`.

---

## Acceptance checklist (each item mechanically verifiable)

- [ ] `bash tools/run_gate_loop.sh` prints `GATE LOOP OK`; the gate/demo build pulls in **no** new plugin dependency.
- [ ] On device, a present model file loads a real `GemmaLlmEngine`; an absent one falls back to `RuleBasedAssistant` with no crash.
- [ ] Both persisted brains (`LaneExperience`, `MicroLearner`) restore across an app reboot.
- [ ] Foresight Card appears on a predicted slide **before** the mode degrades; hidden when calm.
- [ ] Assistant View renders assistant tokens incrementally and shows the offline-backlog summary when queued.
- [ ] The director takes at least one pre-emptive action on a predicted slide, cooldown-bounded, surfaced in the UI action line.
- [ ] Every identifier literally names its behaviour; `tool/architecture_guard.dart` passes.

## Hidden traps to check first

- `IntelligenceHub.start(...)` (static, hydrates) — **not** `IntelligenceHub(...)` + `hydrate()`. The example sketch that used the latter does not match the code.
- `GemmaLlmEngine` needs `binding` + `memoryProbe`, not just `modelPath`.
- `DiskJsonStorage` takes a `directoryFactory` closure, not a filename string.
- Model load must be off the first-frame path; the assistant must serve rule-based output until the engine is ready.
- Every `GetIt.I<...>` access must be guarded/optional so isolated widget tests still pass.
- Name each module for its literal function — a nearby-device link is a `local_link_lane`, the path chooser is a `delivery_planner`, the health forecaster is a `trend_sentinel`.
