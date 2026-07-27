import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' as pkg_clock;
import 'package:test/test.dart';

EdgeBridgeTopology _topology(List<String> authorities) => EdgeBridgeTopology(
      nodes: [for (final a in authorities) EdgeRelayNode.parse(a)],
    );

class _FakeConnection implements EdgeBridgeConnection {
  final List<Uint8List> sent = [];

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List frame) => sent.add(frame);

  @override
  Future<void> close() async {}
}

class _FakeDuplex implements DuplexByteStream {
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

RealityCredential _credential() => RealityCredential.fromSharedSecret(
      Uint8List.fromList(List<int>.filled(32, 0x5A)),
    );

Uint8List _authenticatedHello(RealityAuthenticator auth) {
  final credential = _credential();
  final random = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 13 + 7) & 0xFF),
  );
  return UtlsClientHelloBuilder.wrapInRecord(
    UtlsClientHelloBuilder(
      profile: UtlsClientProfile.chrome120,
      random: Random(9),
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
  group('EdgeRelayNode parsing', () {
    test('reads host:port, bare host, and full URLs', () {
      expect(EdgeRelayNode.parse('203.0.113.10:443').authority,
          '203.0.113.10:443');
      expect(EdgeRelayNode.parse('edge.example').authority,
          'edge.example:443');
      expect(EdgeRelayNode.parse('https://edge.example:8443').authority,
          'edge.example:8443');
    });

    test('rejects an address with no host', () {
      expect(() => EdgeRelayNode.parse(''),
          throwsA(isA<TopologyViolation>()));
      expect(() => EdgeRelayNode.parse('https://'),
          throwsA(isA<TopologyViolation>()));
    });
  });

  group('EdgeBridgeTopology — origin concealment', () {
    test('builds from the documented config schema', () {
      final topology = EdgeBridgeTopology.fromConfig({
        'edgeBridgeNodes': ['203.0.113.10:443', '203.0.113.11:443'],
        'utlsProfile': 'chrome_latest',
      });
      expect(topology.nodes, hasLength(2));
      expect(topology.endpoints.first.port, 443);
    });

    test('refuses a client config that names an origin at all', () {
      expect(
        () => EdgeBridgeTopology.fromConfig({
          'edgeBridgeNodes': ['203.0.113.10:443'],
          'originServer': '198.51.100.5:443',
        }),
        throwsA(isA<TopologyViolation>()),
      );
      expect(
        () => EdgeBridgeTopology.fromConfig({
          'edgeBridgeNodes': ['203.0.113.10:443'],
          'upstreamServerIp': '198.51.100.5',
        }),
        throwsA(isA<TopologyViolation>()),
      );
    });

    test('refuses a config with no edge nodes', () {
      expect(() => EdgeBridgeTopology.fromConfig({'edgeBridgeNodes': []}),
          throwsA(isA<TopologyViolation>()));
      expect(() => EdgeBridgeTopology.fromConfig(const {}),
          throwsA(isA<TopologyViolation>()));
    });

    test('a relay topology yields a client view with the origin stripped',
        () {
      final relay = EdgeRelayTopology(
        origin: Uri.parse('https://198.51.100.5:8443'),
        peers: [EdgeRelayNode.parse('203.0.113.10:443')],
      );
      final client = relay.clientView;
      expect(client.nodes, hasLength(1));
      expect(
        client.endpoints.map((e) => e.toString()).join(),
        isNot(contains('198.51.100.5')),
      );
    });
  });

  group('EdgeNodeDirectory', () {
    test('offers every node before repeating any', () {
      final directory =
          EdgeNodeDirectory(topology: _topology(['a:443', 'b:443', 'c:443']));
      final seen = <String>{};
      for (var i = 0; i < 3; i++) {
        seen.add(directory.preferredOrder.first.authority);
        directory.advanceRotation();
      }
      expect(seen, hasLength(3));
    });

    test('demotes a failing node and backs it off exponentially', () {
      final start = DateTime.utc(2026, 7, 27, 9);
      pkg_clock.withClock(pkg_clock.Clock.fixed(start), () {
        final directory = EdgeNodeDirectory(
          topology: _topology(['a:443', 'b:443']),
          minBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(minutes: 2),
        );
        final a = directory.health.first.node;

        directory.recordFailure(a);
        expect(directory.backoffOf(a), const Duration(seconds: 5));
        directory.recordFailure(a);
        expect(directory.backoffOf(a), const Duration(seconds: 10));
        directory.recordFailure(a);
        expect(directory.backoffOf(a), const Duration(seconds: 20));

        expect(directory.eligibleNodes.map((n) => n.authority), ['b:443']);
        expect(directory.preferredOrder.first.authority, 'b:443');
      });
    });

    test('clamps the backoff at the ceiling', () {
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)), () {
        final directory = EdgeNodeDirectory(
          topology: _topology(['a:443']),
          minBackoff: const Duration(seconds: 5),
          maxBackoff: const Duration(seconds: 30),
        );
        final a = directory.health.first.node;
        for (var i = 0; i < 12; i++) {
          directory.recordFailure(a);
        }
        expect(directory.backoffOf(a), const Duration(seconds: 30));
      });
    });

    test('a node re-enters service once its backoff expires', () {
      final start = DateTime.utc(2026, 7, 27, 9);
      late EdgeNodeDirectory directory;
      late EdgeRelayNode a;
      pkg_clock.withClock(pkg_clock.Clock.fixed(start), () {
        directory = EdgeNodeDirectory(
          topology: _topology(['a:443', 'b:443']),
          minBackoff: const Duration(seconds: 5),
        );
        a = directory.health.first.node;
        directory.recordFailure(a);
        expect(directory.eligibleNodes, hasLength(1));
      });
      pkg_clock.withClock(
        pkg_clock.Clock.fixed(start.add(const Duration(seconds: 6))),
        () {
          expect(directory.eligibleNodes, hasLength(2));
          expect(directory.backoffOf(a), isNull);
        },
      );
    });

    test('a success clears the penalty immediately', () {
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)), () {
        final directory = EdgeNodeDirectory(topology: _topology(['a:443']));
        final a = directory.health.first.node;
        directory.recordFailure(a);
        directory.recordFailure(a);
        directory.recordSuccess(a);
        expect(directory.backoffOf(a), isNull);
        expect(directory.health.first.consecutiveFailures, 0);
        expect(directory.health.first.lastSuccess, isNotNull);
      });
    });

    test('still offers an order when every node is backing off — refusing '
        'to try is worse than trying early', () {
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)), () {
        final directory = EdgeNodeDirectory(topology: _topology(['a:443']));
        directory.recordFailure(directory.health.first.node);
        expect(directory.eligibleNodes, isEmpty);
        expect(directory.preferredOrder, hasLength(1));
      });
    });

    test('discovery adds new nodes and drops withdrawn ones', () async {
      var discovered = [
        EdgeRelayNode.parse('a:443'),
        EdgeRelayNode.parse('c:443'),
      ];
      final directory = EdgeNodeDirectory(
        topology: _topology(['a:443', 'b:443']),
        discovery: () async => discovered,
      );

      expect(await directory.refreshDiscovery(), 1);
      expect(
        directory.health.map((h) => h.node.authority).toSet(),
        {'a:443', 'c:443'},
      );

      discovered = [];
      expect(await directory.refreshDiscovery(), 0,
          reason: 'an empty discovery result means "no change", not "wipe"');
      expect(directory.health, hasLength(2));
    });

    test('a rediscovered failing node keeps its penalty', () async {
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)),
          () async {
        final directory = EdgeNodeDirectory(
          topology: _topology(['a:443']),
          discovery: () async => [EdgeRelayNode.parse('a:443')],
        );
        directory.recordFailure(directory.health.first.node);
        await directory.refreshDiscovery();
        expect(directory.health.first.consecutiveFailures, 1,
            reason: 'rediscovery is not evidence the node was fixed');
      });
    });
  });

  group('EdgeBridgeClient', () {
    test('builds a lane over the directory order', () {
      final directory =
          EdgeNodeDirectory(topology: _topology(['a:443', 'b:443']));
      final client = EdgeBridgeClient(
        directory: directory,
        connector: (_) async => _FakeConnection(),
      );
      addTearDown(client.dispose);
      expect(client.lane.endpoints, hasLength(2));
      expect(client.laneEndpoints, client.lane.endpoints);
    });

    test('records a failing endpoint against its node', () async {
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)),
          () async {
        final directory =
            EdgeNodeDirectory(topology: _topology(['a:443', 'b:443']));
        final client = EdgeBridgeClient(
          directory: directory,
          connector: (uri) async {
            if (uri.host == 'a') throw StateError('refused');
            return _FakeConnection();
          },
        );
        addTearDown(client.dispose);

        final result = await client.lane.send([1, 2, 3]);
        expect(result.status, SendStatus.ok,
            reason: 'the healthy node carried it');
        final a = directory.health
            .firstWhere((h) => h.node.authority == 'a:443');
        final b = directory.health
            .firstWhere((h) => h.node.authority == 'b:443');
        expect(a.consecutiveFailures, greaterThan(0));
        expect(b.consecutiveFailures, 0);
        expect(b.lastSuccess, isNotNull);
      });
    });

    test('rebuilds the lane only when the pool actually changes', () async {
      var discovered = [EdgeRelayNode.parse('a:443')];
      final directory = EdgeNodeDirectory(
        topology: _topology(['a:443']),
        discovery: () async => discovered,
      );
      final client = EdgeBridgeClient(
        directory: directory,
        connector: (_) async => _FakeConnection(),
      );
      addTearDown(client.dispose);

      final first = client.lane;
      expect(await client.refresh(), isFalse);
      expect(client.lane, same(first));

      discovered = [
        EdgeRelayNode.parse('a:443'),
        EdgeRelayNode.parse('d:443'),
      ];
      expect(await client.refresh(), isTrue);
      expect(client.lane, isNot(same(first)));
      expect(client.lane.endpoints, hasLength(2));
    });

    test('shapes payloads when a shaper is configured', () async {
      final connection = _FakeConnection();
      final client = EdgeBridgeClient(
        directory: EdgeNodeDirectory(topology: _topology(['a:443'])),
        connector: (_) async => connection,
        shaper: TrafficShaper(
          random: Random(3),
          allowInsecureRandom: true,
        ),
      );
      addTearDown(client.dispose);

      final payload = List<int>.generate(50, (i) => i);
      await client.lane.send(payload);
      final message = const GrpcMessageFramer().decode(connection.sent.single);
      expect(message.length, greaterThan(payload.length));
      expect(TrafficShaper.unshape(message), payload);
    });
  });

  group('EdgeRelayNodeServer', () {
    late _FakeDuplex client;
    late _FakeDuplex origin;
    late _FakeDuplex fallback;
    late RealityAuthenticator auth;
    late EdgeRelayNodeServer node;

    setUp(() {
      client = _FakeDuplex();
      origin = _FakeDuplex();
      fallback = _FakeDuplex();
      auth = RealityAuthenticator(credentials: [_credential()]);
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

    test('forwards an authenticated session to the origin', () async {
      final outcome = node.handle(client);
      await Future<void>.delayed(Duration.zero);
      final hello = _authenticatedHello(auth);
      client.deliver(hello);
      await Future<void>.delayed(Duration.zero);
      client.deliver([9, 9, 9]);
      await Future<void>.delayed(Duration.zero);
      origin.deliver([7, 7]);
      await Future<void>.delayed(Duration.zero);
      origin.endOfPeerStream();
      final result = await outcome;

      expect(result.admitted, isTrue);
      expect(origin.writtenBytes, [...hello, 9, 9, 9],
          reason: 'the handshake bytes must reach the origin in position');
      expect(client.writtenBytes, [7, 7]);
      expect(fallback.written, isEmpty,
          reason: 'an authenticated client never touches the fallback host');
      expect(node.stats.admitted, 1);
    });

    test('an unauthenticated probe goes to the fallback host, never the '
        'origin', () async {
      final probe = UtlsClientHelloBuilder.wrapInRecord(
        UtlsClientHelloBuilder(
          profile: UtlsClientProfile.chrome120,
          random: Random(2),
        ).build(serverName: 'edge.example', sessionId: Uint8List(32)),
      );
      final outcome = node.handle(client);
      await Future<void>.delayed(Duration.zero);
      client.deliver(probe);
      await Future<void>.delayed(Duration.zero);
      client.endOfPeerStream();
      final result = await outcome;

      expect(result.admitted, isFalse);
      expect(result.reason, RealityRejectReason.unknownShortId);
      expect(fallback.writtenBytes, probe);
      expect(origin.written, isEmpty,
          reason: 'the origin must never see an unauthenticated byte');
      expect(client.written, isEmpty,
          reason: 'the node originates nothing of its own');
      expect(node.stats.passedThrough, 1);
      expect(node.stats.passThroughRatio, 1.0);
    });

    test('stays silent when the origin is unreachable', () async {
      final failing = EdgeRelayNodeServer(
        gate: RealityGate(
          authenticator: auth,
          relay: PassThroughRelay(
            connector: (_, __) async => fallback,
            target: const FallbackTarget(host: 'www.apple.com'),
          ),
        ),
        originUplink: () async => throw StateError('origin down'),
      );
      final outcome = failing.handle(client);
      await Future<void>.delayed(Duration.zero);
      client.deliver(_authenticatedHello(auth));
      final result = await outcome;

      expect(result.admitted, isTrue);
      expect(result.uplinkFailed, isTrue);
      expect(client.written, isEmpty,
          reason: 'an error response would be a distinguishing reply');
      expect(client.closed, isTrue);
      expect(failing.stats.originUplinkFailures, 1);
    });

    test('the origin connector takes no address, so a peer cannot steer it',
        () {
      // A compile-time property, asserted here so it is not silently
      // relaxed later: OriginUplinkConnector has zero parameters.
      const OriginUplinkConnector connector = _noArgUplink;
      expect(connector, isNotNull);
    });
  });

  group('ProbeDefenseConfig.fromJson', () {
    test('parses the documented schema', () {
      final config = ProbeDefenseConfig.fromJson(const {
        'fallbackTarget': 'www.apple.com:443',
        'utlsProfile': 'chrome_latest',
        'tcpOsProfile': 'windows_11',
        'enablePQ': true,
        'enableECH': true,
        'shaping': {
          'paddingRange': [1, 128],
          'jitterMicroseconds': 250,
        },
      });

      expect(config.utlsProfile, UtlsProfileId.chrome120);
      expect(config.tcpProfile, TcpStackProfileId.windows);
      expect(config.enablePostQuantum, isTrue);
      expect(config.enableEch, isTrue);
      expect(config.fallbackTarget!.host, 'www.apple.com');
      expect(config.fallbackTarget!.port, 443);
      expect(config.shaping.maxPadding, 128);
      expect(config.shaping.maxJitter, const Duration(microseconds: 250));
      expect(config.shaping.gaussianMean, 64);
    });

    test('applies sane defaults for a minimal config', () {
      final config = ProbeDefenseConfig.fromJson(const {});
      expect(config.utlsProfile, UtlsProfileId.chrome120);
      expect(config.tcpProfile, TcpStackProfileId.windows);
      expect(config.shaping.maxPadding, TrafficShapingPolicy.voice.maxPadding);
      expect(config.fallbackTarget, isNull);
    });

    test('maps OS release names onto stack profiles', () {
      expect(
        ProbeDefenseConfig.fromJson(const {
          'utlsProfile': 'safari_latest',
          'tcpOsProfile': 'ios',
          'enablePQ': false,
        }).tcpProfile,
        TcpStackProfileId.iOS,
      );
      expect(
        ProbeDefenseConfig.fromJson(const {
          'utlsProfile': 'firefox_latest',
          'tcpOsProfile': 'linux',
        }).tcpProfile,
        TcpStackProfileId.linux,
      );
    });

    test('rejects unknown profile names rather than guessing', () {
      expect(
        () => ProbeDefenseConfig.fromJson(const {'utlsProfile': 'edge_99'}),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
      expect(
        () => ProbeDefenseConfig.fromJson(const {'tcpOsProfile': 'plan9'}),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('rejects an inverted padding range', () {
      expect(
        () => ProbeDefenseConfig.fromJson(const {
          'shaping': {
            'paddingRange': [128, 1],
          },
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('still enforces the cross-layer checks when parsed from JSON', () {
      expect(
        () => ProbeDefenseConfig.fromJson(const {
          'utlsProfile': 'safari_latest',
          'tcpOsProfile': 'windows_11',
          'enablePQ': false,
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });
  });
}

Future<DuplexByteStream> _noArgUplink() async => _FakeDuplex();
