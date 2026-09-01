import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 5 acceptance gate 5e, cache level.
///
/// What is pinned here:
/// - a FRESH INSTALL (no persisted floor) already carries a time floor:
///   the in-binary [embeddedTimeFloorUtc]. A document whose whole life
///   (validity window plus last-known-good grace) ended before that floor
///   is rejected even when a wound-back device clock sits inside the
///   document's own window;
/// - the lenient re-check reaches the freshly-fetched path, not only the
///   persisted-document path, and both go through the one relaxation
///   point, ManifestVerifier.verifyLenient;
/// - the re-check extends to notYetValid on the persisted path;
/// - relaxation never admits an inauthentic document.
///
/// Every instant below is DERIVED from [embeddedTimeFloorUtc], so the
/// tests keep measuring the same gate whenever a release moves the
/// constant.
void main() {
  group('5e embedded time floor + lenient re-check (cache level)', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;
    late FakeManifestStorage storage;
    late FakeFetcher fetcher;
    late FakeClock clock;
    final bootstrapUri = Uri.parse('https://bootstrap.example.com/manifest');
    final floor = embeddedTimeFloorUtc;

    ManifestCache newCache() => ManifestCache(
      verifier: verifier,
      storage: storage,
      fetcher: fetcher.call,
      bootstrapUri: bootstrapUri,
      clock: clock.call,
    );

    setUp(() {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      verifier = ManifestVerifier(
        pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
        crypto: crypto,
      );
      storage = FakeManifestStorage();
      fetcher = FakeFetcher();
      clock = FakeClock(floor);
    });

    test('5e fresh install: a document older than the embedded floor is '
        'rejected even when the device clock sits inside its window', () async {
      // The document's whole life — window plus the 7-day default
      // last-known-good grace — ended long before this build was cut.
      final issuedAt = floor.subtract(const Duration(days: 400));
      final expiresAt = issuedAt.add(const Duration(days: 7));
      final manifest = buildManifest(
        revision: 3,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );
      fetcher.enqueueSuccess(
        encodeSignedDocument(signManifest(manifest, key1)),
      );

      // A wound-back device clock, sitting comfortably inside the old
      // document's window. Without the in-binary floor this would be
      // served as fresh.
      clock.set(issuedAt.add(const Duration(days: 1)));

      final cache = newCache();
      await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));

      expect(fetcher.calls, 1, reason: 'lenient pass re-uses the bytes');
      expect(
        storage.document,
        isNull,
        reason: 'a refused document must not be persisted',
      );
      expect(storage.acceptedRevision, 0);
      expect(storage.timeFloorUtc, isNull);
    });

    test('5e fresh install: the embedded floor never rejects a document '
        'that is current relative to the floor', () async {
      final issuedAt = floor.add(const Duration(days: 1));
      final manifest = buildManifest(
        revision: 3,
        issuedAt: issuedAt,
        expiresAt: issuedAt.add(const Duration(days: 30)),
      );
      fetcher.enqueueSuccess(
        encodeSignedDocument(signManifest(manifest, key1)),
      );
      clock.set(issuedAt.add(const Duration(days: 2)));

      final result = await newCache().get();

      expect(result.freshness, ManifestFreshness.fresh);
      expect(result.manifest.revision, 3);
    });

    test(
      '5e the lenient re-check reaches the freshly-fetched path: a '
      'recently expired but authentic document is admitted as '
      'last-known-good, from the same bytes, without a second fetch',
      () async {
        final issuedAt = floor.add(const Duration(days: 10));
        final expiresAt = issuedAt.add(const Duration(days: 1));
        final manifest = buildManifest(
          revision: 4,
          issuedAt: issuedAt,
          expiresAt: expiresAt,
        );
        fetcher.enqueueSuccess(
          encodeSignedDocument(signManifest(manifest, key1)),
        );
        // One day past expiry: inside the 7-day default grace.
        clock.set(expiresAt.add(const Duration(days: 1)));

        final result = await newCache().get();

        expect(result.freshness, ManifestFreshness.lastKnownGood);
        expect(result.manifest.revision, 4);
        expect(fetcher.calls, 1, reason: 'no re-fetch for the lenient pass');
        expect(
          storage.document,
          isNotNull,
          reason: 'an admitted stale document persists for the next start',
        );
        expect(storage.acceptedRevision, 4);
        expect(
          storage.timeFloorUtc,
          issuedAt,
          reason: 'acceptance advances the persisted floor to issuedAt',
        );
      },
    );

    test('5e the lenient re-check extends to notYetValid on the persisted '
        'path: a stored document issued ahead of a lagging clock still '
        'loads at startup', () async {
      final issuedAt = floor.add(const Duration(days: 20));
      final manifest = buildManifest(
        revision: 42,
        issuedAt: issuedAt,
        expiresAt: issuedAt.add(const Duration(days: 7)),
      );
      storage.document = encodeSignedDocument(signManifest(manifest, key1));
      storage.acceptedRevision = 41;
      // Device clock lags two days behind the document's issuedAt (and
      // sits above the embedded floor, so the floor cannot repair it).
      clock.set(issuedAt.subtract(const Duration(days: 2)));

      final cache = newCache();
      await cache.initialize();

      expect(
        cache.currentRevision,
        42,
        reason:
            'before 5e only expired was relaxed at startup; a '
            'notYetValid-but-authentic document was discarded',
      );
      final result = await cache.get();
      expect(result.manifest.revision, 42);
      expect(fetcher.calls, 0, reason: 'no network needed to serve it');
    });

    test('5e relaxation on the freshly-fetched path never admits an '
        'inauthentic document, however expired', () async {
      final issuedAt = floor.add(const Duration(days: 10));
      final expiresAt = issuedAt.add(const Duration(days: 1));
      final manifest = buildManifest(
        revision: 4,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );
      fetcher.enqueueSuccess(
        encodeSignedDocument(
          signManifest(manifest, key1, signatureOverride: List.filled(64, 7)),
        ),
      );
      clock.set(expiresAt.add(const Duration(days: 1)));

      await expectLater(newCache().get(), throwsA(isA<ManifestUnavailable>()));
      expect(storage.document, isNull);
      expect(storage.acceptedRevision, 0);
    });
  });
}
