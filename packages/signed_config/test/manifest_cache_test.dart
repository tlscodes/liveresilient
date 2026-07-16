import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('ManifestCache', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;
    late FakeManifestStorage storage;
    late FakeFetcher fetcher;
    late FakeClock clock;
    final bootstrapUri = Uri.parse('https://bootstrap.example.com/manifest');

    ManifestCache newCache({ManifestCacheConfig? config}) => ManifestCache(
      verifier: verifier,
      storage: storage,
      fetcher: fetcher.call,
      bootstrapUri: bootstrapUri,
      clock: clock.call,
      config: config ?? const ManifestCacheConfig(),
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
      clock = FakeClock(DateTime.utc(2026, 1, 1, 0, 30));
    });

    test('constructor rejects a non-https bootstrap URI', () {
      expect(
        () => ManifestCache(
          verifier: verifier,
          storage: storage,
          fetcher: fetcher.call,
          bootstrapUri: Uri.parse('http://insecure.example.com'),
        ),
        throwsArgumentError,
      );
    });

    test(
      'initialize() loads a valid stored manifest without any network fetch',
      () async {
        final manifest = buildManifest(
          revision: 1,
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 1, 1, 1),
        );
        storage.document = encodeSignedDocument(signManifest(manifest, key1));
        storage.acceptedRevision = 0;

        final cache = newCache();
        await cache.initialize();

        expect(cache.currentRevision, 1);

        final result = await cache.get();
        expect(result.freshness, ManifestFreshness.fresh);
        expect(result.manifest.revision, 1);
        expect(
          fetcher.calls,
          0,
          reason: 'a fresh stored manifest needs no refetch',
        );
      },
    );

    test('initialize() accepts an expired-but-authentic stored manifest as '
        'last-known-good (grace path)', () async {
      final manifest = buildManifest(
        revision: 1,
        issuedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 1, 1, 1),
      );
      storage.document = encodeSignedDocument(signManifest(manifest, key1));
      storage.acceptedRevision = 0;

      // "Now" is well past expiresAt but within the last-known-good grace.
      clock.set(DateTime.utc(2026, 1, 1, 3, 0));
      final cache = newCache(
        config: const ManifestCacheConfig(
          lastKnownGoodGrace: Duration(days: 1),
          refreshCooldown: Duration(minutes: 5),
        ),
      );

      await cache.initialize();
      expect(
        cache.currentRevision,
        1,
        reason: 'expired-but-authentic manifest must still be adopted',
      );

      // Network is unreachable on every origin; get() must still serve
      // last-known-good. (The manifest lists two configServiceUris and the
      // refresh now fails over across all of them.)
      fetcher.enqueueFailure(Exception('network down'));
      fetcher.enqueueFailure(Exception('network down'));
      final result = await cache.get();
      expect(result.freshness, ManifestFreshness.lastKnownGood);
      expect(result.manifest.revision, 1);
    });

    test('initialize() ignores a tampered stored manifest', () async {
      final manifest = buildManifest(
        revision: 1,
        issuedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 1, 1, 1),
      );
      storage.document = encodeSignedDocument(
        signManifest(manifest, key1, signatureOverride: List.filled(64, 9)),
      );
      storage.acceptedRevision = 0;

      final cache = newCache();
      await cache.initialize();

      expect(
        cache.currentRevision,
        isNull,
        reason: 'a tampered document must never seed the in-memory cache',
      );
    });

    test(
      'get() on a fetch success updates the in-memory cache, storage and accepted revision',
      () async {
        final manifest = buildManifest(
          revision: 1,
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 1, 1, 1),
        );
        fetcher.enqueueSuccess(
          encodeSignedDocument(signManifest(manifest, key1)),
        );

        final cache = newCache();
        final result = await cache.get();

        expect(result.freshness, ManifestFreshness.fresh);
        expect(result.manifest.revision, 1);
        expect(fetcher.calls, 1);
        expect(fetcher.lastUri, bootstrapUri);
        expect(storage.acceptedRevision, 1);
        expect(storage.document, isNotNull);
      },
    );

    test(
      'get() falls back to last-known-good when a refresh fetch fails',
      () async {
        final manifest = buildManifest(
          revision: 1,
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 1, 1, 1),
        );
        fetcher.enqueueSuccess(
          encodeSignedDocument(signManifest(manifest, key1)),
        );

        final cache = newCache(
          config: const ManifestCacheConfig(
            lastKnownGoodGrace: Duration(days: 1),
            refreshCooldown: Duration(minutes: 5),
          ),
        );

        // Seed a fresh, cached manifest.
        final first = await cache.get();
        expect(first.freshness, ManifestFreshness.fresh);

        // Move past expiry (but inside grace) and past the refresh cooldown,
        // then make the network fail on both manifest-listed origins.
        clock.set(DateTime.utc(2026, 1, 1, 2, 0));
        fetcher.enqueueFailure(Exception('network down'));
        fetcher.enqueueFailure(Exception('network down'));

        final second = await cache.get();
        expect(second.freshness, ManifestFreshness.lastKnownGood);
        expect(second.manifest.revision, 1);
        expect(
          fetcher.calls,
          3,
          reason: 'seed + one failover attempt per manifest origin',
        );
      },
    );

    test(
      'get() throws ManifestUnavailable when nothing trustworthy exists and fetch fails',
      () async {
        fetcher.enqueueFailure(Exception('network down'));
        final cache = newCache();

        await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
      },
    );

    test(
      'refresh cooldown suppresses an immediate re-fetch after a failure',
      () async {
        fetcher.enqueueFailure(Exception('network down'));
        final cache = newCache(
          config: const ManifestCacheConfig(
            refreshCooldown: Duration(minutes: 5),
          ),
        );

        await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
        expect(fetcher.calls, 1);

        // Same instant: cooldown has not elapsed, so no second network call
        // is attempted even though nothing trustworthy is cached.
        await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
        expect(
          fetcher.calls,
          1,
          reason: 'refresh cooldown must suppress the retry',
        );

        // Past cooldown: a fetch is attempted again.
        clock.advance(const Duration(minutes: 6));
        fetcher.enqueueFailure(Exception('still down'));
        await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
        expect(fetcher.calls, 2);
      },
    );

    test(
      'accepted revision persists monotonically: a rollback fetch never lowers it',
      () async {
        final good = buildManifest(
          revision: 5,
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 1, 1, 6),
        );
        fetcher.enqueueSuccess(encodeSignedDocument(signManifest(good, key1)));

        final cache = newCache(
          config: const ManifestCacheConfig(
            refreshCooldown: Duration(minutes: 5),
          ),
        );
        final seeded = await cache.get();
        expect(seeded.manifest.revision, 5);
        expect(storage.acceptedRevision, 5);

        // An attacker (or misbehaving mirrors) serve an older, validly
        // signed manifest from BOTH origins on the next refresh.
        final stale = buildManifest(
          revision: 2,
          issuedAt: DateTime.utc(2026, 1, 1),
          expiresAt: DateTime.utc(2026, 1, 1, 6),
        );
        final staleBytes = encodeSignedDocument(signManifest(stale, key1));
        fetcher.enqueueSuccess(staleBytes);
        fetcher.enqueueSuccess(staleBytes);
        clock.advance(const Duration(minutes: 6)); // past cooldown, still fresh

        final result = await cache.get(forceRefresh: true);

        expect(
          result.manifest.revision,
          5,
          reason: 'rollback fetch must be rejected; last-known-good stays 5',
        );
        expect(
          storage.acceptedRevision,
          5,
          reason: 'accepted revision must never move backwards',
        );
      },
    );

    test(
      'currentRevision is null before initialize()/get() have populated anything',
      () {
        final cache = newCache();
        expect(cache.currentRevision, isNull);
      },
    );

    test('initialize() ignores corrupt (non-JSON) persisted bytes', () async {
      storage.document = utf8.encode('not a signed manifest document');
      final cache = newCache();

      await cache.initialize();

      expect(cache.currentRevision, isNull);
    });
  });

  test('ManifestUnavailable.toString() carries the message', () {
    const error = ManifestUnavailable('no network');
    expect(error.toString(), 'ManifestUnavailable: no network');
  });
}
