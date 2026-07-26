import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

Uint8List fixedBytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 7 + 3) & 0xff));

/// In-memory relay peer: the server side of the modern stack. Holds only the
/// SCRAM verifier (never the password), derives the same session as the
/// client, and records every payload it successfully unframes.
class FakeRelayPeer implements SecureLaneConnection {
  FakeRelayPeer({
    required this.username,
    required String password,
    this.dialDelay = Duration.zero,
    int exporterSeed = 13,
  })  : _password = password,
        tlsExporter = Uint8List.fromList(
          List.generate(tlsExporterLength, (i) => (i * exporterSeed + 5) & 0xff),
        );

  final String username;
  final String _password;
  @override
  final Uint8List tlsExporter;
  final Duration dialDelay;

  final Uint8List salt = fixedBytes(16);
  static const iterations = 512;

  SecureTransportSession? _session;
  String? _clientNonce;

  final receivedPayloads = <Uint8List>[];
  final wireLog = <Uint8List>[];
  bool closed = false;

  @override
  Future<({String serverNonce, Uint8List salt, int iterations})> startAuth(
      String user, String clientNonce) async {
    _clientNonce = clientNonce;
    return (serverNonce: 'srv-1', salt: salt, iterations: iterations);
  }

  @override
  Future<Uint8List?> finishAuth(Uint8List clientProof) async {
    final verifier = ScramVerifier.fromPassword(
      username: username,
      password: _password,
      salt: salt,
      iterations: iterations,
    );
    final established = MutualRelaySession.establish(
      verifier: verifier,
      clientNonce: _clientNonce!,
      serverNonce: 'srv-1',
      tlsExporter: tlsExporter,
      clientProof: clientProof,
    );
    if (established == null) return null;
    _session = SecureTransportSession(session: established.session);
    return established.serverSignature;
  }

  @override
  Future<Uint8List> answerPathChallenge(Uint8List challenge) async {
    final session = _session;
    if (session == null) return Uint8List(32);
    return session.newPathValidator().expectedResponse(challenge);
  }

  @override
  Future<void> sendDatagram(Uint8List frame) async {
    wireLog.add(frame);
    // Server side: strip the ChannelData header (the channel number was
    // assigned by the client's binder), then clear the replay window.
    final length = ByteData.sublistView(frame).getUint16(2);
    final sealed = Uint8List.sublistView(frame, 4, 4 + length);
    receivedPayloads.add(_session!.open(sealed));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  final endpoints = [
    RelayEndpoint(hostPort: const HostPort(host: 'relay-a.example', port: 443)),
    RelayEndpoint(hostPort: const HostPort(host: 'relay-b.example', port: 443)),
  ];

  Future<SecureMediaLane> connectLane(
    Map<String, FakeRelayPeer> peers, {
    String password = 'lane secret',
  }) =>
      SecureMediaLane.establish(
        endpoints: endpoints,
        dial: (e) async {
          final peer = peers[e.hostPort.host]!;
          if (peer.dialDelay > Duration.zero) {
            await Future<void>.delayed(peer.dialDelay);
          }
          return peer;
        },
        username: 'caller',
        password: password,
        randomBytes: fixedBytes,
        connectionAttemptDelay: const Duration(milliseconds: 20),
      );

  Map<String, FakeRelayPeer> twoPeers({Duration slowA = Duration.zero}) => {
        'relay-a.example':
            FakeRelayPeer(username: 'caller', password: 'lane secret', dialDelay: slowA),
        'relay-b.example':
            FakeRelayPeer(username: 'caller', password: 'lane secret'),
      };

  group('SecureMediaLane end-to-end', () {
    test('full recipe: race -> mutual auth -> path validation -> framed send',
        () async {
      final peers = twoPeers();
      final lane = await connectLane(peers);
      expect(lane.name, startsWith('secure-relay:'));
      final result = await lane.send([1, 2, 3, 4]);
      expect(result.delivered, isTrue);
      final server = peers[lane.endpoint.hostPort.host]!;
      expect(server.receivedPayloads.single, [1, 2, 3, 4]);
      expect(await lane.probe(), isTrue,
          reason: 'probe re-validates the path cryptographically');
    });

    test('slow first endpoint loses the race and its dial is discarded',
        () async {
      final peers = twoPeers(slowA: const Duration(milliseconds: 300));
      final lane = await connectLane(peers);
      expect(lane.endpoint.hostPort.host, 'relay-b.example');
      await lane.send([9]);
      expect(peers['relay-b.example']!.receivedPayloads, hasLength(1));
      expect(peers['relay-a.example']!.receivedPayloads, isEmpty);
    });

    test('wrong password fails closed at mutual auth', () async {
      final peers = twoPeers();
      await expectLater(
        connectLane(peers, password: 'wrong'),
        throwsA(isA<LaneEstablishmentException>()),
      );
      expect(
        peers.values.where((p) => p.closed), isNotEmpty,
        reason: 'a failed lane never leaks its connection',
      );
    });

    test('replayed wire datagram is rejected by the server session', () async {
      final peers = twoPeers();
      final lane = await connectLane(peers);
      await lane.send([5, 6]);
      final server = peers[lane.endpoint.hostPort.host]!;
      final captured = server.wireLog.single;
      expect(() => server.sendDatagram(captured),
          throwsA(isA<ReplayedDatagramException>()));
    });

    test('registered in ConnectionFabric it carries a delivery live',
        () async {
      final peers = twoPeers();
      final lane = await connectLane(peers);
      final fabric = ConnectionFabric(
        fallbackQueue: DtnBundleQueue(),
        nowMs: () => 1000,
      );
      fabric.registerLane(
        lane,
        const LaneProfile(id: 'secure-relay', kind: LaneKind.internet),
      );
      final outcome = await fabric.deliver(
        [7, 7, 7],
        bundleId: 'b1',
        priority: LinkMessagePriority.callSignal,
      );
      expect(outcome, DeliveryOutcome.sentLive);
      final server = peers[lane.endpoint.hostPort.host]!;
      expect(server.receivedPayloads.last, [7, 7, 7]);
      expect(fabric.snapshot.mode, FabricMode.live);
      await fabric.dispose();
    });

    test('measured: per-datagram lane overhead and establish round count',
        () async {
      final peers = twoPeers();
      final lane = await connectLane(peers);
      const payload = 160;
      final framed = lane.frame(Uint8List(payload));
      final overhead = framed.length - payload;
      // ignore: avoid_print
      print('MEASURED secure lane overhead: $overhead B per $payload B '
          'datagram (channel 4 + sequence 6 + padding)');
      expect(overhead, lessThanOrEqualTo(13));
      expect(lane.keyEpoch, 0);
      expect(lane.channelNumber, ChannelRelayBinder.firstChannel);
    });
  });
}
