/// LLM-backed assistant with automatic graceful fallback.
///
/// The real inference runtime (flutter_gemma, a llama.cpp FFI binding)
/// is injected as an [LlmEngine]; this class owns the reliability
/// contract: engine missing, failing to load, or throwing mid-call NEVER
/// reaches the user — every call falls back to the deterministic
/// rule-based tier.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';

import 'assistant_port.dart';
import 'rule_based_assistant.dart';

/// Minimal surface an inference runtime must provide. Implemented in the
/// Flutter app layer over the chosen engine; faked in tests.
abstract interface class LlmEngine {
  /// Loads model weights into memory. Throwing here marks the engine
  /// unavailable (e.g. model file absent, not enough memory).
  Future<void> load();

  Future<String> generate(String prompt);

  Stream<String> generateStream(String prompt);

  Future<void> unload();
}

/// [OnDeviceAssistant] that prefers the LLM and degrades without drama.
class LlmBackedAssistant implements OnDeviceAssistant {
  LlmBackedAssistant({required LlmEngine engine, OnDeviceAssistant? fallback})
    : _engine = engine,
      _fallback = fallback ?? RuleBasedAssistant();

  final LlmEngine _engine;
  final OnDeviceAssistant _fallback;
  AssistantEngineState _state = AssistantEngineState.uninitialized;

  @override
  AssistantEngineState get state => _state;

  @override
  Future<void> initialize() async {
    await _fallback.initialize();
    try {
      await _engine.load();
      _state = AssistantEngineState.ready;
    } catch (_) {
      // Model absent / out of memory: run on the rule-based tier.
      _state = AssistantEngineState.unavailable;
    }
  }

  Future<String> _generateOr(
    String prompt,
    Future<String> Function() fallback,
  ) async {
    if (_state != AssistantEngineState.ready) return fallback();
    try {
      return await _engine.generate(prompt);
    } catch (_) {
      // A mid-call engine failure demotes it; later calls stay fast.
      _state = AssistantEngineState.unavailable;
      return fallback();
    }
  }

  @override
  Future<String> explainConnectivity(ConnectivitySnapshot snapshot) =>
      _generateOr(
        'Explain this connectivity status to the user in one short, calm '
        'sentence. Mode: ${snapshot.mode.name}, best path: '
        '${snapshot.bestLaneId}, queued items: ${snapshot.pendingBundles}.',
        () => _fallback.explainConnectivity(snapshot),
      );

  @override
  Future<String> summarizeOfflineBacklog(List<String> messages) => _generateOr(
    'Summarize these ${messages.length} messages that arrived while the '
    'user was offline, in two sentences:\n${messages.join('\n')}',
    () => _fallback.summarizeOfflineBacklog(messages),
  );

  @override
  Stream<String> draftReply(String incomingMessage) async* {
    if (_state == AssistantEngineState.ready) {
      try {
        yield* _engine.generateStream(
          'Draft a brief friendly reply to: $incomingMessage',
        );
        return;
      } catch (_) {
        _state = AssistantEngineState.unavailable;
      }
    }
    yield* _fallback.draftReply(incomingMessage);
  }

  @override
  Future<void> dispose() async {
    if (_state == AssistantEngineState.ready) await _engine.unload();
    await _fallback.dispose();
    _state = AssistantEngineState.uninitialized;
  }
}
