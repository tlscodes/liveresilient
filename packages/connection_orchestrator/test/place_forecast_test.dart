/// Long-term place memory seeding the fabric's lane ranking.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _FakeChannel implements TransportChannel {
  _FakeChannel(this.name);

  @override
  final String name;

  int sends = 0;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async => true;

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    return const SendResult(SendStatus.ok, rttMs: 20);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'arriving at a known place pre-ranks lanes before any traffic',
    () async {
      final learner = MicroLearner();
      for (var i = 0; i < 10; i++) {
        learner.observe(
          const ConnectivityExperience(
            placeTag: 'home',
            networkName: 'HomeNet',
            quality: 0.95,
            slope: 0,
            atMs: 0,
          ),
        );
        learner.observe(
          const ConnectivityExperience(
            placeTag: 'home',
            networkName: 'CellA',
            quality: 0.15,
            slope: 0,
            atMs: 0,
          ),
        );
      }

      final fabric = ConnectionFabric(
        fallbackQueue: DtnBundleQueue(),
        nowMs: () => 0,
      );
      final wifi = _FakeChannel('wifi');
      final cell = _FakeChannel('cell');
      // Identical health and cost: without the forecast they would tie.
      fabric.registerLane(
        wifi,
        const LaneProfile(id: 'wifi', kind: LaneKind.internet),
      );
      fabric.registerLane(
        cell,
        const LaneProfile(id: 'cell', kind: LaneKind.internet),
      );

      fabric.applyPlaceForecast(
        learner,
        'home',
        networkOfLane: (id) => id == 'wifi' ? 'HomeNet' : 'CellA',
      );

      expect(
        fabric.snapshot.bestLaneId,
        'wifi',
        reason: 'place memory ranks the historically good network first',
      );
      await fabric.deliver([1], bundleId: 'a');
      expect(wifi.sends, 1);
      expect(cell.sends, 0);

      // An unknown place clears nothing but matches nothing: biases reset.
      fabric.applyPlaceForecast(learner, 'nowhere', networkOfLane: (id) => id);
      final scores = {for (final l in fabric.snapshot.lanes) l.id: l.score};
      // Biases are cleared; the only remaining gap is the small health-EWMA
      // drift from wifi's one successful send — far below the bias scale.
      expect(
        (scores['wifi']! - scores['cell']!).abs(),
        lessThan(0.1),
        reason: 'no forecast → scores converge to live health again',
      );
      await fabric.dispose();
    },
  );
}
