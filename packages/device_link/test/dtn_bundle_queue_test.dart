/// Delay-tolerant store-and-forward queue: lifetime expiry, de-dup,
/// priority/arrival delivery order, capacity shedding (lowest priority
/// then oldest), and flush-on-transport-up with mid-flush failure.
library;

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

DtnBundle bundle(
  String id, {
  LinkMessagePriority priority = LinkMessagePriority.bulk,
  int createdAtMs = 0,
  int lifetimeMs = 60000,
  int sizeBytes = 4,
}) => DtnBundle(
  id: id,
  payload: List<int>.filled(sizeBytes, 1),
  priority: priority,
  createdAtMs: createdAtMs,
  lifetimeMs: lifetimeMs,
);

void main() {
  group('offer admission', () {
    test('stores a fresh bundle and reports it pending', () {
      final q = DtnBundleQueue();
      expect(q.offer(bundle('a'), nowMs: 0), BundleAdmission.stored);
      expect(q.pendingCount, 1);
      expect(q.pendingBytes, 4);
    });

    test('a duplicate id is ignored while the original is live', () {
      final q = DtnBundleQueue();
      q.offer(bundle('a'), nowMs: 0);
      expect(q.offer(bundle('a'), nowMs: 10), BundleAdmission.duplicate);
      expect(q.pendingCount, 1);
    });

    test('a bundle already past its lifetime at offer time is not stored', () {
      final q = DtnBundleQueue();
      expect(
        q.offer(bundle('a', lifetimeMs: 100), nowMs: 500),
        BundleAdmission.expired,
      );
      expect(q.pendingCount, 0);
    });
  });

  group('lifetime expiry', () {
    test('purgeExpired drops only bundles past their lifetime', () {
      final q = DtnBundleQueue();
      q.offer(bundle('short', lifetimeMs: 100), nowMs: 0);
      q.offer(bundle('long', lifetimeMs: 10000), nowMs: 0);
      expect(q.purgeExpired(200), 1);
      expect(q.pendingCount, 1);
      expect(q.pendingInDeliveryOrder(200).single.id, 'long');
    });
  });

  group('delivery order', () {
    test('highest priority first, oldest first within a priority', () {
      final q = DtnBundleQueue();
      q.offer(
        bundle('bulk-old', priority: LinkMessagePriority.bulk, createdAtMs: 1),
        nowMs: 1,
      );
      q.offer(
        bundle(
          'signal',
          priority: LinkMessagePriority.callSignal,
          createdAtMs: 5,
        ),
        nowMs: 5,
      );
      q.offer(
        bundle(
          'presence',
          priority: LinkMessagePriority.presence,
          createdAtMs: 3,
        ),
        nowMs: 3,
      );
      q.offer(
        bundle('bulk-new', priority: LinkMessagePriority.bulk, createdAtMs: 2),
        nowMs: 2,
      );

      expect(q.pendingInDeliveryOrder(10).map((b) => b.id).toList(), [
        'signal',
        'presence',
        'bulk-old',
        'bulk-new',
      ]);
    });
  });

  group('capacity shedding', () {
    test('at count capacity a higher-priority arrival evicts the weakest '
        'resident; a lower-priority arrival is refused instead', () {
      final q = DtnBundleQueue(maxBundles: 2);
      q.offer(bundle('b1', priority: LinkMessagePriority.bulk), nowMs: 0);
      q.offer(bundle('b2', priority: LinkMessagePriority.bulk), nowMs: 0);

      // callSignal arrives full: it evicts a bulk resident.
      expect(
        q.offer(
          bundle('sig', priority: LinkMessagePriority.callSignal),
          nowMs: 0,
        ),
        BundleAdmission.stored,
      );
      expect(q.pendingCount, 2);
      expect(q.pendingInDeliveryOrder(0).map((b) => b.id), contains('sig'));

      // Now the queue holds {sig(callSignal), one bulk}. Another bulk that
      // is not more important than the weakest resident is refused.
      final weakest = q
          .pendingInDeliveryOrder(0)
          .where((b) => b.priority == LinkMessagePriority.bulk)
          .length;
      expect(weakest, 1);
      // fill so both slots are callSignal, then a bulk must be refused.
      q.offer(
        bundle('sig2', priority: LinkMessagePriority.callSignal),
        nowMs: 0,
      );
      expect(
        q.offer(bundle('late', priority: LinkMessagePriority.bulk), nowMs: 0),
        BundleAdmission.rejectedFull,
      );
    });

    test('byte capacity sheds the same way', () {
      final q = DtnBundleQueue(maxBundles: 100, maxBytes: 10);
      expect(
        q.offer(bundle('a', sizeBytes: 6), nowMs: 0),
        BundleAdmission.stored,
      );
      // 6 + 6 > 10 → must evict 'a' (same priority, and it's oldest).
      expect(
        q.offer(bundle('b', sizeBytes: 6, createdAtMs: 1), nowMs: 1),
        BundleAdmission.stored,
      );
      expect(q.pendingCount, 1);
      expect(q.pendingBytes, 6);
      expect(q.pendingInDeliveryOrder(1).single.id, 'b');
    });
  });

  group('flush', () {
    test('flushes in delivery order, removes forwarded bundles, and stops on '
        'the first failure (transport dropped again)', () async {
      final q = DtnBundleQueue();
      q.offer(
        bundle('bulk', priority: LinkMessagePriority.bulk, createdAtMs: 1),
        nowMs: 1,
      );
      q.offer(
        bundle(
          'signal',
          priority: LinkMessagePriority.callSignal,
          createdAtMs: 2,
        ),
        nowMs: 2,
      );
      q.offer(
        bundle(
          'presence',
          priority: LinkMessagePriority.presence,
          createdAtMs: 3,
        ),
        nowMs: 3,
      );

      final forwarded = <String>[];
      // Transport carries the first two, then drops.
      final delivered = await q.flush((b) async {
        forwarded.add(b.id);
        return forwarded.length <= 2;
      }, nowMs: 10);

      expect(delivered, 2);
      // All three are attempted in priority order; the third's hand-off
      // fails, so it is not counted and stays queued.
      expect(forwarded, ['signal', 'presence', 'bulk']);
      expect(q.pendingInDeliveryOrder(10).map((b) => b.id), ['bulk']);
    });

    test('expired bundles are dropped by flush, never delivered', () async {
      final q = DtnBundleQueue();
      q.offer(bundle('dead', lifetimeMs: 100), nowMs: 0);
      q.offer(bundle('alive', lifetimeMs: 10000, createdAtMs: 0), nowMs: 0);

      final forwarded = <String>[];
      final delivered = await q.flush((b) async {
        forwarded.add(b.id);
        return true;
      }, nowMs: 500);

      expect(delivered, 1);
      expect(forwarded, ['alive']);
      expect(q.pendingCount, 0);
    });

    test('a forwarder that throws counts as a failed hand-off: the thrower '
        'and later bundles stay queued, and a retry delivers each exactly '
        'once', () async {
      final q = DtnBundleQueue();
      q.offer(
        bundle('one', priority: LinkMessagePriority.callSignal, createdAtMs: 1),
        nowMs: 1,
      );
      q.offer(
        bundle('two', priority: LinkMessagePriority.presence, createdAtMs: 2),
        nowMs: 2,
      );
      q.offer(
        bundle('three', priority: LinkMessagePriority.bulk, createdAtMs: 3),
        nowMs: 3,
      );

      final forwarded = <String>[];
      final delivered = await q.flush((b) async {
        forwarded.add(b.id);
        if (b.id == 'two') throw StateError('transport blew up');
        return true;
      }, nowMs: 10);

      expect(delivered, 1);
      expect(forwarded, ['one', 'two']);
      expect(q.pendingInDeliveryOrder(10).map((b) => b.id), ['two', 'three']);

      // Retry: the thrower now succeeds, and nothing is re-delivered.
      final retryForwarded = <String>[];
      final retryDelivered = await q.flush((b) async {
        retryForwarded.add(b.id);
        return true;
      }, nowMs: 20);

      expect(retryDelivered, 2);
      expect(retryForwarded, ['two', 'three']);
      expect(q.pendingCount, 0);
    });
  });

  group('validation', () {
    test('bad bundle and queue parameters throw', () {
      expect(() => bundle('', lifetimeMs: 1), throwsArgumentError);
      expect(
        () => DtnBundle(
          id: 'x',
          payload: const [],
          priority: LinkMessagePriority.bulk,
          createdAtMs: 0,
          lifetimeMs: 1,
        ),
        throwsArgumentError,
      );
      expect(() => DtnBundleQueue(maxBundles: 0), throwsArgumentError);
      expect(() => DtnBundleQueue(maxBytes: 0), throwsArgumentError);
    });
  });
}
