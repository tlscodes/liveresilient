import 'dart:async';
import 'dart:io';

/// A robust WebSocket connection helper supporting standard host resolution,
/// optional forward-proxy configuration, and custom client rules.
///
/// [endpoint] must be a `ws`/`wss` URI. All hooks are optional and default to
/// standard direct behaviour. The internal [HttpClient] is force-closed if the
/// upgrade fails, so a failed attempt never leaks a client; on success the
/// returned [WebSocket] owns the detached socket.
Future<WebSocket> connectWebSocketWithCustomRules(
  Uri endpoint, {
  String? Function(String host)? hostResolver,
  String Function(Uri uri)? proxyResolver,
  void Function(HttpClient client)? proxyConfigurator,
  Duration timeout = const Duration(seconds: 10),
  SecurityContext? securityContext,
}) async {
  if (endpoint.scheme != 'ws' && endpoint.scheme != 'wss') {
    throw ArgumentError.value(
      endpoint.toString(),
      'endpoint',
      'Must be a ws:// or wss:// URI.',
    );
  }
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
  }

  final client = HttpClient(context: securityContext)
    ..connectionTimeout = timeout;

  if (proxyResolver != null) {
    client.findProxy = proxyResolver;
  }

  if (proxyConfigurator != null) {
    proxyConfigurator(client);
  }

  if (hostResolver != null) {
    client.connectionFactory = (url, proxyHost, proxyPort) {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      final connectHost = hostResolver(url.host) ?? url.host;
      var cancelled = false;
      final socketFuture = () async {
        final socket = await Socket.connect(
          connectHost,
          url.port,
          timeout: timeout,
        );
        if (cancelled) {
          socket.destroy();
          throw const SocketException('Connection attempt cancelled.');
        }
        if (url.scheme != 'wss' && url.scheme != 'https') return socket;
        try {
          return await SecureSocket.secure(
            socket,
            host: url.host,
            context: securityContext,
          );
        } catch (_) {
          socket.destroy();
          rethrow;
        }
      }();
      return Future.value(
        ConnectionTask.fromSocket(socketFuture, () => cancelled = true),
      );
    };
  }

  try {
    return await WebSocket.connect(
      endpoint.toString(),
      customClient: client,
    ).timeout(timeout);
  } catch (_) {
    // Failed upgrade: release the client so a bad attempt never leaks it.
    client.close(force: true);
    rethrow;
  }
}
