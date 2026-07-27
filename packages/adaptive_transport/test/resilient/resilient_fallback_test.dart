import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// A local loopback UDP echo server: any datagram received is sent right
/// back to its sender. Used to give [PrimaryUdpLane] something real to
/// probe/send against without touching any external host.
class _LoopbackUdpEcho {
  _LoopbackUdpEcho._(this._socket);

  final RawDatagramSocket _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  static Future<_LoopbackUdpEcho> start() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final echo = _LoopbackUdpEcho._(socket);
    echo._sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = socket.receive();
        if (packet != null) {
          socket.send(packet.data, packet.address, packet.port);
        }
      }
    });
    return echo;
  }

  int get port => _socket.port;

  Future<void> stop() async {
    await _sub?.cancel();
    _socket.close();
  }
}

/// A local loopback HTTP server exposing:
/// - `GET /health` (or any path) -> 200, used by both WS upgrade and the
///   HTTP long-poll health check.
/// - `POST /send` -> collects the raw body as one delivered frame, 200 OK.
/// - WebSocket upgrade on `/ws` -> collects each binary message as one
///   delivered frame.
class _LoopbackRelayServer {
  _LoopbackRelayServer._(this._server);

  final HttpServer _server;
  final List<List<int>> receivedFrames = [];
  StreamSubscription<HttpRequest>? _sub;
  bool alive = true;

  static Future<_LoopbackRelayServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _LoopbackRelayServer._(server);
    relay._sub = server.listen(relay._handle);
    return relay;
  }

  int get port => _server.port;

  void _handle(HttpRequest request) async {
    if (!alive) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        if (data is List<int>) receivedFrames.add(data);
      });
      return;
    }
    if (request.method == 'POST') {
      final bytes = await request.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      receivedFrames.add(bytes);
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }
    // HEAD/GET health check.
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _server.close(force: true);
  }
}

void main() {
  group('PrimaryUdpLane', () {
    late _LoopbackUdpEcho echo;
    late PrimaryUdpLane lane;

    setUp(() async {
      echo = await _LoopbackUdpEcho.start();
      lane = PrimaryUdpLane(
        remote: HostPort(host: '127.0.0.1', port: echo.port),
      );
    });

    tearDown(() async {
      await lane.dispose();
      await echo.stop();
    });

    test('probes successfully against a live loopback echo', () async {
      expect(await lane.probe(), isTrue);
    });

    test('sends frames and reports ok', () async {
      final result = await lane.send(const [1, 2, 3, 4]);
      expect(result.status, SendStatus.ok);
      expect(result.delivered, isTrue);
    });

    test('probe fails once the echo server is stopped', () async {
      await echo.stop();
      expect(await lane.probe(), isFalse);
    });
  });

  group('WebSocketRelayLane', () {
    late _LoopbackRelayServer server;
    late WebSocketRelayLane lane;

    setUp(() async {
      server = await _LoopbackRelayServer.start();
      lane = WebSocketRelayLane(
        relayUri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      );
    });

    tearDown(() async {
      await lane.dispose();
      await server.stop();
    });

    test('sends binary frames the server receives', () async {
      final result = await lane.send(const [9, 9, 9, 9]);
      expect(result.status, SendStatus.ok);
      // Allow the server-side listener a microtask/event-loop turn to
      // register the frame.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.receivedFrames, hasLength(1));
      expect(server.receivedFrames.single, equals(const [9, 9, 9, 9]));
    });

    test('reconnects lazily after the server drops the connection', () async {
      await lane.send(const [1, 2, 3, 4]);
      await server.stop();
      // A binary `add()` on an already-open socket is fire-and-forget (like
      // a UDP datagram) and does not itself surface the server's absence;
      // an explicit probe forces a fresh connection attempt and is what
      // actually detects the drop, same pattern the resilient chain uses
      // via PathSelector.refresh().
      final stillUp = await lane.probe();
      expect(stillUp, isFalse);
      final failing = await lane.send(const [5, 6, 7, 8]);
      expect(failing.delivered, isFalse);

      server = await _LoopbackRelayServer.start();
      lane = WebSocketRelayLane(
        relayUri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      );
      final recovered = await lane.send(const [5, 6, 7, 8]);
      expect(recovered.status, SendStatus.ok);
    });
  });

  group('HttpLongPollLane', () {
    late _LoopbackRelayServer server;
    late HttpLongPollLane lane;

    setUp(() async {
      server = await _LoopbackRelayServer.start();
      lane = HttpLongPollLane(
        sendUri: Uri.parse('http://127.0.0.1:${server.port}/send'),
        healthCheckUri: Uri.parse('http://127.0.0.1:${server.port}/health'),
      );
    });

    tearDown(() async {
      await lane.dispose();
      await server.stop();
    });

    test('probe succeeds against a live health endpoint', () async {
      expect(await lane.probe(), isTrue);
    });

    test('POSTs the frame body and the server records it', () async {
      final result = await lane.send(const [4, 3, 2, 1]);
      expect(result.status, SendStatus.ok);
      expect(server.receivedFrames, hasLength(1));
      expect(server.receivedFrames.single, equals(const [4, 3, 2, 1]));
    });

    test('probe fails once the server refuses requests', () async {
      server.alive = false;
      expect(await lane.probe(), isFalse);
    });
  });

  group('LocalMeshLane', () {
    test('delivers via the injected peer sender', () async {
      final delivered = <List<int>>[];
      final lane = LocalMeshLane(
        peerSender: (payload) async {
          delivered.add(payload);
          return const SendResult(SendStatus.ok, rttMs: 5);
        },
      );
      final result = await lane.send(const [7, 7, 7, 7]);
      expect(result.status, SendStatus.ok);
      expect(delivered.single, equals(const [7, 7, 7, 7]));
    });

    test('probe delegates to the injected peer probe', () async {
      var probed = false;
      final lane = LocalMeshLane(
        peerSender: (_) async => const SendResult(SendStatus.unavailable),
        peerProbe: () async {
          probed = true;
          return true;
        },
      );
      expect(await lane.probe(), isTrue);
      expect(probed, isTrue);
    });

    test('send failures surface as unavailable', () async {
      final lane = LocalMeshLane(
        peerSender: (_) async => const SendResult(SendStatus.unavailable),
      );
      final result = await lane.send(const [1, 1, 1, 1]);
      expect(result.delivered, isFalse);
    });
  });

  group('ResilientFallbackTransportChain fallover', () {
    late _LoopbackUdpEcho echo;
    late _LoopbackRelayServer wsServer;
    late _LoopbackRelayServer httpServer;
    late PrimaryUdpLane udpLane;
    late WebSocketRelayLane wsLane;
    late HttpLongPollLane httpLane;
    late LocalMeshLane meshLane;
    final meshFrames = <List<int>>[];

    setUp(() async {
      echo = await _LoopbackUdpEcho.start();
      wsServer = await _LoopbackRelayServer.start();
      httpServer = await _LoopbackRelayServer.start();
      meshFrames.clear();

      udpLane = PrimaryUdpLane(
        remote: HostPort(host: '127.0.0.1', port: echo.port),
      );
      wsLane = WebSocketRelayLane(
        relayUri: Uri.parse('ws://127.0.0.1:${wsServer.port}/ws'),
      );
      httpLane = HttpLongPollLane(
        sendUri: Uri.parse('http://127.0.0.1:${httpServer.port}/send'),
      );
      meshLane = LocalMeshLane(
        peerSender: (payload) async {
          meshFrames.add(payload);
          return const SendResult(SendStatus.ok, rttMs: 1);
        },
      );
    });

    tearDown(() async {
      await udpLane.dispose();
      await wsLane.dispose();
      await httpLane.dispose();
      await meshLane.dispose();
      await echo.stop();
      await wsServer.stop();
      await httpServer.stop();
    });

    test('falls over UDP -> WS -> HTTP -> mesh with 100% delivery as each '
        'preceding lane is killed', () async {
      final selector = ResilientFallbackTransportChain.build(
        primaryUdp: udpLane,
        webSocketRelay: wsLane,
        httpLongPoll: httpLane,
        localMesh: meshLane,
      );

      const framesPerStage = 5;
      var delivered = 0;

      // Stage 1: UDP alive, everything should go via UDP.
      for (var i = 0; i < framesPerStage; i++) {
        final ok = await selector.sendChunk(const [1, 2, 3, 4]);
        if (ok) delivered++;
      }
      expect(httpServer.receivedFrames, isEmpty);
      expect(wsServer.receivedFrames, isEmpty);

      // Kill UDP: subsequent sends should fail over to WS. A real UDP
      // `send()` to a dead loopback echo does not itself error (there is
      // no connection to break), so the router only learns the lane is
      // down via an explicit health refresh (which probes and times out).
      await echo.stop();
      await selector.refresh();
      for (var i = 0; i < framesPerStage; i++) {
        final ok = await selector.sendChunk(const [1, 2, 3, 4]);
        if (ok) delivered++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(wsServer.receivedFrames, isNotEmpty);

      // Kill WS: subsequent sends should fail over to HTTP.
      await wsServer.stop();
      await selector.refresh();
      for (var i = 0; i < framesPerStage; i++) {
        final ok = await selector.sendChunk(const [1, 2, 3, 4]);
        if (ok) delivered++;
      }
      expect(httpServer.receivedFrames, isNotEmpty);

      // Kill HTTP: subsequent sends should fail over to the mesh.
      await httpServer.stop();
      await selector.refresh();
      for (var i = 0; i < framesPerStage; i++) {
        final ok = await selector.sendChunk(const [1, 2, 3, 4]);
        if (ok) delivered++;
      }
      expect(meshFrames, isNotEmpty);

      expect(delivered, framesPerStage * 4);

      await selector.dispose();
    });
  });

  group('PoissonPacer', () {
    test('mean interval stays within tolerance of the configured mean', () {
      final pacer = PoissonPacer(meanIntervalMs: 125, random: Random(42));
      const samples = 20000;
      var total = 0.0;
      for (var i = 0; i < samples; i++) {
        total += pacer.nextIntervalMs();
      }
      final mean = total / samples;
      // Exponential sampling has high variance; with 20k seeded samples the
      // empirical mean should land within 5% of the configured mean.
      expect(mean, closeTo(125, 125 * 0.05));
    });

    test('every interval is strictly positive', () {
      final pacer = PoissonPacer(meanIntervalMs: 10, random: Random(7));
      for (var i = 0; i < 5000; i++) {
        expect(pacer.nextIntervalMs(), greaterThan(0));
      }
    });

    test('same seed produces the same sequence (deterministic)', () {
      final a = PoissonPacer(meanIntervalMs: 50, random: Random(1));
      final b = PoissonPacer(meanIntervalMs: 50, random: Random(1));
      final seqA = List.generate(10, (_) => a.nextIntervalMs());
      final seqB = List.generate(10, (_) => b.nextIntervalMs());
      expect(seqA, equals(seqB));
    });
  });
}
