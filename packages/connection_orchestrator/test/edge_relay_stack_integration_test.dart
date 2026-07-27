import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

/// End-to-end wiring of the concealment stack into the fabric:
///
///   media queue -> carriage -> EdgeBridgeClient lane -> edge relay node
///        -> (authenticated) origin uplink  |  (probe) fallback host
///
/// The point of this file is the joins, not the parts: each layer has its
/// own unit tests in `adaptive_transport`. What is asserted here is that
/// a frame put into [ResilientMediaTransport] arrives at the *origin* and
/// nowhere else, and that a probe arriving at the same relay reaches the
/// fallback host and nowhere else.
class _MemoryDuplex implements DuplexByteStream {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> written = [];
  bool closed = false;

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

/// An edge connection that records what the client sent to that endpoint.
class _RecordingEdge implements EdgeBridgeConnection {
  _RecordingEdge(this.endpoint, this.log);

  final Uri endpoint;
  final Map<Uri, List<Uint8List>> log;

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List frame) => log.putIfAbsent(endpoint, () => []).add(frame);

  @override
  Future<void> close() async {}
}

RealityCredential _credential() => RealityCredential.fromSharedSecret(
  Uint8List.fromList(List<int>.filled(32, 0x7C)),
);

Uint8List _authenticatedHello(RealityAuthenticator auth) {
  final credential = _credential();
  final random = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 5 + 1) & 0xFF),
  );
  return UtlsClientHelloBuilder.wrapInRecord(
    UtlsClientHelloBuilder(
      profile: UtlsClientProfile.chrome120,
      random: Random(6),
    ).build(
      serverName: 'edge.example',
      clientRandom: random,
      sessionId: credential.buildSessionId(
        clientRandom: random,
        timeSlot: auth.currentTimeSlot,
      ),
    ),
  );
}

void main() {
  group('client side: config -> topology -> lane -> fabric', () {
    test('a deployment config produces a lane the fabric accepts', () {
      const rawConfig = {
        'edgeBridgeNodes': ['203.0.113.10:443', '203.0.113.11:443'],
        'fallbackTarget': 'www.apple.com:443',
        'utlsProfile': 'chrome_latest',
        'tcpOsProfile': 'windows_11',
        'enablePQ': true,
        'enableECH': true,
        'shaping': {
          'paddingRange': [1, 128],
          'jitterMicroseconds': 250,
        },
      };

      final topology = EdgeBridgeTopology.fromConfig(rawConfig);
      final defense = ProbeDefenseConfig.fromJson(rawConfig);
      final log = <Uri, List<Uint8List>>{};

      final client = EdgeBridgeClient(
        directory: EdgeNodeDirectory(topology: topology),
        connector: (uri) async => _RecordingEdge(uri, log),
        shaper: TrafficShaper(
          policy: defense.shaping,
          random: Random(1),
          allowInsecureRandom: true,
        ),
      );
      addTearDown(client.dispose);

      final fabric = ConnectionFabric(
        fallbackQueue: DtnBundleQueue(),
        nowMs: () => 0,
      );
      addTearDown(fabric.dispose);
      final laneId = fabric.registerEdgeBridge(client.lane);

      expect(laneId, ConnectionFabric.edgeBridgeLaneId);
      expect(client.lane.endpoints, hasLength(2));
      expect(defense.tcpProfile, TcpStackProfileId.windows);
      expect(defense.shaping.maxPadding, 128);
      // The whole client stack, and no origin address anywhere in it.
      expect(client.lane.endpoints.map((e) => e.host).toSet(), {
        '203.0.113.10',
        '203.0.113.11',
      });
    });

    test('media frames leave through the edge lane, shaped', () async {
      final log = <Uri, List<Uint8List>>{};
      final client = EdgeBridgeClient(
        directory: EdgeNodeDirectory(
          topology: EdgeBridgeTopology.fromConfig(const {
            'edgeBridgeNodes': ['203.0.113.10:443'],
          }),
        ),
        connector: (uri) async => _RecordingEdge(uri, log),
        shaper: TrafficShaper(random: Random(2), allowInsecureRandom: true),
      );
      addTearDown(client.dispose);

      final transport = ResilientMediaTransport(
        queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
        carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
        edgeBridge: client.lane,
      );
      transport.send(
        Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF)),
        MediaType.photo,
      );

      transport.wireTick(nowMs: 0, voiceIsSpeaking: false);
      final results = await transport.flushWireTick(
        nowMs: 1000,
        voiceIsSpeaking: false,
      );

      expect(results, isNotEmpty);
      expect(results.every((r) => r.delivered), isTrue);
      final sentToEdge = log[Uri.parse('https://203.0.113.10:443')]!;
      expect(sentToEdge, hasLength(results.length));
      // Every frame is gRPC-framed and carries a shaping trailer that
      // unshapes cleanly — the two layers compose without either knowing
      // about the other.
      for (final frame in sentToEdge) {
        final message = const GrpcMessageFramer().decode(frame);
        expect(() => TrafficShaper.unshape(message), returnsNormally);
      }
    });

    test('a second flush while one is in flight is refused', () async {
      final log = <Uri, List<Uint8List>>{};
      final client = EdgeBridgeClient(
        directory: EdgeNodeDirectory(
          topology: EdgeBridgeTopology.fromConfig(const {
            'edgeBridgeNodes': ['203.0.113.10:443'],
          }),
        ),
        connector: (uri) async => _RecordingEdge(uri, log),
        shaper: TrafficShaper(random: Random(2), allowInsecureRandom: true),
      );
      addTearDown(client.dispose);

      final transport = ResilientMediaTransport(
        queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
        carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
        edgeBridge: client.lane,
      );
      transport.send(
        Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF)),
        MediaType.photo,
      );

      final first = transport.flushWireTick(
        nowMs: 1000,
        voiceIsSpeaking: false,
      );
      // Started without awaiting the first: its frames would interleave.
      expect(
        () => transport.flushWireTick(nowMs: 1000, voiceIsSpeaking: false),
        throwsStateError,
      );
      await first;
      // The guard clears, so the next tick proceeds normally.
      await expectLater(
        transport.flushWireTick(nowMs: 2000, voiceIsSpeaking: false),
        completes,
      );
    });

    test('the lane keeps its sequence across an edge failover', () async {
      final log = <Uri, List<Uint8List>>{};
      var firstNodeAlive = true;
      final directory = EdgeNodeDirectory(
        topology: EdgeBridgeTopology.fromConfig(const {
          'edgeBridgeNodes': ['203.0.113.10:443', '203.0.113.11:443'],
        }),
      );
      final client = EdgeBridgeClient(
        directory: directory,
        connector: (uri) async {
          if (uri.host == '203.0.113.10' && !firstNodeAlive) {
            throw StateError('edge blocked');
          }
          return _RecordingEdge(uri, log);
        },
      );
      addTearDown(client.dispose);

      await client.lane.send([1]);
      expect(client.lane.sessionSequence, 1);

      firstNodeAlive = false;
      await client.lane.send([2]);
      await client.lane.send([3]);

      expect(
        client.lane.sessionSequence,
        3,
        reason: 'failover continues the session sequence, never rewinds it',
      );
      expect(log.keys.map((u) => u.host).toSet(), hasLength(2));
    });
  });

  group('relay side: one node, two paths', () {
    late RealityAuthenticator auth;
    late _MemoryDuplex origin;
    late _MemoryDuplex fallback;
    late EdgeRelayNodeServer node;

    setUp(() {
      auth = RealityAuthenticator(credentials: [_credential()]);
      origin = _MemoryDuplex();
      fallback = _MemoryDuplex();
      node = EdgeRelayNodeServer(
        gate: RealityGate(
          authenticator: auth,
          relay: PassThroughRelay(
            connector: (_, __) async => fallback,
            target: const FallbackTarget(host: 'www.apple.com'),
          ),
          firstRecordTimeout: const Duration(milliseconds: 200),
        ),
        originUplink: () async => origin,
      );
    });

    test('an authenticated client reaches the origin; a probe reaches only '
        'the fallback host', () async {
      // Path 1: a real client.
      final real = _MemoryDuplex();
      final realDone = node.handle(real);
      await Future<void>.delayed(Duration.zero);
      real.deliver(_authenticatedHello(auth));
      await Future<void>.delayed(Duration.zero);
      real.deliver([0xAA, 0xBB]);
      await Future<void>.delayed(Duration.zero);
      origin.endOfPeerStream();
      final realOutcome = await realDone;

      expect(realOutcome.admitted, isTrue);
      expect(origin.writtenBytes, contains(0xAA));
      expect(fallback.written, isEmpty);
      final originBytesAfterRealClient = origin.writtenBytes.length;

      // Path 2: a scanner, against the same node.
      final probe = _MemoryDuplex();
      final probeBytes = UtlsClientHelloBuilder.wrapInRecord(
        UtlsClientHelloBuilder(
          profile: UtlsClientProfile.safari17,
          random: Random(8),
        ).build(serverName: 'edge.example', sessionId: Uint8List(32)),
      );
      final probeDone = node.handle(probe);
      await Future<void>.delayed(Duration.zero);
      probe.deliver(probeBytes);
      await Future<void>.delayed(Duration.zero);
      probe.endOfPeerStream();
      final probeOutcome = await probeDone;

      expect(probeOutcome.admitted, isFalse);
      expect(fallback.writtenBytes, probeBytes);
      expect(
        probe.written,
        isEmpty,
        reason: 'the node emits nothing a scanner could fingerprint',
      );
      expect(
        origin.writtenBytes.length,
        originBytesAfterRealClient,
        reason: 'the probe added not one byte to the origin uplink',
      );

      expect(node.stats.admitted, 1);
      expect(node.stats.passedThrough, 1);
      expect(node.stats.passThroughRatio, 0.5);
    });
  });
}
