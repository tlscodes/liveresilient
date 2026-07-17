/// Multi-origin failover matrix at the FakeFetcher level (no sockets).
///
/// Phase-7 exit gate under test: a failure or tampered/rejected response
/// from origin 1 must neither be accepted nor stop origin 2 from serving a
/// healthy manifest.
library;

import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Per-URI routing fetcher: each origin has its own response queue.
/// Throws [StateError] on an unrouted/exhausted origin so under-provisioned
/// tests fail loudly (an Error deliberately escapes per-origin isolation).
class RoutedFetcher {
  final Map<Uri, List<Object>> _routes = {};
  final List<Uri> requested = [];

  void enqueue(Uri origin, Object bytesOrError) =>
      _routes.putIfAbsent(origin, () => []).add(bytesOrError);

  Future<List<int>> call(Uri uri) async {
    requested.add(uri);
    final queue = _routes[uri];
    if (queue == null || queue.isEmpty) {
      throw StateError('RoutedFetcher: no queued response for $uri');
    }
    final next = queue.removeAt(0);
    if (next is List<int>) return next;
    throw next;
  }
}

void main() {
  late FakeEd25519Verifier crypto;
  late Uint8List key1;
  late ManifestVerifier verifier;
  late FakeManifestStorage storage;
  late RoutedFetcher fetcher;
  late FakeClock clock;

  // Must match buildManifest() defaults: after the first accepted manifest,
  // refresh candidates are exactly these two, in order.
  final origin1 = Uri.parse('https://config.example.com/manifest');
  final origin2 = Uri.parse('https://config-alt.example.net/manifest');
  final bootstrap1 = Uri.parse('https://boot-1.example.com/manifest');
  final bootstrap2 = Uri.parse('https://boot-2.example.com/manifest');

  ManifestCache newCache({
    List<Uri>? bootstrapUris,
    ManifestCacheConfig? config,
  }) => ManifestCache(
    verifier: verifier,
    storage: storage,
    fetcher: fetcher.call,
    bootstrapUris: bootstrapUris ?? [bootstrap1, bootstrap2],
    clock: clock.call,
    config: config ?? const ManifestCacheConfig(refreshCooldown: Duration.zero),
  );

  List<int> signedBytes(EndpointManifest manifest) =>
      encodeSignedDocument(signManifest(manifest, key1));

  List<int> tamperedBytes(EndpointManifest manifest) => encodeSignedDocument(
    signManifest(manifest, key1, signatureOverride: List.filled(64, 7)),
  );

  setUp(() {
    crypto = FakeEd25519Verifier();
    key1 = keyBytes(1);
    verifier = ManifestVerifier(
      pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
      crypto: crypto,
    );
    storage = FakeManifestStorage();
    fetcher = RoutedFetcher();
    clock = FakeClock(DateTime.utc(2026, 1, 1, 0, 30));
  });

  group('ManifestCache constructor (multi-origin API)', () {
    test('rejects neither / both bootstrap parameters', () {
      expect(() => newCache(bootstrapUris: null), isNot(throwsArgumentError));
      expect(
        () => ManifestCache(
          verifier: verifier,
          storage: storage,
          fetcher: fetcher.call,
        ),
        throwsArgumentError,
      );
      expect(
        () => ManifestCache(
          verifier: verifier,
          storage: storage,
          fetcher: fetcher.call,
          bootstrapUri: bootstrap1,
          bootstrapUris: [bootstrap2],
        ),
        throwsArgumentError,
      );
    });

    test('rejects an empty bootstrap list', () {
      expect(() => newCache(bootstrapUris: []), throwsArgumentError);
    });

    test('rejects a non-https URI anywhere in the bootstrap list', () {
      expect(
        () => newCache(
          bootstrapUris: [
            bootstrap1,
            Uri.parse('http://insecure.example.com/manifest'),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('single bootstrapUri convenience parameter still works', () async {
      fetcher.enqueue(bootstrap1, signedBytes(buildManifest(revision: 1)));
      final cache = ManifestCache(
        verifier: verifier,
        storage: storage,
        fetcher: fetcher.call,
        bootstrapUri: bootstrap1,
        clock: clock.call,
      );
      final result = await cache.get();
      expect(result.manifest.revision, 1);
      expect(fetcher.requested, [bootstrap1]);
    });
  });

  group('bootstrap-list failover (no manifest yet)', () {
    test('first bootstrap origin down -> second serves the manifest', () async {
      fetcher.enqueue(bootstrap1, Exception('connection refused'));
      fetcher.enqueue(bootstrap2, signedBytes(buildManifest(revision: 1)));

      final result = await newCache().get();

      expect(result.freshness, ManifestFreshness.fresh);
      expect(result.manifest.revision, 1);
      expect(fetcher.requested, [bootstrap1, bootstrap2]);
      expect(storage.acceptedRevision, 1);
    });

    test('all bootstrap origins down -> ManifestUnavailable', () async {
      fetcher.enqueue(bootstrap1, Exception('down'));
      fetcher.enqueue(bootstrap2, Exception('down'));

      await expectLater(newCache().get(), throwsA(isA<ManifestUnavailable>()));
      expect(fetcher.requested, [bootstrap1, bootstrap2]);
    });
  });

  group('manifest-origin failover (configServiceUris)', () {
    Future<ManifestCache> seededCache({int revision = 1}) async {
      fetcher.enqueue(
        bootstrap1,
        signedBytes(buildManifest(revision: revision)),
      );
      final cache = newCache();
      await cache.get();
      fetcher.requested.clear();
      return cache;
    }

    test(
      'both origins healthy -> origin 1 wins, origin 2 never contacted',
      () async {
        final cache = await seededCache();
        fetcher.enqueue(origin1, signedBytes(buildManifest(revision: 2)));

        final result = await cache.get(forceRefresh: true);

        expect(result.manifest.revision, 2);
        expect(fetcher.requested, [origin1]);
      },
    );

    test('origin 1 network failure -> origin 2 serves the refresh', () async {
      final cache = await seededCache();
      fetcher.enqueue(origin1, Exception('origin 1 unreachable'));
      fetcher.enqueue(origin2, signedBytes(buildManifest(revision: 2)));

      final result = await cache.get(forceRefresh: true);

      expect(result.freshness, ManifestFreshness.fresh);
      expect(result.manifest.revision, 2);
      expect(fetcher.requested, [origin1, origin2]);
      expect(storage.acceptedRevision, 2);
    });

    test(
      'EXIT GATE: tampered origin 1 is rejected AND origin 2 still serves',
      () async {
        final cache = await seededCache();
        fetcher.enqueue(origin1, tamperedBytes(buildManifest(revision: 9)));
        fetcher.enqueue(origin2, signedBytes(buildManifest(revision: 2)));

        final result = await cache.get(forceRefresh: true);

        expect(
          result.manifest.revision,
          2,
          reason: 'tampered rev-9 must never be accepted',
        );
        expect(fetcher.requested, [origin1, origin2]);
        expect(
          storage.acceptedRevision,
          2,
          reason: 'accepted revision follows the verified origin only',
        );
      },
    );

    test('malformed (non-document) bytes from origin 1 fall through', () async {
      final cache = await seededCache();
      fetcher.enqueue(origin1, 'not json'.codeUnits);
      fetcher.enqueue(origin2, signedBytes(buildManifest(revision: 2)));

      final result = await cache.get(forceRefresh: true);
      expect(result.manifest.revision, 2);
      expect(fetcher.requested, [origin1, origin2]);
    });

    test(
      'rollback rejection on origin 1 falls through to a newer origin 2',
      () async {
        final cache = await seededCache(revision: 5);
        fetcher.enqueue(origin1, signedBytes(buildManifest(revision: 3)));
        fetcher.enqueue(origin2, signedBytes(buildManifest(revision: 6)));

        final result = await cache.get(forceRefresh: true);

        expect(result.manifest.revision, 6);
        expect(fetcher.requested, [origin1, origin2]);
        expect(storage.acceptedRevision, 6);
      },
    );

    test('authentic-but-older (yet >= accepted) origin 1 wins by order — '
        'documented acceptable behavior', () async {
      final cache = await seededCache(revision: 5);
      // Origin 1 re-serves the already-accepted revision 5; origin 2 has 6.
      fetcher.enqueue(origin1, signedBytes(buildManifest(revision: 5)));

      final result = await cache.get(forceRefresh: true);

      expect(result.manifest.revision, 5);
      expect(
        fetcher.requested,
        [origin1],
        reason: 'first verified winner: origin 2 is not consulted',
      );
      expect(storage.acceptedRevision, 5);
    });

    test('all origins failing -> last-known-good within grace', () async {
      final cache = await seededCache();
      // Past expiry (manifest is valid 1h from 2026-01-01T00:00Z), inside
      // the default 7-day grace.
      clock.set(DateTime.utc(2026, 1, 1, 3));
      fetcher.enqueue(origin1, Exception('down'));
      fetcher.enqueue(origin2, tamperedBytes(buildManifest(revision: 8)));

      final result = await cache.get();

      expect(result.freshness, ManifestFreshness.lastKnownGood);
      expect(result.manifest.revision, 1);
      expect(fetcher.requested, [origin1, origin2]);
    });

    test('all origins failing past grace -> ManifestUnavailable', () async {
      final cache = await seededCache();
      clock.set(DateTime.utc(2026, 1, 9));
      fetcher.enqueue(origin1, Exception('down'));
      fetcher.enqueue(origin2, Exception('down'));

      await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
    });

    test(
      'concurrent refreshes still coalesce into one failover pass',
      () async {
        final cache = await seededCache();
        fetcher.enqueue(origin1, signedBytes(buildManifest(revision: 2)));

        final results = await Future.wait([
          cache.get(forceRefresh: true),
          cache.get(forceRefresh: true),
          cache.get(forceRefresh: true),
        ]);

        expect(results.map((r) => r.manifest.revision), everyElement(2));
        expect(
          fetcher.requested,
          [origin1],
          reason: 'single-flight: one network pass for concurrent callers',
        );
      },
    );
  });

  group('fetchVerifiedManifest helper', () {
    test('empty origin list throws ArgumentError', () {
      expect(
        () => fetchVerifiedManifest(
          origins: const [],
          fetch: fetcher.call,
          verifier: verifier,
          lastAcceptedRevision: 0,
          now: clock(),
        ),
        throwsArgumentError,
      );
    });

    test('aggregate exception lists every origin failure in order', () async {
      fetcher.enqueue(origin1, Exception('boom-1'));
      fetcher.enqueue(origin2, tamperedBytes(buildManifest(revision: 2)));

      try {
        await fetchVerifiedManifest(
          origins: [origin1, origin2],
          fetch: fetcher.call,
          verifier: verifier,
          lastAcceptedRevision: 0,
          now: clock(),
        );
        fail('expected MultiOriginRefreshException');
      } on MultiOriginRefreshException catch (error) {
        expect(error.failures, hasLength(2));
        expect(error.failures[0].origin, origin1);
        expect(error.failures[0].reason, contains('boom-1'));
        expect(error.failures[1].origin, origin2);
        expect(error.failures[1].reason, contains('badSignature'));
        expect(error.toString(), contains('all 2 origin(s) failed'));
      }
    });

    test('staggered racing: fastest healthy origin wins over a slow '
        'origin 1 still in flight', () async {
      final requested = <Uri>[];
      Future<List<int>> fetch(Uri uri) async {
        requested.add(uri);
        if (uri == origin1) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return signedBytes(buildManifest(revision: 2));
        }
        return signedBytes(buildManifest(revision: 3));
      }

      final result = await fetchVerifiedManifest(
        origins: [origin1, origin2],
        fetch: fetch,
        verifier: verifier,
        lastAcceptedRevision: 0,
        now: clock(),
        staggerDelay: const Duration(milliseconds: 50),
      );

      expect(result.manifest.revision, 3, reason: 'origin 2 finished first');
      expect(requested, [
        origin1,
        origin2,
      ], reason: 'both origins were racing in flight');
    });

    test('healthy origin 1 answers within the stagger window: '
        'origin 2 is never fetched', () async {
      final requested = <Uri>[];
      Future<List<int>> fetch(Uri uri) async {
        requested.add(uri);
        return signedBytes(buildManifest(revision: 2));
      }

      final result = await fetchVerifiedManifest(
        origins: [origin1, origin2],
        fetch: fetch,
        verifier: verifier,
        lastAcceptedRevision: 0,
        now: clock(),
      );

      expect(result.manifest.revision, 2);
      expect(requested, [origin1]);
    });

    test('fast failure of origin 1 launches origin 2 immediately, '
        'without waiting out the stagger', () async {
      final requested = <Uri>[];
      Future<List<int>> fetch(Uri uri) async {
        requested.add(uri);
        if (uri == origin1) throw Exception('down');
        return signedBytes(buildManifest(revision: 2));
      }

      final stopwatch = Stopwatch()..start();
      final result = await fetchVerifiedManifest(
        origins: [origin1, origin2],
        fetch: fetch,
        verifier: verifier,
        lastAcceptedRevision: 0,
        now: clock(),
        staggerDelay: const Duration(seconds: 2),
      );
      stopwatch.stop();

      expect(result.manifest.revision, 2);
      expect(requested, [origin1, origin2]);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason:
            'early start: an all-started-failed state wakes the next '
            'origin instead of sleeping the full stagger',
      );
    });

    test('rejected slow origin 1 does not block a verified origin 2 winner '
        'racing in parallel', () async {
      final requested = <Uri>[];
      Future<List<int>> fetch(Uri uri) async {
        requested.add(uri);
        if (uri == origin1) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return tamperedBytes(buildManifest(revision: 9));
        }
        return signedBytes(buildManifest(revision: 4));
      }

      final result = await fetchVerifiedManifest(
        origins: [origin1, origin2],
        fetch: fetch,
        verifier: verifier,
        lastAcceptedRevision: 0,
        now: clock(),
        staggerDelay: const Duration(milliseconds: 50),
      );

      expect(result.manifest.revision, 4);
      expect(requested, [origin1, origin2]);
    });
  });
}
