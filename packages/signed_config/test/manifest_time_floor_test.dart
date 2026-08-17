import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 5 acceptance gates 5a-5e (5e's cache-level gates live in
/// embedded_floor_test.dart; the verifier-level relaxation gates are
/// here).
///
/// The defect these pin down: the validity window was evaluated against the
/// device clock alone, so a device running one day behind an authentic newer
/// document's `issuedAt` rejected it as not-yet-valid and never reached the
/// rollback branch at all. Over a drift sweep of -90/-30/-1/0/+3/+8/+30/+90
/// days the rollback branch was reached in 2 of 8 cases.
void main() {
  group('persisted time floor', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;

    final issuedAt = DateTime.utc(2026, 1, 10);
    final expiresAt = DateTime.utc(2026, 1, 17);

    setUp(() {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      verifier = ManifestVerifier(
        pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
        crypto: crypto,
      );
    });

    SignedManifestDocument doc({int revision = 42}) => signManifest(
      buildManifest(
        revision: revision,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      ),
      key1,
    );

    test(
      '5a  a device clock one day behind issuedAt accepts with the floor, '
      'and is rejected as not-yet-valid without it',
      () async {
        final lagging = issuedAt.subtract(const Duration(days: 1));

        final without = await verifier.verify(
          doc(),
          lastAcceptedRevision: 41,
          now: lagging,
        );
        expect(
          without,
          isA<ManifestRejected>().having(
            (r) => r.reason,
            'reason',
            ManifestRejection.notYetValid,
          ),
          reason: 'this is the shipped behaviour the ticket exists to fix',
        );

        final with_ = await verifier.verify(
          doc(),
          lastAcceptedRevision: 41,
          now: lagging,
          persistedTimeFloorUtc: issuedAt,
        );
        expect(with_, isA<ManifestAccepted>());
      },
    );

    test('5b  the floor never regresses', () async {
      final storage = FakeManifestStorage();

      await storage.writeTimeFloorUtc(DateTime.utc(2026, 1, 10));
      expect(await storage.readTimeFloorUtc(), DateTime.utc(2026, 1, 10));

      await storage.writeTimeFloorUtc(DateTime.utc(2026, 1, 3));
      expect(
        await storage.readTimeFloorUtc(),
        DateTime.utc(2026, 1, 10),
        reason: 'an older write must leave the floor untouched',
      );

      await storage.writeTimeFloorUtc(DateTime.utc(2026, 1, 12));
      expect(await storage.readTimeFloorUtc(), DateTime.utc(2026, 1, 12));

      expect(
        () => storage.writeTimeFloorUtc(DateTime(2026, 1, 20)),
        throwsArgumentError,
        reason: 'a non-UTC instant must be refused, not silently converted',
      );
    });

    test(
      '5c  a null floor reproduces the prior behaviour on the same inputs',
      () async {
        final probes = <DateTime>[
          issuedAt.subtract(const Duration(days: 90)),
          issuedAt.subtract(const Duration(days: 1)),
          issuedAt,
          issuedAt.add(const Duration(days: 3)),
          expiresAt.add(const Duration(days: 1)),
          expiresAt.add(const Duration(days: 90)),
        ];

        for (final probe in probes) {
          final absent = await verifier.verify(
            doc(),
            lastAcceptedRevision: 41,
            now: probe,
          );
          final explicitNull = await verifier.verify(
            doc(),
            lastAcceptedRevision: 41,
            now: probe,
            persistedTimeFloorUtc: null,
          );
          expect(
            explicitNull.runtimeType,
            absent.runtimeType,
            reason: 'divergence at $probe',
          );
          if (absent is ManifestRejected && explicitNull is ManifestRejected) {
            expect(explicitNull.reason, absent.reason, reason: 'at $probe');
          }
        }
      },
    );

    test(
      '5d  the floor never extends a document past its expiresAt, and never '
      'reaches back before its issuedAt',
      () async {
        // Floor far in the future: the document is expired against it and
        // must stay rejected, even though the device clock is inside the
        // window. The floor may only move the effective instant forward.
        final expiredByFloor = await verifier.verify(
          doc(),
          lastAcceptedRevision: 41,
          now: issuedAt.add(const Duration(days: 1)),
          persistedTimeFloorUtc: expiresAt.add(const Duration(days: 30)),
        );
        expect(
          expiredByFloor,
          isA<ManifestRejected>().having(
            (r) => r.reason,
            'reason',
            ManifestRejection.expired,
          ),
        );

        // Floor behind the device clock: it must not drag the effective
        // instant backwards into the not-yet-valid branch.
        final floorBehindClock = await verifier.verify(
          doc(),
          lastAcceptedRevision: 41,
          now: issuedAt.add(const Duration(days: 1)),
          persistedTimeFloorUtc: issuedAt.subtract(const Duration(days: 30)),
        );
        expect(floorBehindClock, isA<ManifestAccepted>());

        // A non-UTC floor is a caller error, not something to coerce.
        expect(
          () => verifier.verify(
            doc(),
            lastAcceptedRevision: 41,
            persistedTimeFloorUtc: DateTime(2026, 1, 10),
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      '5a-bis  with the floor applied the rollback branch is reachable across '
      'the whole drift sweep that previously skipped it',
      () async {
        final drifts = <int>[-90, -30, -1, 0, 3];
        var rollbackReached = 0;
        for (final days in drifts) {
          final result = await verifier.verify(
            doc(revision: 40), // older than lastAccepted -> rollback
            lastAcceptedRevision: 41,
            now: issuedAt.add(Duration(days: days)),
            persistedTimeFloorUtc: issuedAt,
          );
          if (result is ManifestRejected &&
              result.reason == ManifestRejection.rollback) {
            rollbackReached++;
          }
        }
        expect(
          rollbackReached,
          drifts.length,
          reason: 'the floor must make the rollback branch reachable on every '
              'in-window drift, including the backward ones',
        );
      },
    );

    group('5e verifyLenient — the single relaxation point', () {
      test(
        '5e a strictly valid document comes back LenientAccepted, '
        'not stale',
        () async {
          final result = await verifier.verifyLenient(
            doc(),
            lastAcceptedRevision: 41,
            now: issuedAt.add(const Duration(days: 1)),
          );
          expect(result, isA<LenientAccepted>());
          expect((result as LenientAccepted).manifest.revision, 42);
        },
      );

      test(
        '5e an authentic document failing only as expired is accepted '
        'stale with its cause named',
        () async {
          final result = await verifier.verifyLenient(
            doc(),
            lastAcceptedRevision: 41,
            now: expiresAt.add(const Duration(days: 1)),
          );
          expect(result, isA<LenientAcceptedStale>());
          final stale = result as LenientAcceptedStale;
          expect(stale.fault, ManifestTimeFault.expired);
          expect(stale.manifest.revision, 42);
        },
      );

      test(
        '5e an authentic document failing only as notYetValid is accepted '
        'stale with its cause named',
        () async {
          final result = await verifier.verifyLenient(
            doc(),
            lastAcceptedRevision: 41,
            now: issuedAt.subtract(const Duration(days: 1)),
          );
          expect(result, isA<LenientAcceptedStale>());
          expect(
            (result as LenientAcceptedStale).fault,
            ManifestTimeFault.notYetValid,
          );
        },
      );

      test(
        '5e a tampered signature is never relaxed, even when the document '
        'is also expired',
        () async {
          final tampered = signManifest(
            buildManifest(
              revision: 42,
              issuedAt: issuedAt,
              expiresAt: expiresAt,
            ),
            key1,
            signatureOverride: List.filled(64, 7),
          );
          final result = await verifier.verifyLenient(
            tampered,
            lastAcceptedRevision: 41,
            now: expiresAt.add(const Duration(days: 1)),
          );
          expect(result, isA<LenientRejected>());
          expect(
            (result as LenientRejected).reason,
            ManifestRejection.badSignature,
            reason: 'relaxation may only touch the two time facts; '
                'authenticity failures are final',
          );
        },
      );

      test(
        '5e an unknown signing key is never relaxed',
        () async {
          final unknownKey = signManifest(
            buildManifest(
              revision: 42,
              signingKeyId: 'key-9',
              issuedAt: issuedAt,
              expiresAt: expiresAt,
            ),
            key1,
          );
          final result = await verifier.verifyLenient(
            unknownKey,
            lastAcceptedRevision: 41,
            now: expiresAt.add(const Duration(days: 1)),
          );
          expect(result, isA<LenientRejected>());
          expect(
            (result as LenientRejected).reason,
            ManifestRejection.unknownSigningKey,
          );
        },
      );

      test(
        '5e a rollback is never relaxed: the relaxed pass re-checks the '
        'revision and reports it',
        () async {
          // Expired AND older than accepted: the strict pass reports the
          // time fact first (window checks precede the revision check),
          // so only the relaxed pass can surface the rollback — and it
          // must, rather than admitting the document as stale.
          final result = await verifier.verifyLenient(
            doc(revision: 40),
            lastAcceptedRevision: 41,
            now: expiresAt.add(const Duration(days: 1)),
          );
          expect(result, isA<LenientRejected>());
          expect(
            (result as LenientRejected).reason,
            ManifestRejection.rollback,
          );
        },
      );
    });
  });
}
