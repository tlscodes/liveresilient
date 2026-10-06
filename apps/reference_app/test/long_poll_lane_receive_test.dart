// The long-poll lane reads as well as writes. Sealed letters no longer
// travel this way — nothing holds a request open for them — but the lane
// still has `receive`, and this is its only test: a relay on loopback that
// keeps the border relay's long-poll contract (POST to one side queues for
// the other, GET takes the queue, frames concatenated with nothing between
// them). Lab only.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HttpLongPollLane;
import 'package:flutter_test/flutter_test.dart';

class _Relay {
  _Relay._(this._server);

  static Future<_Relay> start() async {
    final relay = _Relay._(await HttpServer.bind('127.0.0.1', 0));
    relay._server.listen(relay._serve);
    return relay;
  }

  final HttpServer _server;
  final Map<String, List<Uint8List>> _held = {};

  /// Answer 503 to everything.
  bool down = false;

  Uri uriFor(String session, String role) => Uri.parse(
    'http://127.0.0.1:${_server.port}/http?session=$session&role=$role',
  );

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final session = request.uri.queryParameters['session'];
    final role = request.uri.queryParameters['role'];
    if (down) {
      await request.drain<void>();
      response.statusCode = 503;
    } else if (request.uri.path != '/http' || session == null || role == null) {
      await request.drain<void>();
      response.statusCode = 400;
    } else if (request.method == 'POST') {
      final body = BytesBuilder();
      await for (final chunk in request) {
        body.add(chunk);
      }
      final other = role == 'a' ? 'b' : 'a';
      (_held['$session:$other'] ??= []).add(body.takeBytes());
      response.statusCode = 204;
    } else if (request.method == 'GET') {
      await request.drain<void>();
      final frames = _held.remove('$session:$role') ?? const <Uint8List>[];
      if (frames.isEmpty) {
        response.statusCode = 204;
      } else {
        response.statusCode = 200;
        for (final frame in frames) {
          response.add(frame);
        }
      }
    } else {
      await request.drain<void>();
      response.statusCode = 405;
    }
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  test('what one side posted is what the other side receives', () async {
    final relay = await _Relay.start();
    addTearDown(relay.stop);
    final a = HttpLongPollLane(sendUri: relay.uriFor('room', 'a'));
    final b = HttpLongPollLane(sendUri: relay.uriFor('room', 'b'));
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    expect(await b.receive(), isEmpty, reason: 'nothing waiting');
    await a.send([1, 2, 3]);
    await a.send([4, 5]);
    expect(await b.receive(), [1, 2, 3, 4, 5]);
    expect(await b.receive(), isEmpty, reason: 'taken once');

    relay.down = true;
    expect(await b.receive(), isNull, reason: 'the relay is down');
  });
}
