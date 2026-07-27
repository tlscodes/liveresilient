import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' as pkg_clock;
import 'package:test/test.dart';

/// An in-memory duplex pair. `local` is what the code under test holds;
/// `remote` is what the peer would hold.
class FakeDuplex implements DuplexByteStream {
  FakeDuplex();

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  /// Every buffer written toward the peer, in order.
  final List<Uint8List> written = [];

  bool closed = false;

  /// Bytes the peer sends to us.
  void deliver(List<int> bytes) => _incoming.add(Uint8List.fromList(bytes));

  void endOfPeerStream() => _incoming.close();

  Uint8List get writtenBytes {
    final builder = BytesBuilder(copy: false);
    for (final chunk in written) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  @override
  Stream<Uint8List> get inbound => _incoming.stream;

  @override
  void add(Uint8List bytes) => written.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

RealityCredential _credential({int seed = 3}) {
  final random = Random(seed);
  return RealityCredential(
    shortId: Uint8List.fromList(
      List<int>.generate(8, (_) => random.nextInt(256)),
    ),
    authKey: Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ),
  );
}

Uint8List _clientRandom([int seed = 11]) {
  final random = Random(seed);
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// A hello carrying [sessionId], shaped like a real Chrome hello.
Uint8List _helloRecord({
  required Uint8List sessionId,
  required Uint8List clientRandom,
  UtlsClientProfile? profile,
}) {
  final builder = UtlsClientHelloBuilder(
    profile: profile ?? UtlsClientProfile.chrome120,
    random: Random(5),
  );
  return UtlsClientHelloBuilder.wrapInRecord(
    builder.build(
      serverName: 'www.example.com',
      sessionId: sessionId,
      clientRandom: clientRandom,
    ),
  );
}

void main() {
  group('RealityCredential', () {
    test('derives a stable short id and key from a shared secret', () {
      final secret = Uint8List.fromList(List<int>.filled(32, 0x42));
      final a = RealityCredential.fromSharedSecret(secret);
      final b = RealityCredential.fromSharedSecret(secret);
      expect(a.shortId, b.shortId);
      expect(a.authKey, b.authKey);
      expect(a.shortId, hasLength(8));
      expect(a.authKey, hasLength(32));
    });

    test('a different secret yields a different short id', () {
      final a = RealityCredential.fromSharedSecret(
        Uint8List.fromList(List<int>.filled(32, 0x42)),
      );
      final b = RealityCredential.fromSharedSecret(
        Uint8List.fromList(List<int>.filled(32, 0x43)),
      );
      expect(a.shortId, isNot(b.shortId));
    });

    test('builds a 32-byte session id, which is what a real hello carries', () {
      final sessionId = _credential().buildSessionId(
        clientRandom: _clientRandom(),
        timeSlot: 100,
      );
      expect(sessionId, hasLength(32));
    });

    test('rejects a short id of the wrong size', () {
      expect(
        () => RealityCredential(shortId: Uint8List(4), authKey: Uint8List(32)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('RealityAuthenticator', () {
    late RealityCredential credential;
    late RealityAuthenticator auth;

    setUp(() {
      credential = _credential();
      auth = RealityAuthenticator(credentials: [credential]);
    });

    test('admits a hello carrying a valid tag for the current slot', () {
      final random = _clientRandom();
      final record = _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot,
        ),
      );
      final decision = auth.inspectRecord(record);
      expect(decision.admitted, isTrue);
      expect(decision.credential!.shortIdHex, credential.shortIdHex);
      expect(decision.hello!.serverName, 'www.example.com');
    });

    test('passes through a hello with an unregistered short id', () {
      final other = _credential(seed: 99);
      final random = _clientRandom();
      final decision = auth.inspectRecord(
        _helloRecord(
          clientRandom: random,
          sessionId: other.buildSessionId(
            clientRandom: random,
            timeSlot: auth.currentTimeSlot,
          ),
        ),
      );
      expect(decision.admitted, isFalse);
      expect(decision.reason, RealityRejectReason.unknownShortId);
    });

    test('passes through a hello whose tag was lifted from another '
        'connection', () {
      final captured = credential.buildSessionId(
        clientRandom: _clientRandom(11),
        timeSlot: auth.currentTimeSlot,
      );
      // Same session id, different client random: the tag no longer binds.
      final decision = auth.inspectRecord(
        _helloRecord(clientRandom: _clientRandom(12), sessionId: captured),
      );
      expect(decision.admitted, isFalse);
      expect(decision.reason, RealityRejectReason.badAuthTag);
    });

    test('passes through a hello whose time slot is outside the skew', () {
      final random = _clientRandom();
      final record = _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot - 60,
        ),
      );
      final decision = auth.inspectRecord(record);
      expect(decision.admitted, isFalse);
      expect(decision.reason, RealityRejectReason.staleTimeSlot);
    });

    test('accepts a slot inside the skew window', () {
      final random = _clientRandom();
      final record = _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot - 1,
        ),
      );
      expect(auth.inspectRecord(record).admitted, isTrue);
    });

    test('admits a hello once and passes the replay through', () {
      final random = _clientRandom();
      final record = _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot,
        ),
      );
      expect(auth.inspectRecord(record).admitted, isTrue);
      final replay = auth.inspectRecord(record);
      expect(replay.admitted, isFalse);
      expect(replay.reason, RealityRejectReason.replayedHello);
    });

    test('forgets a client random once it can no longer be in-window', () {
      final start = DateTime.utc(2026, 7, 27, 12);
      late Uint8List record;
      pkg_clock.withClock(pkg_clock.Clock.fixed(start), () {
        final scoped = RealityAuthenticator(credentials: [credential]);
        final random = _clientRandom();
        record = _helloRecord(
          clientRandom: random,
          sessionId: credential.buildSessionId(
            clientRandom: random,
            timeSlot: scoped.currentTimeSlot,
          ),
        );
        expect(scoped.inspectRecord(record).admitted, isTrue);
        expect(scoped.replayMemorySize, 1);

        pkg_clock.withClock(
          pkg_clock.Clock.fixed(start.add(const Duration(minutes: 10))),
          () {
            // The entry is gone, but the hello is now stale anyway — the two
            // windows overlap on purpose, so expiry never opens a replay gap.
            final late = scoped.inspectRecord(record);
            expect(scoped.replayMemorySize, 0);
            expect(late.reason, RealityRejectReason.staleTimeSlot);
          },
        );
      });
    });

    test('passes through a hello with a session id of the wrong size', () {
      final decision = auth.inspectRecord(
        _helloRecord(clientRandom: _clientRandom(), sessionId: Uint8List(16)),
      );
      expect(decision.reason, RealityRejectReason.sessionIdWrongSize);
    });

    test('passes through bytes that are not a TLS handshake at all', () {
      final decision = auth.inspectRecord(
        Uint8List.fromList('GET / HTTP/1.1\r\n\r\n'.codeUnits),
      );
      expect(decision.admitted, isFalse);
      expect(decision.reason, RealityRejectReason.notATlsHandshake);
    });

    test('passes through a truncated handshake record', () {
      final random = _clientRandom();
      final record = _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot,
        ),
      );
      final decision = auth.inspectRecord(Uint8List.sublistView(record, 0, 40));
      expect(decision.reason, RealityRejectReason.malformedClientHello);
    });

    test('admits a valid hello under any browser profile', () {
      for (final profile in UtlsClientProfile.all) {
        final random = _clientRandom();
        final scoped = RealityAuthenticator(credentials: [credential]);
        final decision = scoped.inspectRecord(
          _helloRecord(
            profile: profile,
            clientRandom: random,
            sessionId: credential.buildSessionId(
              clientRandom: random,
              timeSlot: scoped.currentTimeSlot,
            ),
          ),
        );
        expect(decision.admitted, isTrue, reason: profile.id.name);
      }
    });
  });

  group('PassThroughRelay', () {
    late FakeDuplex client;
    late FakeDuplex upstream;
    late PassThroughRelay relay;

    setUp(() {
      client = FakeDuplex();
      upstream = FakeDuplex();
      relay = PassThroughRelay(
        connector: (_, __) async => upstream,
        target: const FallbackTarget(host: 'www.example.com'),
      );
    });

    test(
      'replays the consumed preface upstream unchanged and in position',
      () async {
        final preface = Uint8List.fromList([
          0x16,
          0x03,
          0x01,
          0x00,
          0x02,
          1,
          2,
        ]);
        final done = relay.splice(client, preface: preface);
        await Future<void>.delayed(Duration.zero); // let the splice subscribe
        client.deliver([3, 4, 5]);
        await Future<void>.delayed(Duration.zero);
        client.endOfPeerStream();
        final stats = await done;

        expect(upstream.writtenBytes, [...preface, 3, 4, 5]);
        expect(stats.bytesToUpstream, preface.length + 3);
      },
    );

    test(
      'relays upstream bytes back verbatim, including an error page',
      () async {
        final body = Uint8List.fromList(
          'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'.codeUnits,
        );
        final done = relay.splice(client, preface: Uint8List(0));
        await Future<void>.delayed(Duration.zero); // let the splice subscribe
        upstream.deliver(body);
        await Future<void>.delayed(Duration.zero);
        upstream.endOfPeerStream();
        final stats = await done;

        expect(client.writtenBytes, body);
        expect(stats.bytesToClient, body.length);
      },
    );

    test('writes nothing of its own to the client when upstream is '
        'unreachable', () async {
      final failing = PassThroughRelay(
        connector: (_, __) async => throw const SocketExceptionStub(),
        target: const FallbackTarget(host: 'unreachable.invalid'),
      );
      final stats = await failing.splice(client, preface: Uint8List(0));
      expect(client.written, isEmpty);
      expect(client.closed, isTrue);
      expect(stats.bytesToClient, 0);
    });

    test('a fallback connect that never completes is cut at connectTimeout, '
        'silently — same as an immediate refusal', () async {
      final hanging = PassThroughRelay(
        // Never resolves and never throws: the TCP handshake to the
        // fallback host is stuck (e.g. a black-holed route), not refused.
        connector: (_, __) => Completer<DuplexByteStream>().future,
        target: const FallbackTarget(host: 'stuck.invalid'),
        connectTimeout: const Duration(milliseconds: 30),
      );
      final stats = await hanging.splice(client, preface: Uint8List(0));
      expect(
        client.written,
        isEmpty,
        reason:
            'a timed-out fallback connect must stay silent, same as '
            'an immediately-refused one',
      );
      expect(client.closed, isTrue);
      expect(stats.bytesToClient, 0);
      expect(stats.bytesToUpstream, 0);
    });

    test('closes both sides when either ends', () async {
      final done = relay.splice(client, preface: Uint8List(0));
      upstream.endOfPeerStream();
      await done;
      expect(client.closed, isTrue);
      expect(upstream.closed, isTrue);
    });
  });

  group('RealityGate', () {
    late RealityCredential credential;
    late FakeDuplex client;
    late FakeDuplex upstream;
    late RealityGate gate;

    setUp(() {
      credential = _credential();
      client = FakeDuplex();
      upstream = FakeDuplex();
      gate = RealityGate(
        authenticator: RealityAuthenticator(credentials: [credential]),
        relay: PassThroughRelay(
          connector: (_, __) async => upstream,
          target: const FallbackTarget(host: 'www.example.com'),
        ),
        firstRecordTimeout: const Duration(milliseconds: 200),
      );
    });

    Uint8List validRecord(RealityAuthenticator auth) {
      final random = _clientRandom();
      return _helloRecord(
        clientRandom: random,
        sessionId: credential.buildSessionId(
          clientRandom: random,
          timeSlot: auth.currentTimeSlot,
        ),
      );
    }

    test('hands an authenticated connection to the call transport', () async {
      DuplexByteStream? admitted;
      Uint8List? consumed;
      final outcome = gate.handle(
        client,
        onAdmitted: (stream, bytes, _) {
          admitted = stream;
          consumed = bytes;
        },
      );
      client.deliver(validRecord(gate.authenticator));
      final result = await outcome;

      expect(result.admitted, isTrue);
      expect(admitted, same(client));
      expect(consumed, isNotNull);
      expect(
        upstream.written,
        isEmpty,
        reason: 'an admitted client must never touch the fallback host',
      );
      expect(
        client.written,
        isEmpty,
        reason: 'the gate itself originates no bytes',
      );
    });

    test('splices an unauthenticated probe without emitting a single byte '
        'of its own', () async {
      final probe = _helloRecord(
        clientRandom: _clientRandom(),
        sessionId: Uint8List(32), // an all-zero id belongs to nobody
      );
      var admittedCalled = false;
      final outcome = gate.handle(
        client,
        onAdmitted: (_, __, ___) => admittedCalled = true,
      );
      client.deliver(probe);
      await Future<void>.delayed(Duration.zero);
      client.endOfPeerStream();
      final result = await outcome;

      expect(admittedCalled, isFalse);
      expect(result.decision.reason, RealityRejectReason.unknownShortId);
      expect(
        upstream.writtenBytes,
        probe,
        reason: 'the prober\'s own hello must reach the real host verbatim',
      );
      expect(
        client.written,
        isEmpty,
        reason: 'no alert, no synthetic response — the relay stays silent',
      );
    });

    test('splices a probe that sends plain HTTP', () async {
      final request = Uint8List.fromList('GET / HTTP/1.1\r\n\r\n'.codeUnits);
      final outcome = gate.handle(client, onAdmitted: (_, __, ___) {});
      client.deliver(request);
      await Future<void>.delayed(Duration.zero);
      client.endOfPeerStream();
      final result = await outcome;

      expect(result.admitted, isFalse);
      expect(upstream.writtenBytes, request);
      expect(client.written, isEmpty);
    });

    test('splices a peer that connects and says nothing, once the first-record '
        'timeout expires', () async {
      final outcome = gate.handle(client, onAdmitted: (_, __, ___) {});
      // The silent peer eventually goes away; the splice ends with it.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          client.endOfPeerStream();
          upstream.endOfPeerStream();
        }),
      );
      final result = await outcome;
      expect(result.admitted, isFalse);
      expect(result.decision.reason, RealityRejectReason.notATlsHandshake);
      expect(client.written, isEmpty);
    });

    test(
      'buffers a hello split across several chunks before deciding',
      () async {
        final record = validRecord(gate.authenticator);
        final outcome = gate.handle(client, onAdmitted: (_, __, ___) {});
        client.deliver(Uint8List.sublistView(record, 0, 3));
        await Future<void>.delayed(Duration.zero);
        client.deliver(Uint8List.sublistView(record, 3, 60));
        await Future<void>.delayed(Duration.zero);
        client.deliver(Uint8List.sublistView(record, 60));
        final result = await outcome;
        expect(result.admitted, isTrue);
      },
    );

    test('reaches its routing decision well inside the 2 ms budget', () async {
      final auth = RealityAuthenticator(credentials: [credential]);
      final record = validRecord(auth);

      // Measure the decision itself, repeated, rather than one sample of a
      // single async hop: this is the cost the budget is about.
      const iterations = 200;
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        RealityAuthenticator(credentials: [credential]).inspectRecord(record);
      }
      stopwatch.stop();
      final perDecision = stopwatch.elapsedMicroseconds / iterations;
      expect(
        perDecision,
        lessThan(2000),
        reason:
            'parse + one HMAC must stay under 2 ms; measured '
            '${perDecision.toStringAsFixed(1)} us',
      );
    });
  });
}

/// Stands in for a connect failure without importing `dart:io` here.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
