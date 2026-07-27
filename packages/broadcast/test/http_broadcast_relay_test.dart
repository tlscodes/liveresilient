import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

/// Records what was asked for and answers from a script.
class _FakeTransport implements BroadcastHttpTransport {
  _FakeTransport({this.onGet, this.onPut});

  final BroadcastHttpResponse Function(Uri url)? onGet;
  final BroadcastHttpResponse Function(Uri url, Uint8List body)? onPut;

  final List<Uri> gets = [];
  final List<Uri> puts = [];
  final Map<String, Uint8List> stored = {};

  @override
  Future<BroadcastHttpResponse> get(Uri url) async {
    gets.add(url);
    if (onGet != null) return onGet!(url);
    final held = stored[url.path];
    return held == null
        ? const BroadcastHttpResponse(statusCode: 404)
        : BroadcastHttpResponse(statusCode: 200, body: held);
  }

  @override
  Future<BroadcastHttpResponse> put(Uri url, Uint8List body) async {
    puts.add(url);
    if (onPut != null) return onPut!(url, body);
    stored[url.path] = Uint8List.fromList(body);
    return const BroadcastHttpResponse(statusCode: 201);
  }
}

class _ThrowingTransport implements BroadcastHttpTransport {
  @override
  Future<BroadcastHttpResponse> get(Uri url) async =>
      throw StateError('socket failed');

  @override
  Future<BroadcastHttpResponse> put(Uri url, Uint8List body) async =>
      throw StateError('socket failed');
}

void main() {
  final origin = Uri.parse('https://relay.example');
  final authorId = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
  final t0 = DateTime.utc(2026, 7, 28, 12);

  group('addressing', () {
    test('builds the documented paths on the given origin', () async {
      final transport = _FakeTransport();
      final relay = HttpBroadcastRelay(origin: origin, transport: transport);
      final bytes = Uint8List.fromList([1, 2, 3]);

      await relay.fetchDescriptor(
        DescriptorAddress(authorId: authorId, seq: 41),
      );
      await relay.fetchObject(ObjectAddress(contentHash(bytes)));

      expect(
        transport.gets.first.toString(),
        'https://relay.example/a/0102030405060708/41',
      );
      expect(
        transport.gets.last.toString(),
        'https://relay.example/o/${hexEncode(contentHash(bytes))}',
      );
    });

    test('an object is published under the hash of its own bytes', () async {
      final transport = _FakeTransport();
      final relay = HttpBroadcastRelay(origin: origin, transport: transport);
      final bytes = Uint8List.fromList([9, 8, 7]);
      await relay.putObject(bytes);
      expect(transport.puts.single.path, '/o/${hexEncode(contentHash(bytes))}');
    });

    test('a path or query on the origin is discarded', () async {
      final transport = _FakeTransport();
      final relay = HttpBroadcastRelay(
        origin: Uri.parse('https://relay.example/ignored?x=1'),
        transport: transport,
      );
      await relay.fetchDescriptor(
        DescriptorAddress(authorId: authorId, seq: 0),
      );
      expect(
        transport.gets.single.toString(),
        'https://relay.example/a/0102030405060708/0',
      );
    });

    test('the default name is the host', () {
      expect(
        HttpBroadcastRelay(origin: origin, transport: _FakeTransport()).name,
        'relay.example',
      );
      expect(
        HttpBroadcastRelay(
          origin: origin,
          transport: _FakeTransport(),
          name: 'border',
        ).name,
        'border',
      );
    });

    test('refuses an origin that is not http or https', () {
      expect(
        () => HttpBroadcastRelay(
          origin: Uri.parse('ftp://relay.example'),
          transport: _FakeTransport(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('reads', () {
    test('a 200 with bytes is the only thing that counts as present', () async {
      for (final status in [204, 301, 403, 404, 429, 500, 503]) {
        final relay = HttpBroadcastRelay(
          origin: origin,
          transport: _FakeTransport(
            onGet: (_) => BroadcastHttpResponse(statusCode: status),
          ),
        );
        expect(
          await relay.fetchObject(ObjectAddress(contentHash(Uint8List(1)))),
          isNull,
          reason: 'HTTP $status must read as absent',
        );
      }
    });

    test('a 200 with an empty body reads as absent', () async {
      final relay = HttpBroadcastRelay(
        origin: origin,
        transport: _FakeTransport(
          onGet: (_) =>
              BroadcastHttpResponse(statusCode: 200, body: Uint8List(0)),
        ),
      );
      expect(
        await relay.fetchDescriptor(
          DescriptorAddress(authorId: authorId, seq: 0),
        ),
        isNull,
      );
    });

    test(
      'a transport failure propagates so a reader can try the next relay',
      () async {
        // BroadcastReader catches this and moves on; swallowing it here
        // would make a down relay indistinguishable from an empty one.
        final relay = HttpBroadcastRelay(
          origin: origin,
          transport: _ThrowingTransport(),
        );
        expect(
          () => relay.fetchDescriptor(
            DescriptorAddress(authorId: authorId, seq: 0),
          ),
          throwsStateError,
        );
      },
    );
  });

  group('writes', () {
    Future<void> publish(int status) {
      final relay = HttpBroadcastRelay(
        origin: origin,
        transport: _FakeTransport(
          onPut: (_, _) => BroadcastHttpResponse(statusCode: status),
        ),
      );
      return relay.putObject(Uint8List.fromList([1]));
    }

    test('201 and 204 both mean the address holds what was intended', () async {
      await publish(201);
      await publish(204);
    });

    test('each refusal maps to a named failure', () async {
      final cases = {
        409: BroadcastPublishFailure.conflict,
        413: BroadcastPublishFailure.tooLarge,
        429: BroadcastPublishFailure.rateLimited,
        507: BroadcastPublishFailure.outOfSpace,
        400: BroadcastPublishFailure.refused,
        500: BroadcastPublishFailure.refused,
      };
      for (final entry in cases.entries) {
        await expectLater(
          publish(entry.key),
          throwsA(
            isA<BroadcastPublishRejected>()
                .having((e) => e.failure, 'failure', entry.value)
                .having((e) => e.statusCode, 'statusCode', entry.key),
          ),
          reason: 'HTTP ${entry.key}',
        );
      }
    });

    test(
      'a transport failure on write is a refusal, not a silent success',
      () async {
        final relay = HttpBroadcastRelay(
          origin: origin,
          transport: _ThrowingTransport(),
        );
        await expectLater(
          relay.putObject(Uint8List.fromList([1])),
          throwsA(
            isA<BroadcastPublishRejected>()
                .having(
                  (e) => e.failure,
                  'failure',
                  BroadcastPublishFailure.refused,
                )
                .having((e) => e.statusCode, 'statusCode', 0),
          ),
        );
      },
    );

    test('the rejection names the failure, the status and the address', () {
      final error = BroadcastPublishRejected(
        BroadcastPublishFailure.conflict,
        409,
        Uri.parse('https://relay.example/a/0102030405060708/3'),
      );
      expect(error.toString(), contains('conflict'));
      expect(error.toString(), contains('409'));
      expect(error.toString(), contains('/a/0102030405060708/3'));
    });
  });

  test('a post published over HTTP is read back and verified', () async {
    // The full loop against the HTTP client rather than the in-memory
    // relay: same publisher, same reader, same verification.
    final transport = _FakeTransport();
    final relay = HttpBroadcastRelay(origin: origin, transport: transport);
    final root = await CryptographyBroadcastSigner.generate();

    final publisher = await withClock(
      Clock.fixed(t0),
      () => BroadcastPublisher.create(rootSigner: root),
    );
    await withClock(Clock.fixed(t0), () async {
      await publisher.pushTo(
        relay,
        await publisher.publish(
          text: Uint8List.fromList('over http'.codeUnits),
        ),
      );
    });

    final reader = BroadcastReader(
      rootPublicKey: root.publicKey,
      relays: [relay],
    );
    await withClock(Clock.fixed(t0), () async {
      expect(
        await reader.adoptCertificate(publisher.certificate.encoded),
        isTrue,
      );
    });

    final result = await withClock(
      Clock.fixed(t0.add(const Duration(minutes: 1))),
      () => reader.fetchNext(),
    );
    expect(result.isDelivered, isTrue);
    final text = await reader.fetchLayer(result.descriptor!, LayerFlag.text);
    expect(String.fromCharCodes(text!), 'over http');
  });
}
