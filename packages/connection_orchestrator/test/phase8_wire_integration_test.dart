import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:test/test.dart';

Uint8List bytes(int value, int count) =>
    Uint8List.fromList(List.filled(count, value));

Uint8List exporter() => Uint8List.fromList(
  List.generate(tlsExporterLength, (i) => (i * 3 + 2) & 0xff),
);

SecureTransportSession establishSession() {
  final salt = Uint8List.fromList(List.generate(16, (i) => 80 + i));
  final verifier = ScramVerifier.fromPassword(
    username: 'caller',
    password: 'relayed secret',
    salt: salt,
    iterations: 512,
  );
  final client = ScramClient(username: 'caller', password: 'relayed secret');
  final proof = client.proof(
    clientNonce: 'p8c',
    serverNonce: 'p8s',
    salt: salt,
    iterations: 512,
    channelBinding: exporter(),
  );
  final established = MutualRelaySession.establish(
    verifier: verifier,
    clientNonce: 'p8c',
    serverNonce: 'p8s',
    tlsExporter: exporter(),
    clientProof: proof,
  );
  if (established == null ||
      !client.verifyServerSignature(established.serverSignature)) {
    fail('handshake must succeed');
  }
  return SecureTransportSession(session: established.session);
}

void main() {
  group('facade with full relayed stack: ChannelData over secure session', () {
    final peer = const HostPort(host: '203.0.113.20', port: 41000);

    ResilientMediaTransport build({
      ChannelRelayLink? link,
      SecureTransportSession? session,
    }) => ResilientMediaTransport(
      queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
      carriage: MediaCarriage(mtuBlockSize: 16, random: Random(4)),
      secureSession: session,
      relayLink: link,
    );

    List<Uint8List> primedTick(ResilientMediaTransport t) {
      t.wireTick(nowMs: 0, voiceIsSpeaking: false);
      return t.wireTick(nowMs: 1000, voiceIsSpeaking: false);
    }

    test('relayed + sealed datagram round-trips through all three layers', () {
      final binder = ChannelRelayBinder();
      final transport = build(
        link: binder.bind(peer),
        session: establishSession(),
      );
      transport.send(bytes(0x5c, 300), MediaType.document);
      final wire = primedTick(transport);
      expect(wire, isNotEmpty);
      final view = ByteData.sublistView(wire.first);
      expect(
        view.getUint16(0),
        ChannelRelayBinder.firstChannel,
        reason: 'outermost framing must be ChannelData',
      );
      final datagram = transport.receiveFromWire(wire.first);
      expect(datagram.bytes, isNotEmpty);
    });

    test('measured stack overhead per datagram: channel 4 B + session 6 B', () {
      final binder = ChannelRelayBinder();
      final session = establishSession();
      final plain = build();
      final secured = build(link: binder.bind(peer), session: session);
      for (final t in [plain, secured]) {
        t.send(bytes(0x11, 300), MediaType.document);
      }
      final plainWire = primedTick(plain).first;
      final securedWire = primedTick(secured).first;
      final overhead = securedWire.length - plainWire.length;
      // ChannelData pads the sealed frame to 4 B, so overhead is 10 or 12.
      // ignore: avoid_print
      print(
        'MEASURED relayed+secured stack overhead: $overhead B per '
        'datagram (${plainWire.length} B plain -> ${securedWire.length} B)',
      );
      expect(
        overhead,
        inInclusiveRange(
          ChannelRelayLink.headerBytes + SecureTransportSession.overheadBytes,
          ChannelRelayLink.headerBytes +
              SecureTransportSession.overheadBytes +
              3,
        ),
      );
    });

    test(
      'replay of a relayed datagram is rejected under the channel layer',
      () {
        final binder = ChannelRelayBinder();
        final transport = build(
          link: binder.bind(peer),
          session: establishSession(),
        );
        transport.send(bytes(0x21, 300), MediaType.document);
        final wire = primedTick(transport);
        transport.receiveFromWire(wire.first);
        expect(
          () => transport.receiveFromWire(wire.first),
          throwsA(isA<ReplayedDatagramException>()),
        );
      },
    );

    test('a frame from another channel never reaches the session layer', () {
      final binder = ChannelRelayBinder();
      final link = binder.bind(peer);
      final other = binder.bind(
        const HostPort(host: '203.0.113.21', port: 41001),
      );
      final transport = build(link: link, session: establishSession());
      transport.send(bytes(0x31, 300), MediaType.document);
      final onWrongChannel = other.wrap(bytes(0, 32));
      expect(
        () => transport.receiveFromWire(onWrongChannel),
        throwsFormatException,
      );
    });
  });
}
