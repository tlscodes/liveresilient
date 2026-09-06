import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../host_port.dart';

/// Carries one DNS message out and brings one back.
///
/// The valve has two ways off a phone, and they fail in different places, so
/// the lane holds both and rotates: [Udp53QueryTransport] is the classic
/// port-53 path a captive network usually still forwards, and
/// [DohQueryTransport] (RFC 8484) survives where UDP/53 is filtered or where
/// an IPv6-only cellular network has no route to an IPv4 resolver literal.
abstract class TxtQueryTransport {
  /// Short, stable name for logs and lane telemetry.
  String get label;

  /// Sends [query] and returns the answer whose transaction id is [txid].
  ///
  /// Throws [TimeoutException] when nothing matching arrives inside
  /// [timeout], and a [SocketException]/[HttpException] when the path
  /// itself failed. Both are failures; only the caller decides what a run
  /// of them means.
  Future<Uint8List> exchange(Uint8List query, int txid, Duration timeout);

  Future<void> dispose();
}

/// Plain DNS over UDP to one resolver.
///
/// The socket is bound once and reused, and only datagrams from the
/// resolver's own address and port are considered, so an unrelated host
/// cannot answer for it. Nothing here is desktop-only: `RawDatagramSocket`
/// is the same class on iOS and Android.
class Udp53QueryTransport implements TxtQueryTransport {
  Udp53QueryTransport(this.resolver);

  /// Where the query goes. Port 53 unless the deployment moved it.
  final HostPort resolver;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  InternetAddress? _address;
  final Map<int, Completer<Uint8List>> _pending = <int, Completer<Uint8List>>{};
  bool _disposed = false;

  @override
  String get label => 'udp53:${resolver.authority}';

  Future<InternetAddress> _resolve() async {
    final cached = _address;
    if (cached != null) return cached;
    final parsed = InternetAddress.tryParse(resolver.host);
    final address =
        parsed ?? (await InternetAddress.lookup(resolver.host)).first;
    _address = address;
    return address;
  }

  Future<RawDatagramSocket> _ensureSocket(
    InternetAddress resolverAddress,
  ) async {
    final existing = _socket;
    if (existing != null) return existing;
    final v6 = resolverAddress.type == InternetAddressType.IPv6;
    final bindTo = resolverAddress.isLoopback
        ? (v6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4)
        : (v6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4);
    final socket = await RawDatagramSocket.bind(bindTo, 0);
    if (_disposed) {
      socket.close();
      throw StateError('$label transport disposed while binding');
    }
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      if (datagram.address.address != resolverAddress.address ||
          datagram.port != resolver.port) {
        return;
      }
      final data = datagram.data;
      if (data.length < 2) return;
      final answered = (data[0] << 8) | data[1];
      final waiting = _pending.remove(answered);
      if (waiting != null && !waiting.isCompleted) waiting.complete(data);
    });
    return socket;
  }

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    if (_disposed) throw StateError('$label transport is disposed');
    final address = await _resolve();
    final socket = await _ensureSocket(address);
    final completer = Completer<Uint8List>();
    _pending[txid] = completer;
    try {
      final sent = socket.send(query, address, resolver.port);
      if (sent != query.length) {
        throw SocketException('$label sent $sent of ${query.length} bytes');
      }
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(txid);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(StateError('$label transport disposed'));
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }
}

/// DNS over HTTPS, RFC 8484: the same DNS message, POSTed as
/// `application/dns-message`.
///
/// This is the path that keeps working where port 53 is filtered, and the
/// only one that needs no resolver address at all — the endpoint is a
/// hostname, so the platform resolver and its NAT64 synthesis handle
/// reaching it on an IPv6-only network.
class DohQueryTransport implements TxtQueryTransport {
  DohQueryTransport(this.endpoint, {HttpClient? client})
    : _client = client ?? HttpClient();

  /// A resolver's RFC 8484 endpoint, for example
  /// `https://cloudflare-dns.com/dns-query`.
  final Uri endpoint;

  final HttpClient _client;
  bool _disposed = false;

  static const String _dnsMessage = 'application/dns-message';

  @override
  String get label => 'doh:${endpoint.host}';

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    if (_disposed) throw StateError('$label transport is disposed');
    final request = await _client.postUrl(endpoint).timeout(timeout);
    request.headers.set(HttpHeaders.contentTypeHeader, _dnsMessage);
    request.headers.set(HttpHeaders.acceptHeader, _dnsMessage);
    request.headers.contentLength = query.length;
    request.add(query);
    final response = await request.close().timeout(timeout);
    final body = await _collect(response, timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        '$label answered ${response.statusCode}',
        uri: endpoint,
      );
    }
    if (body.length < 2) {
      throw HttpException(
        '$label answered ${body.length} bytes',
        uri: endpoint,
      );
    }
    final answered = (body[0] << 8) | body[1];
    if (answered != txid) {
      throw HttpException(
        '$label answered txid $answered, wanted $txid',
        uri: endpoint,
      );
    }
    return body;
  }

  Future<Uint8List> _collect(HttpClientResponse response, Duration timeout) {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      bytes.add,
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    return done.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(subscription.cancel());
        throw TimeoutException('$label body timed out', timeout);
      },
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _client.close(force: true);
  }
}

/// Where the valve's queries can be aimed on this device.
///
/// The list is ordered by how likely each entry is to work from inside a
/// restricted network, not by speed: the network's own resolver first
/// (a captive portal answers it because it must), then well-known public
/// resolvers, then DNS over HTTPS for the case where port 53 is filtered
/// outright.
abstract final class TxtQueryResolvers {
  /// Resolvers reachable on every platform, used when the system's own is
  /// not discoverable — which is the normal case on iOS and Android.
  static const List<HostPort> publicResolvers = <HostPort>[
    HostPort(host: '1.1.1.1', port: 53),
    HostPort(host: '8.8.8.8', port: 53),
    HostPort(host: '9.9.9.9', port: 53),
  ];

  /// RFC 8484 endpoints matching [publicResolvers], as the fallback for a
  /// network that filters port 53.
  static final List<Uri> publicDohEndpoints = <Uri>[
    Uri.parse('https://cloudflare-dns.com/dns-query'),
    Uri.parse('https://dns.google/dns-query'),
  ];

  /// The system resolvers named in `/etc/resolv.conf`, or an empty list.
  ///
  /// Present and meaningful on macOS, Linux and Windows-with-WSL; absent on
  /// Android and unreadable in the iOS sandbox. Absence is not an error —
  /// it is the reason [candidates] falls through to [publicResolvers].
  static List<HostPort> systemResolvers({String path = '/etc/resolv.conf'}) {
    try {
      final file = File(path);
      if (!file.existsSync()) return const <HostPort>[];
      return parseResolvConf(file.readAsStringSync());
    } on FileSystemException {
      return const <HostPort>[];
    }
  }

  /// Reads `nameserver` lines out of a resolv.conf body.
  static List<HostPort> parseResolvConf(String body) {
    final found = <HostPort>[];
    for (final rawLine in body.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2 || parts.first.toLowerCase() != 'nameserver') {
        continue;
      }
      final address = InternetAddress.tryParse(parts[1]);
      if (address == null) continue;
      final entry = HostPort(host: address.address, port: 53);
      if (!found.contains(entry)) found.add(entry);
    }
    return found;
  }

  /// The ordered resolver list this device should try.
  static List<HostPort> candidates({List<HostPort>? system}) {
    final ordered = <HostPort>[...(system ?? systemResolvers())];
    for (final resolver in publicResolvers) {
      if (!ordered.contains(resolver)) ordered.add(resolver);
    }
    return ordered;
  }
}
