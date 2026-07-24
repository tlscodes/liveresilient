/// The abstract port every assistant engine implements.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';

/// Readiness of the underlying engine.
enum AssistantEngineState { uninitialized, ready, unavailable }

/// One swappable on-device assistant. Implementations must be safe to
/// call before [initialize] completes: methods either answer from a
/// fallback or throw [StateError] — they never crash the app.
abstract interface class OnDeviceAssistant {
  /// Loads/warms the engine (model weights, native runtime). A failed
  /// initialization leaves the engine [AssistantEngineState.unavailable];
  /// callers should then fall back to a rule-based implementation.
  Future<void> initialize();

  AssistantEngineState get state;

  /// Explains the current connectivity truth to the user in plain
  /// language (the locale the implementation was configured with).
  Future<String> explainConnectivity(ConnectivitySnapshot snapshot);

  /// Summarizes a backlog of messages that accumulated while offline.
  Future<String> summarizeOfflineBacklog(List<String> messages);

  /// Streams a drafted reply suggestion for an incoming message.
  Stream<String> draftReply(String incomingMessage);

  /// Releases engine resources.
  Future<void> dispose();
}
