/// App-layer intelligence adapters: atomic disk persistence, network
/// label resolution, and hub composition.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:on_device_assistant/on_device_assistant.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/intelligence/intelligence_hub.dart';
import 'package:reference_app/src/intelligence/network_name_resolver.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('intel_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DiskJsonStorage storage(String name) =>
      DiskJsonStorage(directoryFactory: () => tempDir, fileName: name);

  group('DiskJsonStorage', () {
    test('round-trips and survives a corrupt file as a fresh brain', () async {
      final s = storage('brain.json');
      await s.save({'k': 1});
      expect(await s.load(), {'k': 1});

      File('${tempDir.path}/brain.json').writeAsStringSync('{broken');
      expect(await s.load(), isEmpty);
      expect(await storage('missing.json').load(), isEmpty);
    });

    test('atomic write leaves no temp file behind', () async {
      final s = storage('a.json');
      await s.save({'x': true});
      expect(File('${tempDir.path}/a.json.tmp').existsSync(), isFalse);
    });

    test('debounced saver coalesces writes and flushes on dispose', () async {
      var saves = 0;
      final saver = DebouncedSaver(
        storage: _CountingStorage(() => saves++),
        snapshot: () => {'v': 1},
        delay: const Duration(milliseconds: 10),
      );
      saver.markDirty();
      saver.markDirty();
      saver.markDirty();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(saves, 1, reason: 'three dirty marks, one write');
      await saver.dispose();
      expect(saves, 2, reason: 'dispose flushes');
    });
  });

  group('NetworkNameResolver', () {
    test('labels every transport and survives probe crashes', () async {
      Future<String> resolve(
        NetworkTransport t, {
        Future<String?> Function()? wifi,
      }) {
        return HardwareNetworkResolver(
          transportProbe: () async => t,
          wifiNameProbe: wifi,
          carrierNameProbe: () async => 'CarrierX',
        ).resolveNetworkLabel();
      }

      expect(
        await resolve(NetworkTransport.wifi, wifi: () async => 'Home'),
        'wifi:Home',
      );
      expect(await resolve(NetworkTransport.wifi), 'wifi:unnamed');
      expect(await resolve(NetworkTransport.cellular), 'cellular:CarrierX');
      expect(await resolve(NetworkTransport.none), 'offline');

      final crashy = HardwareNetworkResolver(
        transportProbe: () async => throw StateError('no permission'),
      );
      expect(await crashy.resolveNetworkLabel(), 'unresolved');
    });

    test('caching resolver honours TTL and invalidate', () async {
      var probes = 0;
      var clock = 0;
      final caching = CachingNetworkResolver(
        HardwareNetworkResolver(
          transportProbe: () async {
            probes++;
            return NetworkTransport.ethernet;
          },
        ),
        nowMs: () => clock,
        ttlMs: 1000,
      );
      await caching.resolveNetworkLabel();
      await caching.resolveNetworkLabel();
      expect(probes, 1, reason: 'second hit served from cache');
      clock += 2000;
      await caching.resolveNetworkLabel();
      expect(probes, 2, reason: 'TTL expiry re-probes');
      caching.invalidate();
      await caching.resolveNetworkLabel();
      expect(probes, 3, reason: 'connectivity-change invalidation re-probes');
      expect(caching.lastKnownLabel, 'ethernet');
    });
  });

  group('IntelligenceHub composition', () {
    CachingNetworkResolver resolver() => CachingNetworkResolver(
      HardwareNetworkResolver(
        transportProbe: () async => NetworkTransport.wifi,
        wifiNameProbe: () async => 'HomeNet',
      ),
      nowMs: () => 0,
    );

    test('learning survives a full stop/start cycle via disk', () async {
      final r = resolver();
      await r.resolveNetworkLabel();
      final hub = await IntelligenceHub.start(
        experienceStorage: storage('exp.json'),
        learnerStorage: storage('learn.json'),
        atlasStorage: storage('atlas.json'),
        laneChoiceStorage: storage('lane.json'),
        calibratorStorage: storage('calib.json'),
        journalStorage: storage('journal.json'),
        historyStorage: storage('history.json'),
        resolver: r,
      );
      for (var i = 0; i < 8; i++) {
        hub.recordObservation(quality: 0.9, slope: 0, nowMs: i);
      }
      await hub.dispose();

      final reborn = await IntelligenceHub.start(
        experienceStorage: storage('exp.json'),
        learnerStorage: storage('learn.json'),
        atlasStorage: storage('atlas.json'),
        laneChoiceStorage: storage('lane.json'),
        calibratorStorage: storage('calib.json'),
        journalStorage: storage('journal.json'),
        historyStorage: storage('history.json'),
        resolver: r,
      );
      expect(
        reborn.learner.expectedQuality('wifi:HomeNet', 'wifi:HomeNet'),
        greaterThan(0.7),
        reason: 'the map learned before the restart is back',
      );
      await reborn.dispose();
    });

    test('hub always runs the rule-based Persian narrator, ready', () async {
      final hub = await IntelligenceHub.start(
        experienceStorage: storage('e1.json'),
        learnerStorage: storage('l1.json'),
        atlasStorage: storage('a1.json'),
        laneChoiceStorage: storage('lc1.json'),
        calibratorStorage: storage('c1.json'),
        journalStorage: storage('j1.json'),
        historyStorage: storage('h1.json'),
        resolver: resolver(),
      );
      expect(hub.assistant, isA<RuleBasedAssistant>());
      expect(hub.assistant.state, AssistantEngineState.ready);
      await hub.dispose();
    });
  });
}

class _CountingStorage implements PersistentStorage {
  _CountingStorage(this.onSave);

  final void Function() onSave;

  @override
  Future<Map<String, Object?>> load() async => {};

  @override
  Future<void> save(Map<String, Object?> data) async => onSave();
}
