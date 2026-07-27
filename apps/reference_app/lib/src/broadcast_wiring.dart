/// Wiring for the broadcast layer: a real HTTP transport, and the relay
/// list a reader or publisher works over.
///
/// The `broadcast` package deliberately owns no sockets, so this is where
/// it meets `dart:io`. Everything policy-shaped lives here too — which
/// relays, how long to wait — because those are deployment decisions, not
/// protocol ones.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';

import 'call_session.dart' show defaultBorderRelayHost;

/// Environment variable naming the relays to read and publish through.
///
/// Comma-separated origins, most-preferred first, for example
/// `https://a.example,https://b.example`. More than one is the point: a
/// reader tries each in turn, so losing any single one costs reach and
/// nothing else.
const String broadcastRelaysVariable = 'BROADCAST_RELAYS';

/// Longest a single broadcast request may take.
///
/// Short on purpose. There is always another relay to try, so waiting a
/// long time on one that is being interfered with is worse than moving on.
const Duration broadcastRequestTimeout = Duration(seconds: 10);

/// Largest response body accepted from a relay.
///
/// A ceiling here, before the bytes are hashed, keeps a hostile or broken
/// relay from turning a read into an allocation. It is above the relay's
/// own object limit so a legitimate object always fits.
const int maxBroadcastResponseBytes = 256 * 1024;

/// The origins to use when the environment names none.
List<Uri> defaultBroadcastRelayOrigins() => [
  Uri(scheme: 'https', host: defaultBorderRelayHost),
];

/// Parses [environment] into the relay origins to use.
///
/// An entry that is not a usable http or https origin is skipped rather
/// than failing the whole list: one typo in a deployment variable should
/// cost that relay, not every relay.
List<Uri> broadcastRelayOrigins(Map<String, String> environment) {
  final configured = environment[broadcastRelaysVariable];
  if (configured == null || configured.trim().isEmpty) {
    return defaultBroadcastRelayOrigins();
  }
  final origins = <Uri>[];
  for (final entry in configured.split(',')) {
    final text = entry.trim();
    if (text.isEmpty) continue;
    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) continue;
    if (!parsed.isScheme('https') && !parsed.isScheme('http')) continue;
    origins.add(
      Uri(
        scheme: parsed.scheme,
        host: parsed.host,
        port: parsed.hasPort ? parsed.port : null,
      ),
    );
  }
  return origins.isEmpty ? defaultBroadcastRelayOrigins() : origins;
}

/// Builds the relay clients for [environment].
List<BroadcastRelay> broadcastRelaysFromEnvironment(
  Map<String, String> environment, {
  BroadcastHttpTransport? transport,
}) => broadcastRelaysFor(
  broadcastRelayOrigins(environment),
  transport: transport,
);

/// Builds relay clients for [origins], sharing one transport.
List<BroadcastRelay> broadcastRelaysFor(
  List<Uri> origins, {
  BroadcastHttpTransport? transport,
}) {
  final shared = transport ?? IoBroadcastHttpTransport();
  return [
    for (final origin in origins)
      HttpBroadcastRelay(origin: origin, transport: shared),
  ];
}

/// Resolves which relays to use, preferring a verified signed directory.
///
/// The precedence is deliberate. A directory the author signed is the most
/// authoritative statement of where they publish, and it can arrive over
/// any one-way channel — a photographed code, a printed page — which is the
/// only thing that reaches a device already cut off. The environment
/// variable is the operator's override for a deployment or a test, and the
/// compiled-in default is the last resort so a reader is never stranded
/// with nowhere to look.
List<Uri> resolveBroadcastRelayOrigins({
  required Map<String, String> environment,
  required DateTime now,
  RelayDirectoryStore? directory,
}) {
  final held = directory?.current;
  if (held != null && !now.isAfter(held.notAfter)) return held.origins;
  return broadcastRelayOrigins(environment);
}

/// A [BroadcastHttpTransport] over `dart:io`.
///
/// One client for every relay: connection reuse across requests is most of
/// what makes reading a chunked layer bearable on a slow link.
class IoBroadcastHttpTransport implements BroadcastHttpTransport {
  IoBroadcastHttpTransport({
    HttpClient? client,
    this.timeout = broadcastRequestTimeout,
    this.maxResponseBytes = maxBroadcastResponseBytes,
  }) : _client = client ?? (HttpClient()..connectionTimeout = timeout);

  final HttpClient _client;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  Future<BroadcastHttpResponse> get(Uri url) =>
      _send('GET', url, null).timeout(timeout);

  @override
  Future<BroadcastHttpResponse> put(Uri url, Uint8List body) =>
      _send('PUT', url, body).timeout(timeout);

  Future<BroadcastHttpResponse> _send(
    String method,
    Uri url,
    Uint8List? body,
  ) async {
    final request = await _client.openUrl(method, url);
    // Redirects are off: every address here is immutable and content
    // addressed, so a redirect can only send a reader somewhere it did not
    // name. Nothing legitimate needs one.
    request.followRedirects = false;
    if (body != null) {
      request.headers.contentType = ContentType.binary;
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return BroadcastHttpResponse(statusCode: response.statusCode);
    }
    final bytes = await _readCapped(response);
    if (bytes == null) {
      // Over the ceiling. Reported as a refusal rather than an exception:
      // to a caller this relay simply has nothing usable, and there is
      // another one to try.
      return const BroadcastHttpResponse(
        statusCode: HttpStatus.requestEntityTooLarge,
      );
    }
    return BroadcastHttpResponse(statusCode: HttpStatus.ok, body: bytes);
  }

  /// Reads the body, giving up as soon as it exceeds [maxResponseBytes].
  ///
  /// Checked while reading rather than from the declared content length,
  /// which a hostile relay controls independently of what it sends.
  Future<Uint8List?> _readCapped(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (builder.length + chunk.length > maxResponseBytes) {
        return null;
      }
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  /// Closes the underlying client. Safe to call more than once.
  void close() => _client.close(force: true);
}
