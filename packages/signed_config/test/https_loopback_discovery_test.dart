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

/// Generates a localhost server certificate into [dir] with the system
/// `openssl` binary (dev_certificate.dart recipe, extended to a mini
/// CA-signs-leaf chain).
///
/// Unlike the wss tests — which bypass verification with
/// `badCertificateCallback` — this suite installs a real TRUST ANCHOR via
/// `setTrustedCertificates`, and the Dart/BoringSSL verifier refuses a
/// self-signed LEAF as an anchor (probed empirically: CERTIFICATE_VERIFY_
/// FAILED even with CA:TRUE on the leaf). A minimal CA that signs a
/// SAN=localhost/127.0.0.1 leaf verifies cleanly, with hostname checking
/// still active.
Future<({String caCertPath, String chainPath, String leafKeyPath})>
generateLocalhostCert(Directory dir) async {
  final p = dir.path;

  Future<void> run(List<String> args) async {
    final result = await Process.run('openssl', args);
    if (result.exitCode != 0) {
      throw StateError(
        'openssl ${args.first} failed (exit ${result.exitCode}): '
        '${result.stderr}',
      );
    }
  }

  // Mini test CA (the client's sole trust anchor).
  await run([
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    '$p/ca-key.pem',
    '-out',
    '$p/ca.pem',
    '-days',
    '30',
    '-subj',
    '/CN=signed_config loopback test CA',
    '-addext',
    'basicConstraints=critical,CA:TRUE',
    '-addext',
    'keyUsage=critical,keyCertSign',
  ]);
  // Leaf key + CSR, then CA-sign with localhost/127.0.0.1 SANs.
  await run([
    'req',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    '$p/leaf-key.pem',
    '-out',
    '$p/leaf.csr',
    '-subj',
    '/CN=localhost',
  ]);
  final extFile = File('$p/leaf.ext')
    ..writeAsStringSync(
      'subjectAltName=DNS:localhost,IP:127.0.0.1\n'
      'basicConstraints=CA:FALSE\n'
      'keyUsage=digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\n',
    );
  await run([
    'x509',
    '-req',
    '-in',
    '$p/leaf.csr',
    '-CA',
    '$p/ca.pem',
    '-CAkey',
    '$p/ca-key.pem',
    '-CAcreateserial',
    '-days',
    '30',
    '-out',
    '$p/leaf.pem',
    '-extfile',
    extFile.path,
  ]);
  // Server presents leaf + CA chain.
  final chain = File('$p/chain.pem')
    ..writeAsStringSync(
      File('$p/leaf.pem').readAsStringSync() +
          File('$p/ca.pem').readAsStringSync(),
    );

  return (
    caCertPath: '$p/ca.pem',
    chainPath: chain.path,
    leafKeyPath: '$p/leaf-key.pem',
  );
}

/// One scriptable HTTPS manifest origin on an ephemeral loopback port.
class TestOrigin {
  final HttpServer _server;
  int requestCount = 0;

  /// Body to serve; null -> HTTP 500.
  List<int>? body;

  /// When set, responds 302 to this location instead of a body.
  String? redirectTo;

  /// Declare Content-Length (true) or stream chunked (false).
  bool declareLength = true;

  /// Captured at bind time so the URI stays valid after [stop].
  final int port;

  TestOrigin._(this._server) : port = _server.port {
    _server.listen(_handle);
  }

  static Future<TestOrigin> start(SecurityContext serverContext) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    return TestOrigin._(server);
  }

  Uri get manifestUri => Uri.parse('https://127.0.0.1:$port/manifest');

  void _handle(HttpRequest request) {
    requestCount++;
    final response = request.response;
    final redirect = redirectTo;
    final bytes = body;
    if (redirect != null) {
      response.statusCode = HttpStatus.found;
      response.headers.set(HttpHeaders.locationHeader, redirect);
    } else if (bytes == null) {
      response.statusCode = HttpStatus.internalServerError;
    } else {
      if (declareLength) response.contentLength = bytes.length;
      response.add(bytes);
    }
    response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

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
