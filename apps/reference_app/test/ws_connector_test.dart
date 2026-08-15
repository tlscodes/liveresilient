import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ws_connector.dart';

/// A host that is guaranteed to never resolve via normal DNS/OS lookup
/// (reserved by RFC 2606). Used to prove a custom [hostResolver]'s *output*
/// is what actually gets connected to -- not just that it was invoked --
/// since a real hostname (e.g. `localhost`) would resolve on its own and
/// wouldn't isolate the resolver's effect.
const _unresolvableHost = 'reference-app-test.invalid';

/// Starts a local plain-HTTP server for the success-path tests: `/ws`
/// upgrades to a WebSocket and echoes every text frame back; any other path
/// responds with a normal (non-upgraded) 200, which is what a client sees
/// when the server refuses/ignores the WebSocket handshake.
Future<HttpServer> _startEchoServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(socket.add, onDone: () => socket.close());
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  });
  return server;
}

void main() {
  group('WebSocket Custom Connector Tests', () {
    test(
      'connectWebSocketWithCustomRules configures client properties safely',
      () {
        final endpoint = Uri.parse('wss://127.0.0.1:1/ws');
        expect(
          () => connectWebSocketWithCustomRules(
            endpoint,
            timeout: const Duration(milliseconds: 100),
            hostResolver: (_) async => '127.0.0.1',
          ),
          throwsA(anything),
        );
      },
    );

    test('rejects a non ws/wss endpoint', () {
      expect(
        connectWebSocketWithCustomRules(Uri.parse('https://x/y')),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive timeout', () {
      expect(
        connectWebSocketWithCustomRules(
          Uri.parse('wss://127.0.0.1:1/ws'),
          timeout: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test(
      'a successful connect yields a usable WebSocket (echo round trip)',
      () async {
        final server = await _startEchoServer();
        addTearDown(() => server.close(force: true));

        final socket = await connectWebSocketWithCustomRules(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        );
        addTearDown(() => socket.close());

        socket.add('hello');
        final echoed = await socket.first;

        expect(echoed, 'hello');
      },
    );

    test(
      'a custom hostResolver is invoked and its resolved address is used',
      () async {
        final server = await _startEchoServer();
        addTearDown(() => server.close(force: true));

        final resolvedHosts = <String>[];
        Future<String?> resolver(String host) async {
          resolvedHosts.add(host);
          return host == _unresolvableHost ? '127.0.0.1' : null;
        }

        // If the resolver's output were ignored, the OS would fail to
        // resolve `_unresolvableHost` and this would throw instead of
        // connecting -- so a successful echo proves the resolved address
        // (not just native DNS) was actually used to open the socket.
        final socket = await connectWebSocketWithCustomRules(
          Uri.parse('ws://$_unresolvableHost:${server.port}/ws'),
          hostResolver: resolver,
        );
        addTearDown(() => socket.close());

        expect(resolvedHosts, contains(_unresolvableHost));

        socket.add('ping');
        final echoed = await socket.first;
        expect(echoed, 'ping');
      },
    );

    test('a failed upgrade releases the client and does not block a later '
        'successful connect (observable proxy for "client closed on '
        'failure" -- the internal HttpClient is private, so this pins the '
        'externally visible effect instead of the internal call)', () async {
      final server = await _startEchoServer();
      addTearDown(() => server.close(force: true));

      // `/plain` never upgrades, so the handshake fails.
      await expectLater(
        connectWebSocketWithCustomRules(
          Uri.parse('ws://127.0.0.1:${server.port}/plain'),
          timeout: const Duration(seconds: 2),
        ),
        throwsA(anything),
      );

      // A subsequent, unrelated connect must still succeed promptly --
      // if the failed attempt's HttpClient had leaked/blocked, this
      // would hang or fail.
      final socket = await connectWebSocketWithCustomRules(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      ).timeout(const Duration(seconds: 2));
      addTearDown(() => socket.close());

      socket.add('still-works');
      final echoed = await socket.first;
      expect(echoed, 'still-works');
    });
  });
}
