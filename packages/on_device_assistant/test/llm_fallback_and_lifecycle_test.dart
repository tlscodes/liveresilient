/// The reliability contract of the LLM tier and the model download policy.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:on_device_assistant/on_device_assistant.dart';
import 'package:test/test.dart';

class _FakeEngine implements LlmEngine {
  _FakeEngine({this.failLoad = false, this.failGenerate = false});

  bool failLoad;
  bool failGenerate;
  bool unloaded = false;

  @override
  Future<void> load() async {
    if (failLoad) throw StateError('model file missing');
  }

  @override
  Future<String> generate(String prompt) async {
    if (failGenerate) throw StateError('inference crashed');
    return 'LLM: $prompt';
  }

  @override
  Stream<String> generateStream(String prompt) async* {
    if (failGenerate) throw StateError('inference crashed');
    yield 'LLM-stream';
  }

  @override
  Future<void> unload() async {
    unloaded = true;
  }
}

ConnectivitySnapshot _snap() => const ConnectivitySnapshot(
  mode: FabricMode.live,
  lanes: [],
  bestLaneId: 'wifi',
  pendingBundles: 0,
  atMs: 0,
);

void main() {
  group('LlmBackedAssistant · graceful degradation', () {
    test('healthy engine answers through the LLM', () async {
      final a = LlmBackedAssistant(engine: _FakeEngine());
      await a.initialize();
      expect(a.state, AssistantEngineState.ready);
      expect(await a.explainConnectivity(_snap()), startsWith('LLM:'));
      await a.dispose();
    });

    test(
      'failed model load falls back to the rule-based tier, no crash',
      () async {
        final a = LlmBackedAssistant(engine: _FakeEngine(failLoad: true));
        await a.initialize();
        expect(a.state, AssistantEngineState.unavailable);
        final answer = await a.explainConnectivity(_snap());
        expect(answer.toLowerCase(), contains('connected'));
        await a.dispose();
      },
    );

    test(
      'mid-call engine crash demotes the engine and still answers',
      () async {
        final engine = _FakeEngine(failGenerate: true);
        final a = LlmBackedAssistant(engine: engine);
        await a.initialize();
        expect(a.state, AssistantEngineState.ready);

        final answer = await a.summarizeOfflineBacklog(['hi']);

        expect(answer, contains('offline'));
        expect(
          a.state,
          AssistantEngineState.unavailable,
          reason: 'later calls skip the broken engine entirely',
        );
        await a.dispose();
      },
    );

    test('dispose unloads a ready engine', () async {
      final engine = _FakeEngine();
      final a = LlmBackedAssistant(engine: engine);
      await a.initialize();
      await a.dispose();
      expect(engine.unloaded, isTrue);
    });
  });

  group('ModelLifecycleManager · download policy and integrity', () {
    test(
      'blocks on metered network, discharging battery, or existing model',
      () {
        final m = ModelLifecycleManager(expectedChecksum: 'abc');
        expect(
          m.blockers(
            device: const DevicePowerNetworkState(
              onUnmeteredNetwork: false,
              charging: false,
            ),
            modelAlreadyPresent: true,
          ),
          containsAll([
            DownloadBlocker.alreadyPresent,
            DownloadBlocker.notOnUnmeteredNetwork,
            DownloadBlocker.notCharging,
          ]),
        );
        expect(
          m.blockers(
            device: const DevicePowerNetworkState(
              onUnmeteredNetwork: true,
              charging: true,
            ),
            modelAlreadyPresent: false,
          ),
          isEmpty,
        );
      },
    );

    test(
      'acquire: happy path reports progress then verifies checksum',
      () async {
        final m = ModelLifecycleManager(expectedChecksum: 'good');
        final seen = <double>[];
        final sub = m.progress.listen((p) => seen.add(p.fraction));

        final result = await m.acquire(
          device: const DevicePowerNetworkState(
            onUnmeteredNetwork: true,
            charging: true,
          ),
          modelAlreadyPresent: false,
          totalBytes: 100,
          fetch: (onProgress) async {
            onProgress(50);
            onProgress(100);
          },
          computeChecksum: () async => 'good',
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(result, ModelAcquisitionResult.ready);
        expect(seen, [0.5, 1.0]);
        await m.dispose();
      },
    );

    test('corrupt download is rejected before it can ever be loaded', () async {
      final m = ModelLifecycleManager(expectedChecksum: 'good');
      final result = await m.acquire(
        device: const DevicePowerNetworkState(
          onUnmeteredNetwork: true,
          charging: true,
        ),
        modelAlreadyPresent: false,
        totalBytes: 10,
        fetch: (_) async {},
        computeChecksum: () async => 'truncated',
      );
      expect(result, ModelAcquisitionResult.checksumMismatch);
      await m.dispose();
    });

    test('policy blockers stop the fetch from even starting', () async {
      final m = ModelLifecycleManager(expectedChecksum: 'x');
      var fetched = false;
      final result = await m.acquire(
        device: const DevicePowerNetworkState(
          onUnmeteredNetwork: false,
          charging: true,
        ),
        modelAlreadyPresent: false,
        totalBytes: 10,
        fetch: (_) async => fetched = true,
        computeChecksum: () async => 'x',
      );
      expect(result, ModelAcquisitionResult.blocked);
      expect(fetched, isFalse);
      await m.dispose();
    });
  });
}
