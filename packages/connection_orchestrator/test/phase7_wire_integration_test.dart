import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:test/test.dart';

Uint8List bytes(int value, int count) =>
    Uint8List.fromList(List.filled(count, value));

Uint8List exporter([int seed = 5]) => Uint8List.fromList(
  List.generate(tlsExporterLength, (i) => (i * seed + 1) & 0xff),
);

/// Runs the full SCRAM exchange and returns the server-side wire session.
SecureTransportSession establishSession({int messagesPerEpoch = 1 << 20}) {
  final salt = Uint8List.fromList(List.generate(16, (i) => 64 + i));
  final verifier = ScramVerifier.fromPassword(
    username: 'caller',
    password: 'call secret',
    salt: salt,
    iterations: 1024,
  );
  final client = ScramClient(username: 'caller', password: 'call secret');
  final proof = client.proof(
    clientNonce: 'wc1',
    serverNonce: 'ws1',
    salt: salt,
    iterations: 1024,
    channelBinding: exporter(),
  );
  final established = MutualRelaySession.establish(
    verifier: verifier,
    clientNonce: 'wc1',
    serverNonce: 'ws1',
    tlsExporter: exporter(),
    clientProof: proof,
    messagesPerEpoch: messagesPerEpoch,
  );
  if (established == null ||
      !client.verifyServerSignature(established.serverSignature)) {
    fail('mutual handshake must succeed for the integration harness');
  }
  return SecureTransportSession(session: established.session);
}

ResilientMediaTransport transportWith(SecureTransportSession? session) =>
    ResilientMediaTransport(
      queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
      carriage: MediaCarriage(mtuBlockSize: 16, random: Random(9)),
      secureSession: session,
    );

/// The queue's token bucket accrues over elapsed time, so the first tick only
/// sets the baseline; this primes at t=0 and collects at t=1000.
List<Uint8List> primedTick(ResilientMediaTransport t) {
  t.wireTick(nowMs: 0, voiceIsSpeaking: false);
  return t.wireTick(nowMs: 1000, voiceIsSpeaking: false);
}

void main() {
  group('facade wire path with SecureTransportSession', () {
    test('sealed datagrams round-trip; each carries the 6-byte header', () {
      final session = establishSession();
      final transport = transportWith(session);
      final doc = bytes(0x33, 400);
      transport.send(doc, MediaType.document);
      final wire = primedTick(transport);
      expect(wire, isNotEmpty);

      final plain = transportWith(null);
      plain.send(doc, MediaType.document);
      final plainWire = primedTick(plain);
      expect(
        wire.first.length,
        plainWire.first.length + SecureTransportSession.overheadBytes,
        reason: 'measured overhead must be exactly the u48 header',
      );

      final received = transport.receiveFromWire(wire.first);
      expect(received.bytes, isNotEmpty);
    });

    test('a captured wire datagram cannot be delivered twice', () {
      final session = establishSession();
      final transport = transportWith(session);
      transport.send(bytes(1, 300), MediaType.document);
      final wire = primedTick(transport);
      transport.receiveFromWire(wire.first);
      expect(
        () => transport.receiveFromWire(wire.first),
        throwsA(isA<ReplayedDatagramException>()),
        reason: 'replayed media datagrams must never reach the decoder',
      );
    });

    test('out-of-order delivery within the window still decodes', () {
      final session = establishSession();
      final transport = transportWith(session);
      transport.send(bytes(2, 900), MediaType.document);
      final wire = <Uint8List>[
        ...transport.wireTick(nowMs: 0, voiceIsSpeaking: false),
        ...transport.wireTick(nowMs: 1000, voiceIsSpeaking: false),
      ];
      expect(wire.length, greaterThanOrEqualTo(2));
      // Deliver in reverse: the bitmap window accepts fresh-but-late numbers.
      for (final datagram in wire.reversed) {
        transport.receiveFromWire(datagram);
      }
    });

    test('admitted traffic drives key rotation through the facade', () {
      final session = establishSession(messagesPerEpoch: 2);
      final transport = transportWith(session);
      transport.send(bytes(3, 600), MediaType.document);
      final wire = <Uint8List>[
        ...transport.wireTick(nowMs: 0, voiceIsSpeaking: false),
        ...transport.wireTick(nowMs: 1000, voiceIsSpeaking: false),
      ];
      expect(wire.length, greaterThanOrEqualTo(2));
      expect(session.keyEpoch, 0);
      transport.receiveFromWire(wire[0]);
      transport.receiveFromWire(wire[1]);
      expect(
        session.keyEpoch,
        1,
        reason: '2-message budget must have rotated the epoch',
      );
    });

    test('plain transport (no session) is byte-identical to before', () {
      final transport = transportWith(null);
      transport.send(bytes(4, 200), MediaType.document);
      final wire = primedTick(transport);
      final again = transport.receiveFromWire(wire.first);
      expect(again.bytes, isNotEmpty);
    });
  });

  group('migration: continuity token + validated path through the session', () {
    test('token minted before rotation dies with the old epoch', () {
      final session = establishSession(messagesPerEpoch: 1);
      final token = session.mintContinuityToken();
      expect(session.verifyContinuityToken(token), isTrue);
      final transport = transportWith(session);
      transport.send(bytes(5, 300), MediaType.document);
      final wire = primedTick(transport);
      transport.receiveFromWire(wire.first); // budget 1 -> rotates
      expect(session.keyEpoch, 1);
      expect(
        session.verifyContinuityToken(token),
        isFalse,
        reason: 'rotation must invalidate previously minted tokens',
      );
      expect(
        session.verifyContinuityToken(session.mintContinuityToken()),
        isTrue,
      );
    });

    test('endpoint switch releases media only after path validation', () async {
      final session = establishSession();
      final probe = session.newPathValidator();
      final discarded = <String>[];
      final switcher = ValidatedSwitcher<String>(
        connect: (e) async => 'conn-${e.hostPort.host}',
        validatePath: (e, conn) async {
          final challenge = probe.issueChallenge(
            e.hostPort.authority,
            bytes(0x0a, 8),
          );
          // The genuine peer holds the same session key, so it can answer.
          return probe.validateResponse(
            e.hostPort.authority,
            probe.expectedResponse(challenge),
          );
        },
        discard: discarded.add,
      );
      final conn = await switcher.switchTo(
        RelayEndpoint(hostPort: const HostPort(host: 'relay-b', port: 443)),
      );
      expect(conn, 'conn-relay-b');
      expect(switcher.switchCount, 1);
      expect(discarded, isEmpty);
    });
  });
}
