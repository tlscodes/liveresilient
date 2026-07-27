/// End-to-end failover: when the live WebRTC path dies mid-stream, the
/// fabric moves media onto the WAN fallback lanes without dropping or
/// reordering frames.
///
/// Every lane here is an in-process fake. Nothing touches the network:
/// the public echo endpoints are liveness toys, not relays, and a test
/// that depended on a third party would be measuring their uptime.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// A lane that records what it carried and can be switched off, standing
/// in for a real transport that stops delivering.
class _FakeLane implements TransportChannel {
  _FakeLane(this.name, {required double reliabilityPrior})
    : health = ChannelHealth(
        reliabilityPrior: reliabilityPrior,
        bandwidth: 0.8,
      );

  @override
  final String name;

  final List<List<int>> carried = [];
  bool alive = true;

  @override
  final ChannelHealth health;

  /// Sequence numbers this lane carried, in carriage order.
  List<int> get sequences => [for (final frame in carried) frame.single];

  @override
  Future<SendResult> send(List<int> payload) async {
    if (!alive) {
      const failure = SendResult(SendStatus.unavailable);
      health.observe(failure);
      return failure;
    }
    carried.add(List<int>.of(payload));
    const ok = SendResult(SendStatus.ok, rttMs: 20);
    health.observe(ok);
    return ok;
  }

  @override
  Future<bool> probe() async {
    health.pathDegraded = !alive;
    return alive;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakeLane webrtc;
  late _FakeLane relay;
  late _FakeLane longPoll;
  late ConnectionFabric fabric;
  var now = 0;

  setUp(() {
    now = 0;
    webrtc = _FakeLane('webrtc-media', reliabilityPrior: 0.95);
    relay = _FakeLane(ResilientLaneIds.webSocketRelay, reliabilityPrior: 0.75);
    longPoll = _FakeLane(ResilientLaneIds.httpLongPoll, reliabilityPrior: 0.6);

    fabric = ConnectionFabric(
      fallbackQueue: DtnBundleQueue(),
      nowMs: () => now += 10,
    );
    fabric.registerLane(
      webrtc,
      const LaneProfile(id: 'webrtc-media', kind: LaneKind.internet),
    );
    fabric.registerLane(
      relay,
      const LaneProfile(
        id: ResilientLaneIds.webSocketRelay,
        kind: LaneKind.internet,
        costRank: 1,
        energyRank: 1,
      ),
    );
    fabric.registerLane(
      longPoll,
      const LaneProfile(
        id: ResilientLaneIds.httpLongPoll,
        kind: LaneKind.internet,
        costRank: 2,
        energyRank: 1,
      ),
    );
  });

  tearDown(() => fabric.dispose());

  /// Sends [count] numbered frames and returns the sequence numbers a live
  /// lane carried, in the order the fabric sent them.
  Future<List<int>> streamFrames(int first, int count) async {
    final live = <int>[];
    for (var seq = first; seq < first + count; seq++) {
      final outcome = await fabric.deliver(
        [seq],
        bundleId: 'frame-$seq',
        // Media frames, not signalling: `callSignal` marks a payload
        // urgent, and the planner then duplicates it onto the runner-up
        // lane on purpose. Duplication is correct there and would just
        // obscure which lane the frame actually took here.
        priority: LinkMessagePriority.bulk,
      );
      if (outcome == DeliveryOutcome.sentLive) live.add(seq);
    }
    return live;
  }

  test(
    'media continues in sequence when the live path dies mid-stream',
    () async {
      final before = await streamFrames(0, 5);
      expect(before, [0, 1, 2, 3, 4]);
      expect(webrtc.sequences, [0, 1, 2, 3, 4], reason: 'best lane first');
      expect(relay.carried, isEmpty);

      // The live path dies. Nothing else changes.
      webrtc.alive = false;

      final after = await streamFrames(5, 5);
      expect(after, [5, 6, 7, 8, 9], reason: 'no frame is lost at the switch');

      // Every frame after the drop moved to a fallback lane, in order.
      final onFallback = [...relay.sequences, ...longPoll.sequences]..sort();
      expect(onFallback, [5, 6, 7, 8, 9]);
      expect(relay.sequences, orderedEquals(relay.sequences.toList()..sort()));

      // The sequence as a whole is unbroken across the failover boundary.
      expect([...before, ...after], List<int>.generate(10, (i) => i));
    },
  );

  test('the relay lane is preferred over long-poll by cost rank', () async {
    webrtc.alive = false;
    await streamFrames(0, 3);
    expect(relay.sequences, [0, 1, 2]);
    expect(longPoll.carried, isEmpty);
  });

  test(
    'with every lane down the frames park in the queue, still ordered',
    () async {
      webrtc.alive = false;
      relay.alive = false;
      longPoll.alive = false;

      final live = await streamFrames(0, 3);
      expect(live, isEmpty, reason: 'no lane carried anything');
      expect(fabric.snapshot.pendingBundles, 3);

      // A path comes back; the backlog drains through it in queue order.
      relay.alive = true;
      final drained = await fabric.refresh();
      expect(drained, 3);
      expect(relay.sequences, [0, 1, 2]);
      expect(fabric.snapshot.pendingBundles, 0);
    },
  );
}
