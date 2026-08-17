/// Real-TLS loopback proof of multi-origin manifest discovery.
///
/// Two `HttpServer.bindSecure` origins run on 127.0.0.1 with a self-signed
/// localhost certificate (generated with the system `openssl`, mirroring
/// `server/signaling_server/lib/src/dev_certificate.dart` — SAN covers
/// DNS:localhost and IP:127.0.0.1, so hostname verification stays ACTIVE).
/// The client is the production [IoManifestFetcher] with a [SecurityContext]
/// that explicitly trusts that certificate — no badCertificateCallback
/// exists anywhere in the stack.
///
/// Matrix proved here:
///  (a) both origins up            -> fresh manifest from origin 1;
///  (b) origin 1 stopped           -> refresh succeeds via origin 2;
///  (c) origin 1 serving tampered  -> cache still ends fresh via origin 2;
///  (d) both down                  -> last-known-good within grace;
///  (e) both down, past grace      -> ManifestUnavailable.
///
/// Time is a [FakeClock] throughout; only the sockets are real.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/localhost_tls.dart';

void main() {
  late Directory tempDir;
  late SecurityContext serverContext;
  late SecurityContext clientContext;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('signed_config_tls_');
    final cert = await generateLocalhostCert(tempDir);
    serverContext = SecurityContext()
      ..useCertificateChain(cert.chainPath)
      ..usePrivateKey(cert.leafKeyPath);
    // Trusts ONLY the test CA (no system roots): explicit trust,
    // hostname verification still enforced by the TLS stack.
    clientContext = SecurityContext()..setTrustedCertificates(cert.caCertPath);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  group('IoManifestFetcher (real TLS)', () {
    late TestOrigin origin;
    late IoManifestFetcher fetcher;

    setUp(() async {
      origin = await TestOrigin.start(serverContext);
      fetcher = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
        securityContext: clientContext,
      );
    });

    tearDown(() => origin.stop());

    test('downloads served bytes over https', () async {
      origin.body = [1, 2, 3, 4];
      expect(await fetcher.fetch(origin.manifestUri), [1, 2, 3, 4]);
    });

    test('resolveAddress maps localhost to 127.0.0.1 while TLS verifies '
        'the ORIGINAL hostname (SNI + certificate)', () async {
      origin.body = [9, 8, 7];
      final resolvedHosts = <String>[];
      final mappedFetcher = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
        securityContext: clientContext,
        resolveAddress: (host) async {
          resolvedHosts.add(host);
          return host == 'localhost' ? '127.0.0.1' : null;
        },
      );

      // The server listens on 127.0.0.1 (IPv4 only); the URI names
      // "localhost". The hook routes the socket to 127.0.0.1 and the TLS
      // upgrade runs against "localhost", which the leaf SAN covers — so a
      // successful fetch proves both the mapping and standard verification.
      final bytes = await mappedFetcher.fetch(
        Uri.parse('https://localhost:${origin.port}/manifest'),
      );

      expect(bytes, [9, 8, 7]);
      expect(resolvedHosts, contains('localhost'));
    });

    test('rejects a non-https URI before any I/O', () async {
      expect(
        () => fetcher.fetch(Uri.parse('http://127.0.0.1:${origin.port}/m')),
        throwsArgumentError,
      );
      expect(origin.requestCount, 0);
    });

    test('strict TLS: an untrusting client fails the handshake', () async {
      origin.body = [1, 2, 3];
      final untrusting = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
      ); // system roots only — self-signed cert must be rejected
      await expectLater(
        untrusting.fetch(origin.manifestUri),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('declared Content-Length beyond the cap is rejected', () async {
      origin.body = List.filled(1024, 0);
      final small = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
        maxBodyBytes: 64,
        securityContext: clientContext,
      );
      await expectLater(
        small.fetch(origin.manifestUri),
        throwsA(isA<ManifestFetchException>()),
      );
    });

    test('chunked body exceeding the cap is rejected mid-stream', () async {
      origin.body = List.filled(1024, 0);
      origin.declareLength = false;
      final small = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
        maxBodyBytes: 64,
        securityContext: clientContext,
      );
      await expectLater(
        small.fetch(origin.manifestUri),
        throwsA(isA<ManifestFetchException>()),
      );
    });

    test('non-200 status is a fetch failure', () async {
      origin.body = null; // handler answers 500
      await expectLater(
        fetcher.fetch(origin.manifestUri),
        throwsA(isA<ManifestFetchException>()),
      );
    });

    test('redirect to a non-https target is refused', () async {
      origin.redirectTo = 'http://127.0.0.1:${origin.port}/manifest';
      await expectLater(
        fetcher.fetch(origin.manifestUri),
        throwsA(
          isA<ManifestFetchException>().having(
            (e) => e.message,
            'message',
            contains('must be https'),
          ),
        ),
      );
    });

    test('https-to-https redirect is followed', () async {
      final target = await TestOrigin.start(serverContext);
      addTearDown(target.stop);
      target.body = [9, 9, 9];
      origin.redirectTo = target.manifestUri.toString();

      expect(await fetcher.fetch(origin.manifestUri), [9, 9, 9]);
    });

    test('maxRedirects: 0 rejects on the very first redirect, never reaching '
        'the target', () async {
      final target = await TestOrigin.start(serverContext);
      addTearDown(target.stop);
      target.body = [9, 9, 9];
      origin.redirectTo = target.manifestUri.toString();
      final noRedirects = IoManifestFetcher(
        timeout: const Duration(seconds: 5),
        securityContext: clientContext,
        maxRedirects: 0,
      );

      await expectLater(
        noRedirects.fetch(origin.manifestUri),
        throwsA(isA<ManifestFetchException>()),
      );
      expect(
        target.requestCount,
        0,
        reason:
            'maxRedirects: 0 must fail on hop 0, before any request '
            'reaches the redirect target',
      );
    });
  });

  group('multi-origin discovery over real TLS', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;
    late FakeManifestStorage storage;
    late FakeClock clock;
    late TestOrigin origin1;
    late TestOrigin origin2;
    late ManifestCache cache;

    List<int> signedBytes(EndpointManifest manifest) =>
        encodeSignedDocument(signManifest(manifest, key1));

    EndpointManifest manifestRev(int revision) => buildManifest(
      revision: revision,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2026, 1, 1, 1),
      configServiceUris: [origin1.manifestUri, origin2.manifestUri],
    );

    setUp(() async {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      verifier = ManifestVerifier(
        pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
        crypto: crypto,
      );
      storage = FakeManifestStorage();
      clock = FakeClock(DateTime.utc(2026, 1, 1, 0, 30));
      origin1 = await TestOrigin.start(serverContext);
      origin2 = await TestOrigin.start(serverContext);
      cache = ManifestCache(
        verifier: verifier,
        storage: storage,
        fetcher: IoManifestFetcher(
          timeout: const Duration(seconds: 5),
          securityContext: clientContext,
        ).fetch,
        bootstrapUris: [origin1.manifestUri, origin2.manifestUri],
        clock: clock.call,
        config: const ManifestCacheConfig(refreshCooldown: Duration.zero),
      );
    });

    tearDown(() async {
      await origin1.stop();
      await origin2.stop();
    });

    /// Seeds the cache with revision 1 served by origin 1.
    Future<void> seed() async {
      origin1.body = signedBytes(manifestRev(1));
      final seeded = await cache.get();
      expect(seeded.freshness, ManifestFreshness.fresh);
      expect(seeded.manifest.revision, 1);
    }

    test('(a) both origins up -> fresh manifest from origin 1', () async {
      origin1.body = signedBytes(manifestRev(1));
      origin2.body = signedBytes(manifestRev(1));

      final result = await cache.get();

      expect(result.freshness, ManifestFreshness.fresh);
      expect(result.manifest.revision, 1);
      expect(origin1.requestCount, 1);
      expect(origin2.requestCount, 0, reason: 'origin 1 sufficed');
    });

    test('(b) origin 1 STOPPED -> refresh succeeds via origin 2', () async {
      await seed();
      await origin1.stop();
      origin2.body = signedBytes(manifestRev(2));

      final result = await cache.get(forceRefresh: true);

      expect(result.freshness, ManifestFreshness.fresh);
      expect(result.manifest.revision, 2);
      expect(origin2.requestCount, 1);
      expect(storage.acceptedRevision, 2);
    });

    test(
      '(c) origin 1 TAMPERED -> cache still ends fresh via origin 2',
      () async {
        await seed();
        // Origin 1 now serves revision 9 with a corrupted signature.
        origin1.body = encodeSignedDocument(
          signManifest(
            manifestRev(9),
            key1,
            signatureOverride: List.filled(64, 3),
          ),
        );
        origin2.body = signedBytes(manifestRev(2));

        final result = await cache.get(forceRefresh: true);

        expect(result.freshness, ManifestFreshness.fresh);
        expect(
          result.manifest.revision,
          2,
          reason: 'tampered rev-9 must be rejected, healthy origin 2 wins',
        );
        expect(origin2.requestCount, 1);
        expect(
          storage.acceptedRevision,
          2,
          reason: 'tampered revision must never advance the accepted floor',
        );
      },
    );

    test('(d) both origins down -> last-known-good within grace', () async {
      await seed();
      await origin1.stop();
      await origin2.stop();
      // Past the 1h validity, inside the default 7-day grace.
      clock.set(DateTime.utc(2026, 1, 2));

      final result = await cache.get();

      expect(result.freshness, ManifestFreshness.lastKnownGood);
      expect(result.manifest.revision, 1);
    });

    test('(e) both down past grace -> ManifestUnavailable', () async {
      await seed();
      await origin1.stop();
      await origin2.stop();
      // Past expiry (2026-01-01T01:00Z) + 7-day grace.
      clock.set(DateTime.utc(2026, 1, 9));

      await expectLater(cache.get(), throwsA(isA<ManifestUnavailable>()));
    });
  });
}
