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
      if (!_sameAddress(datagram.address, resolverAddress) ||
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

  /// Compares the parsed address, not its spelling.
  ///
  /// [InternetAddress.address] returns whatever text produced the value —
  /// [_resolve] keeps a literal exactly as the caller wrote it — while a
  /// received [Datagram]'s address is always the canonical form the
  /// platform renders. The same IPv6 host in two legal spellings would
  /// otherwise never match, and every datagram from a real resolver would
  /// be silently dropped by the source filter above.
  static bool _sameAddress(InternetAddress a, InternetAddress b) {
    final ra = a.rawAddress;
    final rb = b.rawAddress;
    if (ra.length != rb.length) return false;
    for (var i = 0; i < ra.length; i++) {
      if (ra[i] != rb[i]) return false;
    }
    return true;
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

  /// The largest a DNS message can legally be: the length a TCP or DoH
  /// framing gives it is 16 bits wide. Bounds both the declared
  /// `Content-Length` and the body actually read, independent of it.
  static const int _maxDnsMessageBytes = 0xFFFF;

  @override
  String get label => 'doh:${endpoint.host}';

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    if (_disposed) throw StateError('$label transport is disposed');
    // One deadline for the whole exchange: opening the POST, receiving the
    // response headers and reading the body all race the same timer, so
    // the call ends inside [timeout] whichever stage is the slow one —
    // the promise TxtQueryTransport.exchange makes. A timer rather than a
    // clock read per stage because it is monotonic, and because it is what
    // a fake clock drives, so the bound holds the same way under test.
    final deadline = _ExchangeDeadline(timeout);
    HttpClientRequest? request;
    try {
      request = await deadline.guard<HttpClientRequest>(
        _client.postUrl(endpoint),
        '$label POST',
      );
      request.headers.set(HttpHeaders.contentTypeHeader, _dnsMessage);
      request.headers.set(HttpHeaders.acceptHeader, _dnsMessage);
      request.headers.contentLength = query.length;
      request.add(query);
      final response = await deadline.guard(request.close(), '$label response');
      // The status is known the moment the headers arrive, so it is judged
      // before the body: an endpoint refusing service is the one most
      // likely to hang its body, and that hang must neither spend the rest
      // of the budget nor surface as a body timeout in place of the
      // refusal. Nothing in that body is wanted, so it is aborted, not
      // drained — a drain would wait on the same hang.
      if (response.statusCode != HttpStatus.ok) {
        unawaited(response.listen(null, cancelOnError: true).cancel());
        throw HttpException(
          '$label answered ${response.statusCode}',
          uri: endpoint,
        );
      }
      // A DNS message cannot legally exceed the 16-bit length a TCP/DoH
      // framing would give it; a declared length past that is not a bigger
      // answer, it is an endpoint (or an intercepting proxy) about to hand
      // back far more than a DNS response, and there is no reason to read
      // any of it. Checked before the body, same reasoning as the status.
      final declared = response.contentLength;
      if (declared > _maxDnsMessageBytes) {
        unawaited(response.listen(null, cancelOnError: true).cancel());
        throw HttpException(
          '$label declared $declared bytes > $_maxDnsMessageBytes',
          uri: endpoint,
        );
      }
      final body = await _collect(response, deadline);
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
    } catch (error) {
      // The deadline firing mid-request (or any other failure once a
      // request exists) otherwise leaves the connection held open in
      // [_client] until dispose() — on the filtered network this lane
      // exists for, that is one held socket per retry. Best-effort: if
      // abort itself throws, [error] is still what this exchange failed
      // with, not a cleanup failure masking it.
      try {
        request?.abort();
      } catch (_) {
        // Cleanup failing is not this exchange's failure; fall through to
        // rethrow the real one.
      }
      rethrow;
    } finally {
      deadline.cancel();
    }
  }

  Future<Uint8List> _collect(
    HttpClientResponse response,
    _ExchangeDeadline deadline,
  ) {
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    final done = Completer<Uint8List>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        received += chunk.length;
        // A running cap independent of Content-Length: a header can be
        // absent, wrong, or (with autoUncompress) describe the compressed
        // size while this counts the inflated bytes actually delivered.
        // Cancelling here, not after building the whole BytesBuilder, is
        // what keeps a hostile or misbehaving endpoint from growing this
        // buffer past the cap in the first place.
        if (received > _maxDnsMessageBytes) {
          if (!done.isCompleted) {
            done.completeError(
              HttpException('$label body exceeded $_maxDnsMessageBytes bytes'),
            );
          }
          unawaited(subscription.cancel());
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    return deadline.guard(done.future, '$label body').whenComplete(() {
      // Only the deadline can end this wait while the body is still open;
      // a body that finished or failed has already closed its subscription.
      if (!done.isCompleted) unawaited(subscription.cancel());
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _client.close(force: true);
  }
}

/// The single budget every stage of one [DohQueryTransport.exchange] shares.
///
/// Each stage races the same timer, so the stages spend the budget between
/// them rather than each taking all of it; the exchange as a whole ends
/// within [timeout] no matter which stage stalls.
class _ExchangeDeadline {
  _ExchangeDeadline(this.timeout) {
    _timer = Timer(timeout, () => _expired.complete());
  }

  final Duration timeout;
  final Completer<void> _expired = Completer<void>();
  late final Timer _timer;

  /// Completes with the outcome of [work], or fails with a [TimeoutException]
  /// naming [stage] when the deadline passes first. Whatever [work] does
  /// after that is dropped, never reported a second time.
  Future<T> guard<T>(Future<T> work, String stage) {
    final result = Completer<T>();
    unawaited(
      work.then(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    unawaited(
      _expired.future.then((_) {
        if (!result.isCompleted) {
          result.completeError(TimeoutException('$stage timed out', timeout));
        }
      }),
    );
    return result.future;
  }

  /// Stops the timer once the exchange has ended, one way or the other.
  void cancel() => _timer.cancel();
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
      final parsed = InternetAddress.tryParse(parts[1]);
      if (parsed == null) continue;
      // `tryParse` validates but keeps the spelling it was given, so one
      // address written two legal ways would pass as two resolvers. The
      // entry is rebuilt from the address bytes instead: its text is then
      // a function of the bytes alone, and the dedupe below is a dedupe on
      // the address, not on how the file spelt it.
      final address = InternetAddress.fromRawAddress(parsed.rawAddress);
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

/// Per-query wait derived from measured round trips, in the shape of
/// RFC 6298 (SRTT / RTTVAR, RTO = SRTT + 4·RTTVAR), bounded below by [floor]
/// and above by [ceiling].
///
/// Before the first sample the wait is the full [ceiling] — the configured
/// per-query timeout, which is exactly what a lane with one attempt per
/// chunk waits. Each answered query feeds [sample]; each unanswered one
/// calls [backoff], which doubles the next wait (still capped at [ceiling])
/// until an answer arrives again. So on a 20 ms link a lost query costs a
/// few hundred milliseconds instead of the whole timeout, and on a 2 s link
/// the estimate grows past the ceiling and the lane simply waits the
/// ceiling, as before.
///
/// The floor exists because a DNS round trip on a good link is tens of
/// milliseconds and SRTT + 4·RTTVAR would then be under 100 ms: a jittery
/// link would re-send before its answer arrived, doubling the load on the
/// thin links this lane is for. 300 ms is the same order as a TCP stack's
/// minimum RTO (Linux uses 200 ms).
final class TxtQueryRto {
  TxtQueryRto({
    required this.ceiling,
    this.floor = const Duration(milliseconds: 300),
    this.freshFor = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (floor > ceiling) {
      throw ArgumentError.value(floor, 'floor', 'must not exceed ceiling');
    }
  }

  /// The most the lane ever waits for one query: its configured timeout.
  final Duration ceiling;

  /// The least it waits once it has samples.
  final Duration floor;

  /// How long after the last answered query the estimate is trusted.
  ///
  /// While it is fresh, a lost query is taken as loss and the backoff holds
  /// at twice the estimate: a sender with at most one datagram in flight
  /// cannot congest the link it measures, and doubling further only delays
  /// recovery — at 60 % loss the number of attempts inside a budget is the
  /// whole game. Once no answer has arrived for this long the round trip
  /// may have stepped (a network switch, a newly loaded link) and every
  /// reply would land after a capped timer, so the wait doubles toward
  /// [ceiling] until an answer teaches the new round trip (RFC 6298 §5.5).
  /// Measured second lens, 2026-09-13: a hard 2× cap after a 100 → 900 ms
  /// step never samples again; the doubling recovers by the third attempt.
  final Duration freshFor;

  final DateTime Function() _clock;
  Duration? _srtt;
  Duration? _rttvar;
  Duration? _backedOff;
  DateTime? _lastSampleAt;

  /// Round trips fed to [sample] so far.
  int samples = 0;

  /// The smoothed round trip, or null before the first sample.
  Duration? get smoothedRtt => _srtt;

  /// The un-backed-off estimate: SRTT + 4·RTTVAR clamped, or the ceiling
  /// before the first sample.
  Duration get estimate {
    final srtt = _srtt;
    final rttvar = _rttvar;
    if (srtt == null || rttvar == null) return ceiling;
    return _clamp(srtt + rttvar * 4);
  }

  /// The wait for the next query.
  Duration get next => _backedOff ?? estimate;

  /// Whether the last answer is younger than [freshFor].
  bool get isFresh {
    final last = _lastSampleAt;
    return last != null && _clock().difference(last) <= freshFor;
  }

  /// Records an answered query's round trip (RFC 6298 §2.2–2.3) and clears
  /// any backoff.
  void sample(Duration rtt) {
    final r = rtt.isNegative ? Duration.zero : rtt;
    final srtt = _srtt;
    final rttvar = _rttvar;
    if (srtt == null || rttvar == null) {
      _srtt = r;
      _rttvar = r ~/ 2;
    } else {
      final delta = (srtt - r).abs();
      _rttvar = (rttvar * 3 + delta) ~/ 4;
      _srtt = (srtt * 7 + r) ~/ 8;
    }
    _backedOff = null;
    _lastSampleAt = _clock();
    samples += 1;
  }

  /// Raises the next wait after an unanswered or refused query: to twice
  /// the estimate and no further while the estimate [isFresh], doubling
  /// toward [ceiling] once it is stale.
  void backoff() {
    final doubled = _clamp(next * 2);
    if (!isFresh) {
      _backedOff = doubled;
      return;
    }
    final cap = _clamp(estimate * 2);
    _backedOff = doubled < cap ? doubled : cap;
  }

  Duration _clamp(Duration d) =>
      d < floor ? floor : (d > ceiling ? ceiling : d);
}
