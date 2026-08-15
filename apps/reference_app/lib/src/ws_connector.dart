import 'dart:async';
import 'dart:io';

/// The platform's own name resolution, chosen deliberately.
///
/// Returning null is what tells the connector to fall back to the platform,
/// so behaviourally this is identical to passing nothing. That is exactly why
/// it exists: passing nothing and choosing the platform look the same in the
/// code, and the project has already lost months to that ambiguity — an
/// optional resolver nobody supplied, sitting null in production while the
/// code read as though the capability existed.
///
/// With this value, silence and choice stop looking alike. A construction
/// site that names it has decided; a construction site that omits the
/// argument has forgotten, and the architecture test can tell them apart.
Future<String?> platformHostResolution(String host) async => null;

/// A robust WebSocket connection helper supporting standard host resolution,
/// optional forward-proxy configuration, and custom client rules.
///
/// [endpoint] must be a `ws`/`wss` URI. All hooks are optional and default to
/// standard direct behaviour. The internal [HttpClient] is force-closed if the
/// upgrade fails, so a failed attempt never leaks a client; on success the
/// returned [WebSocket] owns the detached socket.
Future<WebSocket> connectWebSocketWithCustomRules(
  Uri endpoint, {
  /// Maps a host name to an address, asynchronously, once per connection
  /// attempt. Null leaves the platform's own resolution in place.
  Future<String?> Function(String host)? hostResolver,
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
      // DELIBERATE EXCEPTION, documented rather than silent: on the proxy
      // path the resolver is not consulted, because the proxy owns
      // destination name resolution — the target hostname travels to the
      // proxy inside the request, so a target-host-to-address mapping can
      // never be applied here. Before this comment existed the branch simply
      // skipped the seam, which reads identically to a bug.
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }
      var cancelled = false;
      final socketFuture = () async {
        // The seam is asynchronous and per-attempt. It is called with
        // whatever host the HTTP stack hands us, on every attempt: the name
        // is an INPUT produced at connect time, not something the caller
        // holds in advance. Awaiting here rather than in the synchronous
        // prologue costs nothing, because connectionFactory already returns
        // a Future and the ConnectionTask is still handed back promptly.
        final connectHost = (await hostResolver(url.host)) ?? url.host;
        if (cancelled) {
          throw const SocketException('Connection attempt cancelled.');
        }
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
