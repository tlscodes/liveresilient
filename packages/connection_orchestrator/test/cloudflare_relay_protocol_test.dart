/// The border relay's protocol, exercised end to end against a loopback
/// server that implements the same routes as
/// `tools/cloudflare_relay_worker/src/worker.js`.
///
/// The real lanes do the sending: [WebSocketRelayLane] over `/ws` and
/// [HttpLongPollLane] over `/http`. Nothing leaves the machine — a test
/// pointed at a deployed worker would be measuring Cloudflare's uptime.
///
/// What is under test is the property the lanes depend on: frames come out
/// of the relay in the order they went in, byte-identical, and the gRPC
/// framing survives being concatenated by a poll and split again by the
/// reader.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// A loopback stand-in for the worker: pairs roles 'a' and 'b' by session,
/// forwards bytes verbatim, and queues for a peer that is not attached.
class _RelayServer {
  _RelayServer(this._server) {
    _server.listen(_handle);
  }

  static Future<_RelayServer> start() async =>
      _RelayServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, WebSocket> _sockets = {};
  final Map<String, List<List<int>>> _inbox = {};

  int get port => _server.port;

  Uri wsUri(String session, String role) => Uri(
    scheme: 'ws',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
    path: '/ws',
    queryParameters: {'session': session, 'role': role},
  );

  Uri httpUri(String session, String role) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
    path: '/http',
    queryParameters: {'session': session, 'role': role},
  );

  static String _key(String session, String role) => '$session/$role';
  static String _other(String role) => role == 'a' ? 'b' : 'a';

  Future<void> _handle(HttpRequest request) async {
    final session = request.uri.queryParameters['session'] ?? '';
    final role = request.uri.queryParameters['role'] ?? '';
    if (session.isEmpty || (role != 'a' && role != 'b')) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    if (request.uri.path == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      final key = _key(session, role);
      _sockets[key] = socket;
      _flush(session, role);
      socket.listen(
        (data) => _deliver(session, _other(role), data as List<int>),
        onDone: () => _sockets.remove(key),
        onError: (_) => _sockets.remove(key),
      );
      return;
    }

    switch (request.method) {
      case 'HEAD':
        request.response.statusCode = HttpStatus.noContent;
      case 'POST':
        final body = <int>[];
        await for (final chunk in request) {
          body.addAll(chunk);
        }
        _deliver(session, _other(role), body);
        request.response.statusCode = HttpStatus.noContent;
      case 'GET':
        final queued = _inbox.remove(_key(session, role)) ?? const [];
        if (queued.isEmpty) {
          request.response.statusCode = HttpStatus.noContent;
        } else {
          request.response.headers.contentType = ContentType.binary;
          for (final frame in queued) {
            request.response.add(frame);
          }
        }
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
    }
    await request.response.close();
  }

  void _deliver(String session, String role, List<int> frame) {
    final socket = _sockets[_key(session, role)];
    if (socket != null) {
      socket.add(frame);
      return;
    }
    _inbox.putIfAbsent(_key(session, role), () => []).add(List<int>.of(frame));
  }

  void _flush(String session, String role) {
    final socket = _sockets[_key(session, role)];
    final queued = _inbox.remove(_key(session, role));
    if (socket == null || queued == null) return;
    for (final frame in queued) {
      socket.add(frame);
    }
  }

  Future<void> close() async {
    for (final socket in _sockets.values) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  late _RelayServer relay;

  setUp(() async => relay = await _RelayServer.start());
  tearDown(() => relay.close());

  const framer = GrpcMessageFramer();

  /// One gRPC-framed media frame carrying [seq] as its only payload byte.
  Uint8List frameFor(int seq) => framer.encode([seq]);

  test(
    'websocket lane: frames reach the peer in order, byte-identical',
    () async {
      const session = 'ws-order';
      final lane = WebSocketRelayLane(relayUri: relay.wsUri(session, 'a'));
      addTearDown(lane.dispose);

      // The peer attaches first so nothing is queued.
      final peer = await WebSocket.connect(
        relay.wsUri(session, 'b').toString(),
      );
      addTearDown(peer.close);
      final received = <Uint8List>[];
      final reader = GrpcFrameReader();
      final done = Completer<void>();
      peer.listen((data) {
        received.addAll(reader.add(data as List<int>));
        if (received.length == 8) done.complete();
      });

      for (var seq = 0; seq < 8; seq++) {
        final result = await lane.send(frameFor(seq));
        expect(result.delivered, isTrue, reason: 'frame $seq was not accepted');
      }
      await done.future.timeout(const Duration(seconds: 5));

      expect([for (final f in received) f.single], [0, 1, 2, 3, 4, 5, 6, 7]);
    },
  );

  test(
    'websocket lane: frames sent before the peer attaches are not lost',
    () async {
      const session = 'ws-backlog';
      final lane = WebSocketRelayLane(relayUri: relay.wsUri(session, 'a'));
      addTearDown(lane.dispose);

      for (var seq = 0; seq < 4; seq++) {
        expect((await lane.send(frameFor(seq))).delivered, isTrue);
      }

      // The peer arrives late and still receives the backlog, in order.
      final peer = await WebSocket.connect(
        relay.wsUri(session, 'b').toString(),
      );
      addTearDown(peer.close);
      final reader = GrpcFrameReader();
      final received = <Uint8List>[];
      final done = Completer<void>();
      peer.listen((data) {
        received.addAll(reader.add(data as List<int>));
        if (received.length == 4) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 5));

      expect([for (final f in received) f.single], [0, 1, 2, 3]);
    },
  );

  test(
    'http lane: a poll returns concatenated frames the reader splits',
    () async {
      const session = 'http-order';
      final lane = HttpLongPollLane(sendUri: relay.httpUri(session, 'a'));
      addTearDown(lane.dispose);

      expect(await lane.probe(), isTrue, reason: 'HEAD is the liveness probe');

      for (var seq = 0; seq < 5; seq++) {
        expect((await lane.send(frameFor(seq))).delivered, isTrue);
      }

      // The peer polls once and gets all five frames in one body.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(relay.httpUri(session, 'b'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);

      final body = <int>[];
      await for (final chunk in response) {
        body.addAll(chunk);
      }
      final messages = GrpcFrameReader().add(body);
      expect([for (final m in messages) m.single], [0, 1, 2, 3, 4]);
    },
  );

  test('http lane: an empty inbox answers 204 and stays empty', () async {
    const session = 'http-empty';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(relay.httpUri(session, 'b'));
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.noContent);
  });

  test('both lanes feed one peer without interleaving a frame', () async {
    const session = 'mixed';
    final ws = WebSocketRelayLane(relayUri: relay.wsUri(session, 'a'));
    final http = HttpLongPollLane(sendUri: relay.httpUri(session, 'a'));
    addTearDown(ws.dispose);
    addTearDown(http.dispose);

    // Alternating lanes, one frame at a time, each awaited before the
    // next: the relay must not split or merge a frame across lanes.
    for (var seq = 0; seq < 6; seq++) {
      final lane = seq.isEven ? ws : http;
      expect((await lane.send(frameFor(seq))).delivered, isTrue);
    }

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(relay.httpUri(session, 'b'));
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      body.addAll(chunk);
    }

    final messages = GrpcFrameReader().add(body);
    expect([for (final m in messages) m.single], [0, 1, 2, 3, 4, 5]);
  });
}
