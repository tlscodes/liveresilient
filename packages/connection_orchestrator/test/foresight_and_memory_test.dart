/// Persistence of the learned model and proactive trend forecasting.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _FakeChannel implements TransportChannel {
  _FakeChannel(this.name);

  @override
  final String name;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async => true;

  @override
  Future<SendResult> send(List<int> payload) async =>
      const SendResult(SendStatus.ok, rttMs: 20);

  @override
  Future<void> dispose() async {}
}

void main() {
  final morning = DateTime(2026, 7, 24, 10).millisecondsSinceEpoch;

  group('LaneExperience · persistence', () {
    test('round-trips through JSON with memories intact', () {
      final exp = LaneExperience();
      final ctx = DeliveryContext.at(morning, place: 'home');
      for (var i = 0; i < 10; i++) {
        exp.record('peer', ctx, success: false);
        exp.record('net', ctx, success: true);
      }

      final restored = LaneExperience.fromJson(exp.toJson());

      expect(restored.probability('peer', ctx), exp.probability('peer', ctx));
      expect(restored.probability('net', ctx), exp.probability('net', ctx));
      expect(restored.ucbScore('net', ctx), exp.ucbScore('net', ctx));
    });

    test('corrupt JSON degrades to a fresh brain, never a crash', () {
      final restored = LaneExperience.fromJson({
        'totalAttempts': 'garbage',
        'stats': {
          'ok|1|home': {'s': 3, 'f': 1},
          'bad-entry': 'not-a-map',
          'negative|1|x': {'s': -5, 'f': 2},
        },
      });

      final ctx = DeliveryContext.at(morning, place: 'home');
      expect(restored.probability('ok', ctx), greaterThan(0.5));
      expect(restored.probability('negative', ctx), 0.5);
    });
  });

  group('TrendMonitor · forecasting', () {
    test('needs 3 samples before judging', () {
      final t = TrendMonitor();
      t.observe('net', 0.8, nowMs: 0);
      t.observe('net', 0.7, nowMs: 1000);
      expect(t.verdict('net'), TrendVerdict.unknown);
    });

    test(
      'flat trajectory is steady, steep slide is flagged before the floor',
      () {
        final t = TrendMonitor(horizonMs: 10000, floor: 0.2);
        for (var i = 0; i < 5; i++) {
          t.observe('flat', 0.8, nowMs: i * 1000);
          // Falling 0.06/s from 0.8: still 0.56 at the last sample, but the
          // 10s projection is far below the floor.
          t.observe('sliding', 0.8 - i * 0.06, nowMs: i * 1000);
        }
        expect(t.verdict('flat'), TrendVerdict.steady);
        expect(t.verdict('sliding'), TrendVerdict.failingSoon);
        expect(t.projectedScore('sliding')!, lessThan(0.2));
      },
    );

    test('gentle decline is slipping, not failingSoon', () {
      final t = TrendMonitor(horizonMs: 5000, floor: 0.2);
      for (var i = 0; i < 6; i++) {
        t.observe('lane', 0.9 - i * 0.02, nowMs: i * 1000);
      }
      expect(t.verdict('lane'), TrendVerdict.slipping);
    });
  });

  group('ConnectionFabric · proactive recovery', () {
    test(
      'a best lane forecast to fail fires the unhealthy hook early',
      () async {
        var clockMs = 0;
        final channel = _FakeChannel('net');
        final fabric = ConnectionFabric(
          fallbackQueue: DtnBundleQueue(),
          nowMs: () => clockMs,
          trend: TrendMonitor(horizonMs: 10000, floor: 0.2),
        );
        var fired = 0;
        fabric.onUnhealthy(() => fired++);
        fabric.registerLane(
          channel,
          const LaneProfile(id: 'net', kind: LaneKind.internet),
        );

        // Simulate steadily worsening measured health across refreshes: the
        // lane still works (sends succeed) but its score is in free fall.
        for (var i = 0; i < 5; i++) {
          channel.health.availability = 1.0 - i * 0.18;
          clockMs = i * 1000;
          await fabric.refresh();
        }

        expect(
          fired,
          greaterThan(0),
          reason: 'forecast crossed the floor → recovery before hard failure',
        );
        expect(fabric.snapshot.mode, isNot(FabricMode.offline));
        await fabric.dispose();
      },
    );
  });
}
