import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:on_device_assistant/on_device_assistant.dart';
import 'package:test/test.dart';

ConnectivitySnapshot snap(FabricMode mode, {String? best, int pending = 0}) =>
    ConnectivitySnapshot(
      mode: mode,
      lanes: const [],
      bestLaneId: best,
      pendingBundles: pending,
      atMs: 0,
    );

void main() {
  late RuleBasedAssistant assistant;

  setUp(() async {
    assistant = RuleBasedAssistant();
    await assistant.initialize();
  });

  test('initialize flips state to ready; dispose resets it', () async {
    expect(assistant.state, AssistantEngineState.ready);
    await assistant.dispose();
    expect(assistant.state, AssistantEngineState.uninitialized);
  });

  test('explains every fabric mode in plain language', () async {
    final live = await assistant.explainConnectivity(
      snap(FabricMode.live, best: 'wifi'),
    );
    expect(live, contains('wifi'));
    expect(live.toLowerCase(), contains('connected'));

    final saf = await assistant.explainConnectivity(
      snap(FabricMode.storeAndForward, pending: 3),
    );
    expect(saf.toLowerCase(), contains('saved'));
    expect(saf, contains('3'));

    final degraded = await assistant.explainConnectivity(
      snap(FabricMode.degraded, best: 'peer', pending: 1),
    );
    expect(degraded, contains('peer'));
    expect(degraded, contains('1 item'));
  });

  test('summarizes an offline backlog with a safe preview', () async {
    expect(await assistant.summarizeOfflineBacklog([]), contains('Nothing'));
    final long = 'x' * 200;
    final summary = await assistant.summarizeOfflineBacklog([long, 'b', 'c']);
    expect(summary, contains('3 messages'));
    expect(summary, contains('...'));
    expect(summary.length, lessThan(200));
  });

  test('draftReply streams a deterministic acknowledgement', () async {
    final parts = await assistant.draftReply('hello').toList();
    expect(parts, isNotEmpty);
    expect(parts.join(), contains('Got your message'));
  });
}
