/// Deterministic default engine: template-based language, zero model
/// download, instant answers. Ships as the fallback tier under any LLM
/// engine and as the only tier on low-memory devices.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';

import 'assistant_port.dart';

/// Rule-based [OnDeviceAssistant]: honest, small, and always available.
class RuleBasedAssistant implements OnDeviceAssistant {
  RuleBasedAssistant();

  AssistantEngineState _state = AssistantEngineState.uninitialized;

  @override
  Future<void> initialize() async {
    _state = AssistantEngineState.ready;
  }

  @override
  AssistantEngineState get state => _state;

  @override
  Future<String> explainConnectivity(ConnectivitySnapshot snapshot) async {
    final pending = snapshot.pendingBundles;
    final queued = pending == 0
        ? ''
        : ' $pending item${pending == 1 ? '' : 's'} will be delivered '
              'automatically as soon as a path is available.';
    switch (snapshot.mode) {
      case FabricMode.live:
        return 'You are connected via ${snapshot.bestLaneId}.'
            '${queued.isEmpty ? ' Everything is up to date.' : queued}';
      case FabricMode.degraded:
        return 'Your connection via ${snapshot.bestLaneId} is weak right '
            'now; quality is reduced to keep the call alive.$queued';
      case FabricMode.storeAndForward:
        return 'No live connection right now. Your messages are being '
            'saved safely and will send themselves when any path returns.'
            '$queued';
      case FabricMode.offline:
        return 'Connectivity is not set up yet on this device.$queued';
    }
  }

  @override
  Future<String> summarizeOfflineBacklog(List<String> messages) async {
    if (messages.isEmpty) return 'Nothing arrived while you were offline.';
    final preview = messages.first.length > 80
        ? '${messages.first.substring(0, 77)}...'
        : messages.first;
    return messages.length == 1
        ? 'One message arrived while you were offline: "$preview"'
        : '${messages.length} messages arrived while you were offline. '
              'The first one: "$preview"';
  }

  @override
  Stream<String> draftReply(String incomingMessage) async* {
    // Deterministic acknowledgement draft; an LLM engine replaces this
    // with a real generation stream.
    yield 'Got your message';
    yield ' — I will reply properly as soon as I am back online.';
  }

  @override
  Future<void> dispose() async {
    _state = AssistantEngineState.uninitialized;
  }
}
