/// Concrete [LlmEngine] over an injected native inference binding.
///
/// `flutter_gemma` (Gemma 3n/4 E2B) or a llama.cpp FFI wrapper plugs in
/// as three closures in main.dart; this class owns the safety envelope:
/// a device-memory guard before load, a per-call timeout so a hung
/// native runtime can never freeze a user-facing future, and prompt
/// length capping.
library;

import 'dart:async';

import 'package:on_device_assistant/on_device_assistant.dart';

/// Native binding surface — one line each over the chosen plugin.
class NativeLlmBinding {
  const NativeLlmBinding({
    required this.initialize,
    required this.complete,
    required this.completeStream,
    required this.shutdown,
  });

  /// e.g. `(path) => FlutterGemma.initialize(path: path)`
  final Future<void> Function(String modelPath) initialize;

  /// e.g. `(p) => FlutterGemma.instance.getCompletion(prompt: p)`
  final Future<String> Function(String prompt) complete;

  final Stream<String> Function(String prompt) completeStream;

  final Future<void> Function() shutdown;
}

/// Production engine with the reliability envelope.
class GemmaLlmEngine implements LlmEngine {
  GemmaLlmEngine({
    required this.modelPath,
    required this._binding,
    required this._memoryProbe,
    this.minimumMemoryBytes = 2 * 1024 * 1024 * 1024,
    this.callTimeout = const Duration(seconds: 20),
    this.maxPromptChars = 4000,
  });

  final String modelPath;
  final NativeLlmBinding _binding;
  final Future<int> Function() _memoryProbe;

  /// E2B-int4 needs ~1.5 GB resident; refuse to load below this headroom
  /// so the OS never kills the app for memory pressure.
  final int minimumMemoryBytes;

  final Duration callTimeout;
  final int maxPromptChars;

  String _cap(String prompt) => prompt.length <= maxPromptChars
      ? prompt
      : prompt.substring(0, maxPromptChars);

  @override
  Future<void> load() async {
    final available = await _memoryProbe();
    if (available < minimumMemoryBytes) {
      throw StateError(
        'insufficient memory for on-device model: $available bytes',
      );
    }
    await _binding.initialize(modelPath).timeout(callTimeout);
  }

  @override
  Future<String> generate(String prompt) =>
      _binding.complete(_cap(prompt)).timeout(callTimeout);

  @override
  Stream<String> generateStream(String prompt) => _binding
      .completeStream(_cap(prompt))
      .timeout(callTimeout, onTimeout: (sink) => sink.close());

  @override
  Future<void> unload() => _binding.shutdown();
}
