import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

CustodyBundle bundle(
  String id, {
  String dest = 'peer-b',
  int at = 0,
  int life = 60000,
  int hops = 0,
  int bytes = 10,
}) => CustodyBundle(
  bundleId: id,
  destination: dest,
  payload: List.filled(bytes, 1),
  acceptedAtMs: at,
  lifetimeMs: life,
  hopCount: hops,
);

void main() {
  group('CarrierRelay · custody', () {
    test('accepts, matches destination on contact, frees on handover', () {
      final relay = CarrierRelay();
      expect(relay.accept(bundle('m1'), nowMs: 0), isNull);
      expect(relay.accept(bundle('m2', dest: 'peer-c'), nowMs: 0), isNull);

      final forB = relay.bundlesFor('peer-b', nowMs: 1000);
      expect(forB.map((b) => b.bundleId), ['m1']);
      relay.handedOver('m1');
      expect(relay.heldCount, 1);
      expect(relay.bundlesFor('peer-b', nowMs: 1000), isEmpty);
    });

    test('oldest-carried hands over first (fairness)', () {
      final relay = CarrierRelay();
      relay.accept(bundle('new', at: 5000), nowMs: 5000);
      relay.accept(bundle('old', at: 0, life: 99000), nowMs: 5000);
      expect(relay.bundlesFor('peer-b', nowMs: 6000).first.bundleId, 'old');
    });

    test('refuses duplicates, expired, hop-exhausted and over-capacity', () {
      final relay = CarrierRelay(capacityBundles: 2, maxHops: 3);
      expect(relay.accept(bundle('m1'), nowMs: 0), isNull);
      expect(relay.accept(bundle('m1'), nowMs: 0), CustodyRefusal.duplicate);
      expect(
        relay.accept(bundle('m2', life: 10), nowMs: 50),
        CustodyRefusal.expired,
      );
      expect(
        relay.accept(bundle('m3', hops: 3), nowMs: 0),
        CustodyRefusal.tooManyHops,
      );
      relay.accept(bundle('m4'), nowMs: 0);
      expect(relay.accept(bundle('m5'), nowMs: 0), CustodyRefusal.storeFull);
    });

    test('byte capacity is enforced independently of bundle count', () {
      final relay = CarrierRelay(capacityBytes: 25);
      relay.accept(bundle('big', bytes: 20), nowMs: 0);
      expect(
        relay.accept(bundle('big2', bytes: 10), nowMs: 0),
        CustodyRefusal.storeFull,
      );
    });

    test('handover to the next hop decays lifetime and counts the hop', () {
      final b = bundle('m1', at: 0, life: 60000).nextHop(10000);
      expect(b.hopCount, 1);
      expect(b.lifetimeMs, 50000);
      expect(b.acceptedAtMs, 10000);
    });

    test('prune drops expired custody; restore skips expired rows', () {
      final relay = CarrierRelay();
      relay.accept(bundle('live', life: 99000), nowMs: 0);
      relay.accept(bundle('dying', life: 1000), nowMs: 0);
      expect(relay.prune(nowMs: 5000), 1);

      final reborn = CarrierRelay()..restore(relay.toJson(), nowMs: 5000);
      expect(reborn.heldCount, 1);
      expect(reborn.bundlesFor('peer-b', nowMs: 5000).single.bundleId, 'live');
    });

    test('spray phase: binary split halves the copy budget both sides', () {
      final relay = CarrierRelay();
      relay.accept(
        CustodyBundle(
          bundleId: 'viral',
          destination: 'peer-z',
          payload: [1],
          acceptedAtMs: 0,
          lifetimeMs: 60000,
          copies: 8,
        ),
        nowMs: 0,
      );
      final given = relay.spraySplit('viral', nowMs: 1000);
      expect(given.copies, 4);
      expect(
        relay.sprayPlanFor({}, nowMs: 1000).single.copies,
        4,
        reason: 'we kept the other half',
      );
      // Split down to 1 → wait phase: no longer offered to relays.
      relay.spraySplit('viral', nowMs: 2000); // 4 -> keep 2
      relay.spraySplit('viral', nowMs: 3000); // 2 -> keep 1
      expect(relay.sprayPlanFor({}, nowMs: 3000), isEmpty);
      expect(
        relay.bundlesFor('peer-z', nowMs: 3000),
        isNotEmpty,
        reason: 'wait phase still delivers direct to the destination',
      );
    });

    test('summary vector stops redundant bytes on repeat contact', () {
      final relay = CarrierRelay();
      relay.accept(bundle('m1', hops: 0), nowMs: 0);
      final withCopies = CustodyBundle(
        bundleId: 'm9',
        destination: 'peer-b',
        payload: [1],
        acceptedAtMs: 0,
        lifetimeMs: 60000,
        copies: 4,
      );
      relay.accept(withCopies, nowMs: 0);
      expect(relay.sprayPlanFor({}, nowMs: 0).single.bundleId, 'm9');
      expect(
        relay.sprayPlanFor({'m9'}, nowMs: 0),
        isEmpty,
        reason: 'peer already has it — zero bytes moved',
      );
      expect(relay.summaryVector(), containsAll(['m1', 'm9']));
    });

    test('per-peer quota keeps one chatty peer from filling the store', () {
      final relay = CarrierRelay(maxAcceptPerPeer: 2);
      expect(relay.accept(bundle('a1'), nowMs: 0, fromPeer: 'chatty'), isNull);
      expect(relay.accept(bundle('a2'), nowMs: 0, fromPeer: 'chatty'), isNull);
      expect(
        relay.accept(bundle('a3'), nowMs: 0, fromPeer: 'chatty'),
        CustodyRefusal.peerQuota,
      );
      expect(
        relay.accept(bundle('b1'), nowMs: 0, fromPeer: 'polite'),
        isNull,
        reason: 'other peers unaffected',
      );
    });

    test('a full custody chain relays sender→carrier→recipient', () {
      // Sender meets carrier at t=0; carrier meets recipient at t=8h.
      final carrier = CarrierRelay();
      final fromSender = bundle('letter', life: 24 * 3600 * 1000);
      expect(carrier.accept(fromSender, nowMs: 0), isNull);

      final atNight = 8 * 3600 * 1000;
      final toHand = carrier.bundlesFor('peer-b', nowMs: atNight);
      expect(toHand.single.bundleId, 'letter');
      final handed = toHand.single.nextHop(atNight);
      carrier.handedOver('letter');

      expect(handed.hopCount, 1);
      expect(handed.expired(atNight), isFalse);
      expect(carrier.heldCount, 0);
    });
  });
}
