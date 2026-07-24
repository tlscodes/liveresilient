import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

DtnBundle _bundle(
  String id, {
  MeshMessagePriority priority = MeshMessagePriority.presence,
  int createdAtMs = 0,
  int lifetimeMs = 10000,
  int bytes = 4,
}) {
  return DtnBundle(
    id: id,
    payload: List<int>.filled(bytes, 1),
    priority: priority,
    createdAtMs: createdAtMs,
    lifetimeMs: lifetimeMs,
  );
}

void main() {
  group('BundleExchange · handOffAndForget', () {
    test('B ends up with A\'s bundles exactly once; A drops them', () async {
      final a = DtnBundleQueue();
      final b = DtnBundleQueue();
      a.offer(_bundle('m1'), nowMs: 0);
      a.offer(_bundle('m2'), nowMs: 0);

      final report = await const BundleExchange().run(
        sender: a,
        receiver: b,
        nowMs: 0,
      );

      expect(report.transferred, unorderedEquals(['m1', 'm2']));
      expect(b.pendingCount, 2);
      expect(a.pendingCount, 0);
    });
  });

  group('BundleExchange · carryAndKeep', () {
    test('A keeps its bundles after handing off to B', () async {
      final a = DtnBundleQueue();
      final b = DtnBundleQueue();
      a.offer(_bundle('m1'), nowMs: 0);

      final report = await const BundleExchange().run(
        sender: a,
        receiver: b,
        nowMs: 0,
        retain: RetainPolicy.carryAndKeep,
      );

      expect(report.transferred, ['m1']);
      expect(a.pendingCount, 1);
      expect(b.pendingCount, 1);
    });
  });

  test(
    'three-node relay chain delivers end-to-end, exactly once at C',
    () async {
      final a = DtnBundleQueue();
      final carrier = DtnBundleQueue();
      final c = DtnBundleQueue();
      a.offer(_bundle('m1'), nowMs: 0);

      // Contact 1: A meets the carrier.
      await const BundleExchange().run(sender: a, receiver: carrier, nowMs: 0);
      expect(carrier.pendingCount, 1);
      expect(a.pendingCount, 0);

      // Contact 2: the carrier later reaches C.
      await const BundleExchange().run(
        sender: carrier,
        receiver: c,
        nowMs: 1000,
      );
      expect(c.pendingCount, 1);
      expect(carrier.pendingCount, 0);

      // A duplicate re-offer at C (e.g. the carrier meets C twice) must not
      // duplicate the bundle.
      c.offer(_bundle('m1'), nowMs: 2000);
      expect(c.pendingCount, 1);
    },
  );

  test('per-contact quota enforced in priority-then-oldest order', () async {
    final a = DtnBundleQueue();
    final b = DtnBundleQueue();
    a.offer(
      _bundle('bulk-old', priority: MeshMessagePriority.bulk, createdAtMs: 0),
      nowMs: 0,
    );
    a.offer(
      _bundle(
        'call-old',
        priority: MeshMessagePriority.callSignal,
        createdAtMs: 1,
      ),
      nowMs: 1,
    );
    a.offer(
      _bundle(
        'presence-new',
        priority: MeshMessagePriority.presence,
        createdAtMs: 2,
      ),
      nowMs: 2,
    );

    final report = await const BundleExchange(
      maxBundlesPerContact: 1,
    ).run(sender: a, receiver: b, nowMs: 10);

    // Highest priority (callSignal) goes first and fits the quota of 1.
    expect(report.transferred, ['call-old']);
    expect(b.pendingCount, 1);
    expect(b.pendingInDeliveryOrder(10).single.id, 'call-old');
    // The rest stayed queued at the sender (quota, not delivered).
    expect(a.pendingCount, 2);
  });

  test('expired bundles never cross a contact', () async {
    final a = DtnBundleQueue();
    final b = DtnBundleQueue();
    a.offer(_bundle('fresh', createdAtMs: 0, lifetimeMs: 100), nowMs: 0);
    a.offer(_bundle('stale', createdAtMs: 0, lifetimeMs: 5), nowMs: 0);

    final report = await const BundleExchange().run(
      sender: a,
      receiver: b,
      nowMs: 50, // 'stale' has expired (5ms lifetime); 'fresh' has not.
    );

    expect(report.transferred, ['fresh']);
    expect(b.pendingCount, 1);
    expect(b.pendingInDeliveryOrder(50).single.id, 'fresh');
  });

  test(
    'a contact interrupted mid-transfer leaves both sides consistent',
    () async {
      final a = DtnBundleQueue();
      final b = DtnBundleQueue();
      a.offer(
        _bundle(
          'first',
          priority: MeshMessagePriority.callSignal,
          createdAtMs: 0,
        ),
        nowMs: 0,
      );
      a.offer(
        _bundle(
          'second',
          priority: MeshMessagePriority.presence,
          createdAtMs: 1,
        ),
        nowMs: 1,
      );

      var openCalls = 0;
      bool isOpen() {
        openCalls++;
        // Open for the first bundle's attempt only; closed before the second.
        return openCalls <= 1;
      }

      final report = await const BundleExchange().run(
        sender: a,
        receiver: b,
        nowMs: 10,
        isContactOpen: isOpen,
      );

      expect(report.transferred, ['first']);
      expect(report.interrupted, isTrue);
      // Already-transferred bundle stays at the receiver.
      expect(b.pendingCount, 1);
      expect(b.pendingInDeliveryOrder(10).single.id, 'first');
      // Untransferred bundle stays queued at the sender.
      expect(a.pendingCount, 1);
      expect(a.pendingInDeliveryOrder(10).single.id, 'second');
    },
  );

  test(
    'SimulatedCarrierLink joins two endpoints and reports contacts',
    () async {
      final link = SimulatedCarrierLink(nodeAId: 'A', nodeBId: 'B');
      final seenOnA = <String>[];
      final seenOnB = <String>[];
      link.portForA.contacts.listen((c) => seenOnA.add(c.peerId));
      link.portForB.contacts.listen((c) => seenOnB.add(c.peerId));

      final contact = link.openContact(nowMs: 0);
      await Future<void>.delayed(Duration.zero);

      expect(seenOnA, [contact.peerId]);
      expect(seenOnB, [contact.peerId]);
      expect(contact.isOpen, isTrue);
      contact.close();
      expect(contact.isOpen, isFalse);

      await link.dispose();
    },
  );

  test('SimulatedBidirectionalExchange runs both directions', () async {
    final a = DtnBundleQueue();
    final b = DtnBundleQueue();
    a.offer(_bundle('from-a'), nowMs: 0);
    b.offer(_bundle('from-b'), nowMs: 0);

    const bidi = SimulatedBidirectionalExchange(BundleExchange());
    final (aToB, bToA) = await bidi.run(queueA: a, queueB: b, nowMs: 0);

    // aToB runs first (A hands off from-a, now empty); bToA runs second and
    // sees B holding both from-b and the just-received from-a, so it hands
    // both back — a real property of sequential same-contact runs, not a
    // bug: A ends up with both, B ends empty (last hand-off-and-forget wins).
    expect(aToB.transferred, ['from-a']);
    expect(bToA.transferred, unorderedEquals(['from-b', 'from-a']));
    expect(a.pendingCount, 2);
    expect(b.pendingCount, 0);
  });

  group('BundleExchange · consent gate', () {
    test(
      'denied consent transfers nothing and leaves both queues unchanged',
      () async {
        final a = DtnBundleQueue();
        final b = DtnBundleQueue();
        a.offer(_bundle('m1'), nowMs: 0);
        a.offer(
          _bundle('m2', priority: MeshMessagePriority.callSignal),
          nowMs: 0,
        );
        b.offer(_bundle('held'), nowMs: 0);

        for (final retain in RetainPolicy.values) {
          final report = await const BundleExchange().run(
            sender: a,
            receiver: b,
            nowMs: 0,
            retain: retain,
            consent: _FixedConsent(granted: false),
          );

          expect(report.consentDenied, isTrue);
          expect(report.transferred, isEmpty);
          expect(report.duplicates, isEmpty);
          expect(report.quotaSkipped, isEmpty);
          expect(report.interrupted, isFalse);
          expect(a.pendingCount, 2);
          expect(b.pendingCount, 1);
        }
      },
    );

    test('granted consent behaves exactly like the ungated exchange', () async {
      final a = DtnBundleQueue();
      final b = DtnBundleQueue();
      a.offer(_bundle('m1'), nowMs: 0);

      final report = await const BundleExchange().run(
        sender: a,
        receiver: b,
        nowMs: 0,
        consent: _FixedConsent(granted: true),
      );

      expect(report.consentDenied, isFalse);
      expect(report.transferred, ['m1']);
      expect(a.pendingCount, 0);
      expect(b.pendingCount, 1);
    });

    test(
      'denied consent gates both directions of a bidirectional contact',
      () async {
        final a = DtnBundleQueue();
        final b = DtnBundleQueue();
        a.offer(_bundle('from-a'), nowMs: 0);
        b.offer(_bundle('from-b'), nowMs: 0);

        const bidi = SimulatedBidirectionalExchange(BundleExchange());
        final (aToB, bToA) = await bidi.run(
          queueA: a,
          queueB: b,
          nowMs: 0,
          consent: _FixedConsent(granted: false),
        );

        expect(aToB.consentDenied, isTrue);
        expect(bToA.consentDenied, isTrue);
        expect(a.pendingCount, 1);
        expect(b.pendingCount, 1);
      },
    );
  });
}

class _FixedConsent implements DeviceLinkConsent {
  const _FixedConsent({required this.granted});

  @override
  final bool granted;
}
