import 'dart:async';
import 'dart:io';

/// A robust WebSocket connection helper supporting standard host resolution,
/// proxy configuration, and custom client rules.
Future<WebSocket> connectWebSocketWithCustomRules(
  Uri endpoint, {
  String? Function(String host)? hostResolver,
  String Function(Uri uri)? proxyResolver,
  void Function(HttpClient client)? proxyConfigurator,
  Duration timeout = const Duration(seconds: 10),
  SecurityContext? securityContext,
}) async {
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

  return await WebSocket.connect(
    endpoint.toString(),
    customClient: client, // اصلاح نام پارامتر به کلاینت اختصاصی وب‌ساکت
  ).timeout(timeout);
}
