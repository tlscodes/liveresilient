import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// In-memory edge stream: records everything written and lets a test push
/// bytes back in whatever chunk boundaries it wants.
class _FakeEdgeConnection implements EdgeBridgeConnection {
  _FakeEdgeConnection(this.endpoint);

  final Uri endpoint;
  final List<Uint8List> written = [];
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  bool closed = false;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  void add(Uint8List frame) {
    if (closed) throw StateError('stream closed');
    written.add(frame);
  }

  void deliver(List<int> chunk) => _inbound.add(Uint8List.fromList(chunk));

  void breakStream() {
    closed = true;
    _inbound.addError(StateError('peer reset'));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _inbound.close();
  }
}

void main() {
  group('GrpcMessageFramer', () {
    const framer = GrpcMessageFramer();

    test('encodes the standard 5-byte header and nothing else', () {
      final frame = framer.encode([1, 2, 3]);
      expect(frame.length, 8);
      expect(frame[0], 0x00);
      expect(ByteData.sublistView(frame).getUint32(1), 3);
      expect(frame.sublist(5), [1, 2, 3]);
    });

    test('round-trips an empty payload', () {
      expect(framer.decode(framer.encode(const [])), isEmpty);
    });

    test('encodes a large payload with a big-endian length', () {
      final payload = List<int>.filled(300, 7);
      final frame = framer.encode(payload);
      expect(frame.sublist(1, 5), [0, 0, 0x01, 0x2C]);
      expect(framer.decode(frame), payload);
    });

    test('rejects a truncated frame', () {
      expect(() => framer.decode(Uint8List(4)), throwsFormatException);
    });

    test('rejects a length header that disagrees with the frame', () {
      final frame = framer.encode([1, 2, 3]);
      ByteData.sublistView(frame).setUint32(1, 99);
      expect(() => framer.decode(frame), throwsFormatException);
    });

    test('rejects an unsupported compression flag', () {
      final frame = framer.encode([1]);
      frame[0] = 0x01;
      expect(() => framer.decode(frame), throwsFormatException);
    });
  });

  group('GrpcFrameReader', () {
    test('reassembles messages split across chunk boundaries', () {
      const framer = GrpcMessageFramer();
      final reader = GrpcFrameReader();
      final wire = <int>[
        ...framer.encode([1, 2, 3]),
        ...framer.encode([4, 5]),
      ];

      expect(reader.add(wire.sublist(0, 3)), isEmpty);
      expect(reader.add(wire.sublist(3, 9)), [
        [1, 2, 3]
      ]);
      expect(reader.add(wire.sublist(9)), [
        [4, 5]
      ]);
    });

    test('returns several messages from one chunk', () {
      const framer = GrpcMessageFramer();
      final reader = GrpcFrameReader();
      final messages = reader.add([
        ...framer.encode([9]),
        ...framer.encode([8, 8]),
      ]);
      expect(messages, [
        [9],
        [8, 8]
      ]);
    });

    test('reset drops a half-received message', () {
      const framer = GrpcMessageFramer();
      final reader = GrpcFrameReader();
      final frame = framer.encode([1, 2, 3, 4]);
      reader.add(frame.sublist(0, 6));
      reader.reset();
      expect(reader.add(frame.sublist(6)), isEmpty);
    });

    test('rejects a length header above the receive limit', () {
      final reader = GrpcFrameReader();
      final header = Uint8List(GrpcMessageFramer.headerLength);
      ByteData.sublistView(header)
          .setUint32(1, GrpcMessageFramer.maxMessageLength + 1);
      expect(() => reader.add(header), throwsFormatException);
    });

    test('accepts a length header exactly at the receive limit', () {
      final reader = GrpcFrameReader();
      final header = Uint8List(GrpcMessageFramer.headerLength);
      ByteData.sublistView(header)
          .setUint32(1, GrpcMessageFramer.maxMessageLength);
      // Body absent, so nothing is emitted — but the header is not rejected.
      expect(reader.add(header), isEmpty);
    });
  });

  group('DomesticEdgeBridgeLane', () {
    late List<Uri> endpoints;
    late List<_FakeEdgeConnection> opened;
    late Set<Uri> failing;

    EdgeBridgeConnector connector() => (uri) async {
          if (failing.contains(uri)) throw StateError('edge $uri down');
          final connection = _FakeEdgeConnection(uri);
          opened.add(connection);
          return connection;
        };

    setUp(() {
      endpoints = [
        Uri.parse('https://edge-a.example/voice'),
        Uri.parse('https://edge-b.example/voice'),
        Uri.parse('https://edge-c.example/voice'),
      ];
      opened = [];
      failing = <Uri>{};
    });

    test('rejects an empty endpoint pool', () {
      expect(
        () => DomesticEdgeBridgeLane(
          endpoints: const [],
          connector: connector(),
        ),
        throwsArgumentError,
      );
    });

    test('sends a standard gRPC frame and nothing more', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);

      final result = await lane.send([10, 20, 30]);

      expect(result.delivered, isTrue);
      expect(opened, hasLength(1));
      expect(opened.single.written, hasLength(1));
      expect(opened.single.written.single, [0, 0, 0, 0, 3, 10, 20, 30]);
    });

    test('rotates to the next endpoint after each reconnect', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);

      final used = <Uri>[];
      for (var i = 0; i < 4; i++) {
        await lane.send([i]);
        used.add(lane.activeEndpoint!);
        opened.last.breakStream();
        await Future<void>.delayed(Duration.zero);
      }

      expect(used, [
        endpoints[0],
        endpoints[1],
        endpoints[2],
        endpoints[0],
      ]);
    });

    test('skips a dead endpoint and reports the reachable one', () async {
      failing.add(endpoints[0]);
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);

      expect(await lane.probe(), isTrue);
      expect(lane.activeEndpoint, endpoints[1]);
    });

    test('failover does not rewind the session sequence', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);

      await lane.send([1]);
      await lane.send([2]);
      expect(lane.sessionSequence, 2);

      opened.last.breakStream();
      await Future<void>.delayed(Duration.zero);

      await lane.send([3]);
      expect(lane.sessionSequence, 3);
      expect(lane.activeEndpoint, endpoints[1]);
      expect(opened.last.written.single, [0, 0, 0, 0, 1, 3]);
    });

    test('reports unavailable when the whole pool refuses', () async {
      failing.addAll(endpoints);
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);

      final result = await lane.send([1]);
      expect(result.status, SendStatus.unavailable);
      expect(await lane.probe(), isFalse);
      expect(lane.health.pathDegraded, isTrue);
    });

    test('health-check interval backs off on failure and resets on success',
        () async {
      failing.addAll(endpoints);
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
        minHealthCheckInterval: const Duration(seconds: 1),
        maxHealthCheckInterval: const Duration(seconds: 4),
      );
      addTearDown(lane.dispose);

      expect(lane.healthCheckInterval, const Duration(seconds: 1));
      await lane.probe();
      expect(lane.healthCheckInterval, const Duration(seconds: 2));
      await lane.probe();
      expect(lane.healthCheckInterval, const Duration(seconds: 4));
      await lane.probe();
      expect(lane.healthCheckInterval, const Duration(seconds: 4),
          reason: 'clamped at the ceiling');

      failing.clear();
      expect(await lane.probe(), isTrue);
      expect(lane.healthCheckInterval, const Duration(seconds: 1));
    });

    test('surfaces whole messages from chunked inbound bytes', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      addTearDown(lane.dispose);
      await lane.probe();

      final received = <List<int>>[];
      lane.received.listen(received.add);

      const framer = GrpcMessageFramer();
      final wire = framer.encode([7, 7, 7]);
      opened.single.deliver(wire.sublist(0, 2));
      opened.single.deliver(wire.sublist(2));
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        [7, 7, 7]
      ]);
    });

    test('a connect timeout is treated as an unreachable endpoint', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: [endpoints.first],
        connector: (uri) => Completer<EdgeBridgeConnection>().future,
        connectTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(lane.dispose);

      expect(await lane.probe(), isFalse);
    });

    test('send after dispose is unavailable, not a crash', () async {
      final lane = DomesticEdgeBridgeLane(
        endpoints: endpoints,
        connector: connector(),
      );
      await lane.send([1]);
      await lane.dispose();

      expect(opened.single.closed, isTrue);
      expect((await lane.send([2])).status, SendStatus.unavailable);
      expect(await lane.probe(), isFalse);
      await lane.dispose();
    });
  });
}
