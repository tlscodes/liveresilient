/// Name-to-address lookup performed over an HTTPS request instead of the
/// platform's own mechanism.
///
/// This implements the extension point whose type is
/// `Future<String?> Function(String host)`: it is called once per connection
/// attempt with the host about to be connected to, and returns an address to
/// use instead, or null to leave the platform's mechanism in place.
///
/// WIRE FORM. The JSON query form, chosen because it needs no binary encoder
/// and keeps this file free of a wire-format implementation nothing else in
/// the package would reuse.
///
/// FAILURE IS NULL, NEVER AN EXCEPTION. The caller's contract is that null
/// means "fall back to the platform", so every failure here — timeout,
/// oversized body, malformed answer, unreachable endpoint — degrades to that
/// rather than escaping into the connect path and failing a connection that
/// the platform could have completed on its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Asks a configured HTTPS endpoint for the address of a name.
class HttpsNameLookup {
  /// [endpoint] is the query URL and must be https.
  ///
  /// [endpointAddress] is the endpoint's own address as a numeric literal.
  /// It is required, and it is the first half of the cycle-breaker described
  /// on [lookup]: reaching the endpoint must never itself require a lookup.
  HttpsNameLookup({
    required this.endpoint,
    required this.endpointAddress,
    this.timeout = const Duration(seconds: 3),
    this.maxResponseBytes = 8 * 1024,
    SecurityContext? securityContext,
  }) : _securityContext = securityContext {
    if (endpoint.scheme != 'https') {
      throw ArgumentError.value(
        endpoint.toString(),
        'endpoint',
        'Must be https.',
      );
    }
    if (endpointAddress.isEmpty) {
      throw ArgumentError.value(
        endpointAddress,
        'endpointAddress',
        'Required: the endpoint must be reachable without a lookup, or the '
            'lookup path has no base case.',
      );
    }
    if (InternetAddress.tryParse(endpointAddress) == null) {
      throw ArgumentError.value(
        endpointAddress,
        'endpointAddress',
        'Must be a numeric address literal, not a name. A name here would '
            'reintroduce the cycle this parameter exists to break.',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'Must be positive.',
      );
    }
  }

  /// The query URL.
  final Uri endpoint;

  /// The endpoint's own address, as a numeric literal. See [lookup].
  final String endpointAddress;

  /// Cap on one query, connect and read together. Exceeding it returns null.
  final Duration timeout;

  /// Cap on bytes read before parsing. Exceeding it returns null: an answer
  /// larger than this is not a large answer, it is a wrong one.
  final int maxResponseBytes;

  final SecurityContext? _securityContext;

  /// The tear-off a caller wires into the extension point.
  ///
  /// Named so that a construction site reads as a decision — `asResolver`
  /// against the platform's own named value — rather than as the presence or
  /// absence of an argument.
  Future<String?> Function(String host) get asResolver => lookup;

  /// Returns an address for [host], or null to fall back to the platform.
  ///
  /// THE CYCLE, and why this method has a base case. The endpoint that
  /// answers these questions has a host name of its own. Asking this class to
  /// resolve THAT name would require calling the endpoint in order to reach
  /// the endpoint — a recursion with no base case, which in practice is a
  /// hang no stack trace explains. It is closed in two places, both of them
  /// deliberate:
  ///
  ///  1. [endpointAddress] is a numeric literal, so reaching the endpoint
  ///     needs no lookup at all — enforced in the constructor;
  ///  2. a query for the endpoint's own host returns null immediately, right
  ///     here, handing that ONE name to the platform on purpose.
  ///
  ///
  /// [timeout] is an AGGREGATE deadline over the whole lookup, not a
  /// per-phase one. Per-phase caps do not bound the total: connect, headers
  /// and body each got the full allowance, and a body that trickles one byte
  /// at a time refreshed its allowance on every chunk. An endpoint behaving
  /// that way — deliberately or not — would hold the connect path open far
  /// past any figure this class advertised, while the doc claimed a cap.
  Future<String?> lookup(String host) {
    // The base cases are answered without starting a clock, so a cycle-break
    // never spends the deadline.
    if (host.isEmpty) return Future<String?>.value();
    if (host.toLowerCase() == endpoint.host.toLowerCase()) {
      return Future<String?>.value();
    }
    if (InternetAddress.tryParse(host) != null) {
      return Future<String?>.value(host);
    }
    return _lookupOverHttps(host).timeout(timeout, onTimeout: () => null);
  }

  Future<String?> _lookupOverHttps(String host) async {
    if (host.isEmpty) return null;
    // Cycle-breaker, half two. Deliberate, not an oversight: this single
    // name is resolved by the platform so that everything else can be
    // resolved by the endpoint.
    if (host.toLowerCase() == endpoint.host.toLowerCase()) return null;
    // A literal address needs no lookup and must not be sent as a name.
    if (InternetAddress.tryParse(host) != null) return host;

    final client = HttpClient(context: _securityContext)
      ..connectionTimeout = timeout
      // Cycle-breaker, half one: the socket goes straight to the numeric
      // address, while the TLS upgrade still uses the endpoint's real name
      // so certificate hostname verification stays exactly standard.
      ..connectionFactory = _connectToEndpointAddress;
    try {
      final query = endpoint.replace(
        queryParameters: <String, String>{
          ...endpoint.queryParameters,
          'name': host,
          'type': 'A',
        },
      );
      final request = await client.getUrl(query).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      if (response.contentLength > maxResponseBytes) {
        await response.drain<void>();
        return null;
      }
      final body = await _readCapped(response);
      if (body == null) return null;
      return _firstAddress(body);
    } on Object {
      // Every failure degrades to the platform. See the library doc.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<ConnectionTask<Socket>> _connectToEndpointAddress(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    var cancelled = false;
    final socketFuture = () async {
      final socket = await Socket.connect(
        endpointAddress,
        url.port,
        timeout: timeout,
      );
      if (cancelled) {
        socket.destroy();
        throw const SocketException('Lookup connection cancelled.');
      }
      try {
        return await SecureSocket.secure(
          socket,
          host: url.host,
          context: _securityContext,
        );
      } catch (_) {
        socket.destroy();
        rethrow;
      }
    }();
    return ConnectionTask.fromSocket(socketFuture, () => cancelled = true);
  }

  /// Reads at most [maxResponseBytes]; returns null the moment the body
  /// overruns, without buffering the rest.
  Future<String?> _readCapped(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        return null;
      }
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// The first address in a JSON answer, or null if the shape is not what was
  /// promised. Parsed defensively at every step: a wrong answer and a missing
  /// answer are the same outcome here.
  String? _firstAddress(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final answers = decoded['Answer'];
    if (answers is! List) return null;
    for (final answer in answers) {
      if (answer is! Map<String, Object?>) continue;
      // Type 1 is the address record; anything else (an alias, for one) is
      // not an address and must not be handed back as if it were.
      if (answer['type'] != 1) continue;
      final data = answer['data'];
      if (data is! String) continue;
      if (InternetAddress.tryParse(data) == null) continue;
      return data;
    }
    return null;
  }
}
