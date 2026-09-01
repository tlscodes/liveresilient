import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:clock/clock.dart';
import 'package:test/test.dart';

/// Ticket 3 gate 3e — rotation over the existing epoch pattern.
///
/// Two rules are pinned here, and both were adjudicated before the code was
/// written:
///
///  1. THE OVERLAP. A new epoch begins while the outgoing one is still valid.
///     Without it, rotation invalidates connections that are already in
///     flight and key hygiene turns into a scheduled outage. A maintainer who
///     does not know why the overlap exists will shorten it to zero, so the
///     cost of zero is asserted here and not only described in a comment.
///
///  2. ONE AUTHORITY. A record carries only its epoch identifier, never an
///     expiry of its own. A per-record expiry was considered and rejected:
///     each record would hold its own clock opinion and validity would have
///     two authorities able to disagree.
void main() {
  KeyPairBytes keyPair(int seed) => KeyPairBytes(
    publicKey: Uint8List.fromList(List<int>.filled(32, seed)),
    privateKey: Uint8List.fromList(List<int>.filled(32, seed + 1)),
  );

  RelayKeyRing ringAt(DateTime at, {Duration? grace}) => withClock(
    Clock.fixed(at),
    () => RelayKeyRing(
      current: RelayKeyEpoch(epoch: 1, keyPair: keyPair(1)),
      next: RelayKeyEpoch(epoch: 2, keyPair: keyPair(2)),
      gracePeriod: grace ?? const Duration(days: 1),
    ),
  );

  final t0 = DateTime.utc(2026, 1, 1);

  group('the overlap', () {
    test(
      '3e  right after a rotation both epochs are accepted, but only the new one '
      'is emitted',
      () {
        final ring = ringAt(t0);
        withClock(Clock.fixed(t0), () {
          ring.rotate(freshNext: keyPair(3));

          expect(ring.acceptsEpoch(2), isTrue, reason: 'the promoted epoch');
          expect(
            ring.acceptsEpoch(1),
            isTrue,
            reason:
                'the outgoing epoch keeps verifying arrivals, which is '
                'what stops a rotation from cutting a live connection',
          );
          expect(
            ring.emissionEpoch.epoch,
            2,
            reason: 'accept is plural during an overlap; emit never is',
          );
        });
      },
    );

    test(
      '3e  once the overlap closes the outgoing epoch stops being accepted',
      () {
        final ring = ringAt(t0);
        withClock(Clock.fixed(t0), () => ring.rotate(freshNext: keyPair(3)));

        withClock(Clock.fixed(t0.add(const Duration(hours: 23))), () {
          expect(
            ring.acceptsEpoch(1),
            isTrue,
            reason: 'still inside the window',
          );
        });
        withClock(Clock.fixed(t0.add(const Duration(days: 1, seconds: 1))), () {
          expect(ring.acceptsEpoch(1), isFalse);
          expect(ring.acceptsEpoch(2), isTrue);
        });
      },
    );

    test(
      '3e  a zero overlap is exactly the failure the parameter exists to prevent',
      () {
        final ring = ringAt(t0, grace: Duration.zero);
        withClock(Clock.fixed(t0), () => ring.rotate(freshNext: keyPair(3)));
        withClock(Clock.fixed(t0.add(const Duration(milliseconds: 1))), () {
          expect(
            ring.acceptsEpoch(1),
            isFalse,
            reason:
                'with no overlap the outgoing epoch dies the instant the '
                'rotation happens — anything in flight under it is stranded',
          );
        });
      },
    );

    test('3e  an overlap longer than an epoch is refused at construction', () {
      expect(
        () => RelayKeyRing(
          current: RelayKeyEpoch(epoch: 1, keyPair: keyPair(1)),
          epochDuration: const Duration(days: 1),
          gracePeriod: const Duration(days: 2),
        ),
        throwsA(isA<KeyRotationError>()),
      );
    });
  });

  group('one authority', () {
    test('3e  an unknown epoch is never accepted', () {
      final ring = ringAt(t0);
      withClock(Clock.fixed(t0), () {
        expect(ring.acceptsEpoch(99), isFalse);
        expect(ring.acceptsEpoch(0), isFalse);
        expect(
          ring.acceptsEpoch(2),
          isFalse,
          reason:
              'a staged next epoch is not yet acceptable — it is staged '
              'for pre-fetch, not in force',
        );
      });
    });

    test('3e  validity is answered from ring state, never from the record', () {
      final ring = ringAt(t0);
      withClock(Clock.fixed(t0), () => ring.rotate(freshNext: keyPair(3)));
      // The same epoch id answers differently at two instants, which is only
      // possible because the answer comes from the ring and not from
      // something stamped on the record.
      withClock(
        Clock.fixed(t0.add(const Duration(hours: 1))),
        () => expect(ring.acceptsEpoch(1), isTrue),
      );
      withClock(
        Clock.fixed(t0.add(const Duration(days: 2))),
        () => expect(ring.acceptsEpoch(1), isFalse),
      );
    });
  });

  group('bounded history and distribution', () {
    test('3e  history never grows past one past epoch', () {
      final ring = ringAt(t0);
      var at = t0;
      for (var i = 0; i < 5; i++) {
        at = at.add(const Duration(days: 7));
        withClock(
          Clock.fixed(at),
          () => ring.rotate(freshNext: keyPair(10 + i)),
        );
      }
      withClock(Clock.fixed(at), () {
        // Only the immediately preceding epoch can still be accepted; every
        // older one is gone regardless of how many rotations have happened.
        final accepted = <int>[
          for (var e = 1; e <= 12; e++)
            if (ring.acceptsEpoch(e)) e,
        ];
        expect(accepted.length, lessThanOrEqualTo(2));
      });
    });

    test('3e  a peer learns a new epoch from public material only', () {
      final ring = ringAt(t0);
      final announcement = withClock(Clock.fixed(t0), () => ring.announcement);
      expect(announcement.currentEpoch, 1);
      expect(announcement.currentPublicKey, keyPair(1).publicKey);
    });
  });
}
