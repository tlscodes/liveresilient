import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/broadcast_wiring.dart';

/// A loopback stand-in for the border relay's broadcast routes.
///
/// Enough of the real worker's contract to exercise the client: immutable
/// reads, write-once with a 409 on a conflicting rewrite, 404 for an
/// address that holds nothing. Nothing here ever leaves the machine.
class _LoopbackRelay {
  _LoopbackRelay(this._server) {
    _server.listen(_handle);
  }

  static Future<_LoopbackRelay> start() async =>
      _LoopbackRelay(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, Uint8List> _stored = {};

  /// Request headers seen per written path, so a test can check what the
  /// client actually put on the wire.
  final Map<String, Map<String, String?>> _headers = {};

  Map<String, String?>? headersFor(String path) => _headers[path];

  /// Paths this server will answer 500 for, to model a broken relay.
  final Set<String> failing = {};

  /// Extra bytes appended to every response body, to model a relay that
  /// serves something other than what was asked for.
  bool tamper = false;

  Uri get origin =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port);

  int get storedCount => _stored.length;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (failing.contains(path)) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      return;
    }
    if (request.method == 'PUT') {
      _headers[path] = {
        broadcastAuthHeader: request.headers.value(broadcastAuthHeader),
      };
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      final held = _stored[path];
      final bytes = Uint8List.fromList(body);
      if (held != null) {
        request.response.statusCode = bytesEqual(held, bytes)
            ? HttpStatus.noContent
            : HttpStatus.conflict;
      } else {
        _stored[path] = bytes;
        request.response.statusCode = HttpStatus.created;
      }
      await request.response.close();
      return;
    }
    final held = _stored[path];
    if (held == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set('cache-control', immutableCacheControl);
    request.response.add(tamper ? [...held, 0xFF] : held);
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 12);

  group('relay origins from the environment', () {
    test('falls back to the deployed relay when nothing is set', () {
      final origins = broadcastRelayOrigins(const {});
      expect(origins, hasLength(1));
      expect(origins.single.scheme, 'https');
      expect(origins.single.host, contains('voice-call-relay'));
    });

    test('an empty or blank value falls back too', () {
      expect(
        broadcastRelayOrigins(const {broadcastRelaysVariable: '   '}),
        broadcastRelayOrigins(const {}),
      );
    });

    test('reads a comma-separated list in preference order', () {
      final origins = broadcastRelayOrigins(const {
        broadcastRelaysVariable: 'https://a.example, https://b.example:8443',
      });
      expect(origins.map((u) => u.toString()), [
        'https://a.example',
        'https://b.example:8443',
      ]);
    });

    test('a path or query on a configured origin is discarded', () {
      final origins = broadcastRelayOrigins(const {
        broadcastRelaysVariable: 'https://a.example/some/path?x=1',
      });
      expect(origins.single.toString(), 'https://a.example');
    });

    test('one unusable entry costs that relay, not the list', () {
      // A typo in a deployment variable should not take every relay down
      // with it.
      final origins = broadcastRelayOrigins(const {
        broadcastRelaysVariable: 'ftp://a.example,,not a url,https://b.example',
      });
      expect(origins.map((u) => u.host), ['b.example']);
    });

    test('a list of nothing usable falls back to the default', () {
      expect(
        broadcastRelayOrigins(const {
          broadcastRelaysVariable: 'ftp://a.example,gopher://b.example',
        }),
        broadcastRelayOrigins(const {}),
      );
    });

    test('builds one relay client per origin, named by host', () {
      final relays = broadcastRelaysFromEnvironment(const {
        broadcastRelaysVariable: 'https://a.example,https://b.example',
      });
      expect(relays.map((r) => r.name), ['a.example', 'b.example']);
    });
  });

  group('resolving relays across the three sources', () {
    const verifier = CryptographyBroadcastVerifier();
    const environment = {broadcastRelaysVariable: 'https://from-env.example'};

    late CryptographyBroadcastSigner root;

    setUp(() async => root = await CryptographyBroadcastSigner.generate());

    Future<RelayDirectoryStore> storeWith({
      required List<Uri> origins,
      int seq = 1,
      Duration validity = const Duration(days: 30),
    }) async {
      final directory = await RelayDirectory.issue(
        rootSigner: root,
        origins: origins,
        seq: seq,
        notAfter: t0.add(validity),
      );
      final store = RelayDirectoryStore();
      expect(
        await store.adopt(
          encoded: directory.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
        ),
        isTrue,
      );
      return store;
    }

    test('a signed directory outranks the environment', () async {
      // The author's own statement of where they publish beats an operator
      // variable, and unlike that variable it can reach a cut-off device.
      final store = await storeWith(
        origins: [Uri.parse('https://from-directory.example')],
      );
      final origins = resolveBroadcastRelayOrigins(
        environment: environment,
        now: t0,
        directory: store,
      );
      expect(origins.single.host, 'from-directory.example');
    });

    test('an expired directory falls back to the environment', () async {
      final store = await storeWith(
        origins: [Uri.parse('https://from-directory.example')],
        validity: const Duration(days: 2),
      );
      final origins = resolveBroadcastRelayOrigins(
        environment: environment,
        now: t0.add(const Duration(days: 2, seconds: 1)),
        directory: store,
      );
      expect(origins.single.host, 'from-env.example');
    });

    test('no directory at all falls back to the environment', () {
      final origins = resolveBroadcastRelayOrigins(
        environment: environment,
        now: t0,
        directory: RelayDirectoryStore(),
      );
      expect(origins.single.host, 'from-env.example');
    });

    test('with neither, the compiled-in relay is the last resort', () {
      // A reader is never left with nowhere to look.
      final origins = resolveBroadcastRelayOrigins(
        environment: const {},
        now: t0,
      );
      expect(origins.single.host, contains('voice-call-relay'));
    });

    test('a directory drives real relay clients end to end', () async {
      final store = await storeWith(
        origins: [
          Uri.parse('https://one.example'),
          Uri.parse('https://two.example'),
          Uri.parse('https://three.example'),
        ],
      );
      final relays = broadcastRelaysFor(
        resolveBroadcastRelayOrigins(
          environment: const {},
          now: t0,
          directory: store,
        ),
      );
      expect(relays.map((r) => r.name), [
        'one.example',
        'two.example',
        'three.example',
      ]);
    });
  });

  group('over a loopback relay', () {
    late _LoopbackRelay server;
    late IoBroadcastHttpTransport transport;
    late CryptographyBroadcastSigner root;
    late BroadcastPublisher publisher;

    setUp(() async {
      server = await _LoopbackRelay.start();
      transport = IoBroadcastHttpTransport();
      root = await CryptographyBroadcastSigner.generate();
      publisher = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
    });

    tearDown(() async {
      transport.close();
      await server.stop();
    });

    HttpBroadcastRelay relayFor(_LoopbackRelay target) =>
        HttpBroadcastRelay(origin: target.origin, transport: transport);

    Future<BroadcastReader> readerOver(List<BroadcastRelay> relays) async {
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: relays,
      );
      await withClock(
        Clock.fixed(t0),
        () => reader.adoptCertificate(publisher.certificate.encoded),
      );
      return reader;
    }

    test('a post survives the round trip over real HTTP', () async {
      final relay = relayFor(server);
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(
            text: Uint8List.fromList('over the wire'.codeUnits),
            still: Uint8List.fromList(List.filled(9000, 3)),
          ),
        );
      });
      // Descriptor plus two layer objects.
      expect(server.storedCount, 3);

      final reader = await readerOver([relay]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
      expect(
        String.fromCharCodes(
          (await reader.fetchLayer(result.descriptor!, LayerFlag.text))!,
        ),
        'over the wire',
      );
      expect(
        (await reader.fetchLayer(result.descriptor!, LayerFlag.still))!.length,
        9000,
      );
    });

    test('a chunked media layer reassembles over real HTTP', () async {
      final relay = relayFor(server);
      final media = Uint8List.fromList(
        List.generate(150 * 1024, (i) => (i * 13 + 5) & 0xFF),
      );
      final post = await withClock(Clock.fixed(t0), () async {
        final p = await publisher.publish(media: media);
        await publisher.pushTo(relay, p);
        return p;
      });
      final reader = await readerOver([relay]);
      expect(await reader.fetchMedia(post.descriptor), media);
    });

    test('an unpublished sequence number reads as not-yet-published', () async {
      final reader = await readerOver([relayFor(server)]);
      final result = await withClock(Clock.fixed(t0), () => reader.fetchNext());
      expect(result.outcome, ReadOutcome.notAvailable);
    });

    test('republishing the same post is a quiet retry', () async {
      final relay = relayFor(server);
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: Uint8List.fromList('once'.codeUnits)),
      );
      await publisher.pushTo(relay, post);
      await publisher.pushTo(relay, post);
      expect(server.storedCount, 2);
    });

    test('a conflicting rewrite is reported, not swallowed', () async {
      final relay = relayFor(server);
      final address = DescriptorAddress(authorId: publisher.authorId, seq: 0);
      await relay.putDescriptor(address, Uint8List.fromList([1, 2, 3]));
      await expectLater(
        relay.putDescriptor(address, Uint8List.fromList([4, 5, 6])),
        throwsA(
          isA<BroadcastPublishRejected>().having(
            (e) => e.failure,
            'failure',
            BroadcastPublishFailure.conflict,
          ),
        ),
      );
    });

    test('a failing relay is skipped for one that answers', () async {
      final other = await _LoopbackRelay.start();
      addTearDown(other.stop);

      await withClock(Clock.fixed(t0), () async {
        final post = await publisher.publish(
          text: Uint8List.fromList('resilient'.codeUnits),
        );
        await publisher.pushTo(relayFor(other), post);
        // The first relay holds the post as well, then breaks.
        await publisher.pushTo(relayFor(server), post);
        server.failing.add(
          DescriptorAddress(authorId: publisher.authorId, seq: 0).path,
        );
      });

      final reader = await readerOver([relayFor(server), relayFor(other)]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
      expect(result.relayName, other.origin.host);
    });

    test(
      'a relay that alters bytes cannot poison a reader with a second one',
      () async {
        final other = await _LoopbackRelay.start();
        addTearDown(other.stop);
        await withClock(Clock.fixed(t0), () async {
          final post = await publisher.publish(
            text: Uint8List.fromList('unaltered'.codeUnits),
          );
          await publisher.pushTo(relayFor(server), post);
          await publisher.pushTo(relayFor(other), post);
        });
        server.tamper = true;

        final reader = await readerOver([relayFor(server), relayFor(other)]);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => reader.fetchNext(),
        );
        expect(result.isDelivered, isTrue);
        expect(result.relayName, other.origin.host);
        expect(
          String.fromCharCodes(
            (await reader.fetchLayer(result.descriptor!, LayerFlag.text))!,
          ),
          'unaltered',
        );
      },
    );

    test('a descriptor write carries the credentials a relay checks', () async {
      // Without these on the wire, a relay that enforces authorship
      // refuses every publish — and, worse, one that does not enforce it
      // lets anyone squat the author's coming sequence numbers.
      final credentials = BroadcastCredentials.of(
        root.publicKey,
        publisher.certificate,
      );
      final relay = HttpBroadcastRelay(
        origin: server.origin,
        transport: transport,
        credentials: credentials,
      );
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: Uint8List.fromList('hello'.codeUnits)),
      );
      await publisher.pushTo(relay, post);

      final seen = server.headersFor(post.address.path);
      expect(seen, isNotNull);
      expect(seen![broadcastAuthHeader], credentials.headerValue);
      // The object write needs none: its name already proves its bytes.
      final objectPath = ObjectAddress(
        contentHash(post.objects.values.first),
      ).path;
      expect(server.headersFor(objectPath)![broadcastAuthHeader], isNull);
    });

    test('the credential blob is the documented fixed size', () {
      final credentials = BroadcastCredentials.of(
        root.publicKey,
        publisher.certificate,
      );
      expect(
        credentials.rootPublicKey.length + credentials.certificate.length,
        // 32-byte root key plus a 125-byte version-2 certificate.
        157,
      );
      expect(
        () => BroadcastCredentials(
          rootPublicKey: Uint8List(31),
          certificate: publisher.certificate.encoded,
        ),
        throwsArgumentError,
      );
      expect(
        () => BroadcastCredentials(
          rootPublicKey: root.publicKey,
          certificate: Uint8List(10),
        ),
        throwsArgumentError,
      );
    });

    test('a body over the ceiling is refused rather than buffered', () async {
      final small = IoBroadcastHttpTransport(maxResponseBytes: 16);
      addTearDown(small.close);
      final relay = HttpBroadcastRelay(origin: server.origin, transport: small);
      final bytes = Uint8List.fromList(List.filled(1000, 7));
      await relay.putObject(bytes);
      expect(
        await relay.fetchObject(ObjectAddress(contentHash(bytes))),
        isNull,
      );
    });
  });
}
