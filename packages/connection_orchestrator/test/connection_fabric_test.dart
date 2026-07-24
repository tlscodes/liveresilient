import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

/// Scriptable lane: succeeds or fails on demand, counts sends.
class _FakeChannel implements TransportChannel {
  _FakeChannel(this.name, {this.up = true});

  @override
  final String name;

  bool up;
  int sends = 0;
  final sentPayloads = <List<int>>[];

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async => up;

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    if (!up) return const SendResult(SendStatus.transient);
    sentPayloads.add(payload);
    return const SendResult(SendStatus.ok, rttMs: 20);
  }

  @override
  Future<void> dispose() async {}
}

class _ToggleConsent implements DeviceLinkConsent {
  _ToggleConsent(this.granted);

  @override
  bool granted;
}

void main() {
  var clockMs = 0;
  late DtnBundleQueue queue;
  late ConnectionFabric fabric;

  ConnectionFabric build() =>
      ConnectionFabric(fallbackQueue: queue, nowMs: () => clockMs);

  setUp(() {
    clockMs = 0;
    queue = DtnBundleQueue();
    fabric = build();
  });

  tearDown(() => fabric.dispose());

  DtnBundle bundleLike(String id) => DtnBundle(
    id: id,
    payload: [1, 2, 3],
    priority: MeshMessagePriority.bulk,
    createdAtMs: clockMs,
    lifetimeMs: 60000,
  );

  group('ConnectionFabric · delivery', () {
    test('healthy lane carries the payload live', () async {
      final net = _FakeChannel('net');
      fabric.registerLane(
        net,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );

      final outcome = await fabric.deliver([9, 9], bundleId: 'a');

      expect(outcome, DeliveryOutcome.sentLive);
      expect(net.sentPayloads, [
        [9, 9],
      ]);
      expect(queue.pendingCount, 0);
      expect(fabric.snapshot.mode, FabricMode.live);
    });

    test(
      'predicted slide on best lane duplicates non-bulk onto the backup',
      () async {
        final wifi = _FakeChannel('wifi');
        final cell = _FakeChannel('cell');
        cell.health.availability = 0.6; // clear runner-up, wide margin
        fabric.registerLane(
          wifi,
          const LaneProfile(id: 'wifi', kind: LaneKind.internet),
        );
        fabric.registerLane(
          cell,
          const LaneProfile(id: 'cell', kind: LaneKind.internet, costRank: 1),
        );
        // Foresight: wifi is best but its score series slides hard.
        fabric.trend.observe('wifi', 0.9, nowMs: 0);
        fabric.trend.observe('wifi', 0.7, nowMs: 5000);
        fabric.trend.observe('wifi', 0.5, nowMs: 10000);

        final outcome = await fabric.deliver(
          [7],
          bundleId: 'dual',
          priority: MeshMessagePriority.presence,
        );

        expect(outcome, DeliveryOutcome.sentLive);
        expect(wifi.sends, 1, reason: 'primary still used');
        expect(cell.sends, 1, reason: 'danger-window duplicate sent early');

        // Same situation but bulk traffic: no duplication spend.
        final wifiBefore = wifi.sends, cellBefore = cell.sends;
        await fabric.deliver([8], bundleId: 'bulk1');
        expect(wifi.sends + cell.sends, wifiBefore + cellBefore + 1);
      },
    );

    test('all lanes down → payload parked in the DTN queue', () async {
      final net = _FakeChannel('net', up: false);
      fabric.registerLane(
        net,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );

      final outcome = await fabric.deliver([1], bundleId: 'a');

      expect(outcome, DeliveryOutcome.queuedForLater);
      expect(queue.pendingCount, 1);
    });

    test(
      'duplicate bundle id while offline is rejected, not double-queued',
      () async {
        final net = _FakeChannel('net', up: false);
        fabric.registerLane(
          net,
          const LaneProfile(id: 'net', kind: LaneKind.internet),
        );

        expect(
          await fabric.deliver([1], bundleId: 'a'),
          DeliveryOutcome.queuedForLater,
        );
        expect(
          await fabric.deliver([1], bundleId: 'a'),
          DeliveryOutcome.rejected,
        );
        expect(queue.pendingCount, 1);
      },
    );

    test('no lanes at all → still queues (offline mode)', () async {
      expect(
        await fabric.deliver([1], bundleId: 'a'),
        DeliveryOutcome.queuedForLater,
      );
      expect(fabric.snapshot.mode, FabricMode.offline);
      expect(fabric.snapshot.pendingBundles, 1);
    });
  });

  group('ConnectionFabric · ranking and consent', () {
    test(
      'cheaper lane wins a health near-tie; consent revocation reroutes',
      () async {
        final wifi = _FakeChannel('wifi');
        final peer = _FakeChannel('peer');
        final consent = _ToggleConsent(true);
        fabric.registerLane(
          wifi,
          const LaneProfile(id: 'wifi', kind: LaneKind.internet, costRank: 2),
        );
        fabric.registerLane(
          peer,
          LaneProfile(id: 'peer', kind: LaneKind.localPeer, consent: consent),
        );

        await fabric.deliver([1], bundleId: 'a');
        expect(
          peer.sends,
          1,
          reason: 'free lane outranks costRank 2 at equal health',
        );
        expect(wifi.sends, 0);

        consent.granted = false;
        await fabric.deliver([2], bundleId: 'b');
        expect(
          peer.sends,
          1,
          reason: 'revoked consent removes the lane instantly',
        );
        expect(wifi.sends, 1);
        expect(
          fabric.snapshot.lanes.singleWhere((l) => l.id == 'peer').eligible,
          isFalse,
        );
      },
    );

    test('failover: best lane fails → next lane carries it', () async {
      final a = _FakeChannel('a', up: false);
      final b = _FakeChannel('b');
      fabric.registerLane(
        a,
        const LaneProfile(id: 'a', kind: LaneKind.internet),
      );
      fabric.registerLane(
        b,
        const LaneProfile(id: 'b', kind: LaneKind.internet, costRank: 1),
      );

      final outcome = await fabric.deliver([1], bundleId: 'x');

      expect(outcome, DeliveryOutcome.sentLive);
      expect(b.sentPayloads.length, 1);
    });
  });

  group('ConnectionFabric · recovery and drain', () {
    test(
      'backlog drains automatically when a lane comes back via refresh',
      () async {
        final net = _FakeChannel('net', up: false);
        fabric.registerLane(
          net,
          const LaneProfile(id: 'net', kind: LaneKind.internet),
        );
        await fabric.deliver([1], bundleId: 'a');
        await fabric.deliver([2], bundleId: 'b');
        expect(queue.pendingCount, 2);

        net.up = true;
        final drained = await fabric.refresh();

        expect(drained, 2);
        expect(queue.pendingCount, 0);
        expect(net.sentPayloads.length, greaterThanOrEqualTo(2));
      },
    );

    test('a successful live delivery piggybacks the backlog drain', () async {
      final net = _FakeChannel('net', up: false);
      fabric.registerLane(
        net,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      await fabric.deliver([1], bundleId: 'old');
      expect(queue.pendingCount, 1);

      net.up = true;
      final outcome = await fabric.deliver([2], bundleId: 'new');

      expect(outcome, DeliveryOutcome.sentLive);
      expect(queue.pendingCount, 0, reason: 'old bundle rode along');
    });

    test('expired bundle never drains', () async {
      final net = _FakeChannel('net', up: false);
      fabric.registerLane(
        net,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      await fabric.deliver([1], bundleId: 'a');
      queue.offer(bundleLike('direct'), nowMs: clockMs);

      clockMs += 24 * 60 * 60 * 1000 + 1;
      net.up = true;
      await fabric.refresh();

      expect(net.sentPayloads, isEmpty);
      expect(queue.pendingCount, 0);
    });
  });

  group('ConnectionFabric · snapshots and recovery hook', () {
    test('snapshot stream publishes on register, deliver, refresh', () async {
      final events = <ConnectivitySnapshot>[];
      final sub = fabric.snapshots.listen(events.add);
      final net = _FakeChannel('net');
      fabric.registerLane(
        net,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      await fabric.deliver([1], bundleId: 'a');
      await fabric.refresh();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events.length, 3);
      expect(events.last.mode, FabricMode.live);
      expect(events.last.bestLaneId, 'net');
    });

    test(
      'leaving live mode fires the unhealthy hook exactly once per drop',
      () async {
        var fired = 0;
        fabric.onUnhealthy(() => fired++);
        final net = _FakeChannel('net');
        final consent = _ToggleConsent(true);
        fabric.registerLane(
          net,
          LaneProfile(id: 'net', kind: LaneKind.internet, consent: consent),
        );
        await fabric.deliver([1], bundleId: 'a');
        expect(fabric.snapshot.mode, FabricMode.live);

        consent.granted = false;
        fabric.unregisterLane('missing-is-fine');

        expect(fabric.snapshot.mode, FabricMode.storeAndForward);
        expect(fired, 1);
      },
    );

    test('dispose closes the stream and blocks further use', () async {
      await fabric.dispose();
      expect(
        () => fabric.registerLane(
          _FakeChannel('x'),
          const LaneProfile(id: 'x', kind: LaneKind.internet),
        ),
        throwsStateError,
      );
      await fabric.dispose(); // idempotent
    });
  });
}
