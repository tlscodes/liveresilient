import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../host_port.dart';
import '../transport_channel.dart';
import 'txt_query_transport.dart';
import 'txt_query_wire.dart';

/// Where this device should aim the TXT query lane.
///
/// [domain] is the zone the authoritative responder answers for; the lane
/// is useless without it, which is why it is the only required field. The
/// two endpoint lists are ordered candidates, not alternatives to choose
/// between — the lane holds all of them and rotates on failure, because
/// which one survives depends on the network the phone happens to be on.
class TxtQueryValve {
  const TxtQueryValve({
    required this.domain,
    this.resolvers = const <HostPort>[],
    this.dohEndpoints = const <Uri>[],
  });

  /// The valve's zone, for example `valve.example`.
  final String domain;

  /// Resolvers for the plain UDP/53 path. Empty means "discover what this
  /// device can see", which [TxtQueryLane.forValve] does through
  /// [TxtQueryResolvers.candidates].
  final List<HostPort> resolvers;

  /// RFC 8484 endpoints for the DNS-over-HTTPS path. Empty means
  /// [TxtQueryResolvers.publicDohEndpoints].
  final List<Uri> dohEndpoints;

  /// Whether this configuration can produce a lane at all.
  bool get isUsable => domain.trim().isNotEmpty;
}

/// Fallback lane that carries payload bytes inside DNS TXT queries.
///
/// The lane speaks the DNS wire format itself ([TxtQueryWire]) and talks to
/// ordinary resolvers, so it runs on every platform Flutter targets —
/// including iOS and Android, which cannot host the Python sidecar the
/// previous version of this lane depended on. Nothing in this file touches
/// `Platform`, `Process` or the file system.
///
/// One payload becomes one session of chunked queries: 39 raw bytes per
/// query name, sent in order, each answered by the responder's TXT record.
/// A payload of `n` bytes costs `ceil((n + 2) / 39)` round trips, which is
/// why the lane sits last in the ladder and carries a low
/// [ChannelHealth.bandwidth].
///
/// Failure handling mirrors the Python client this replaces: [failThreshold]
/// failures inside [failWindow] declare the valve DOWN, and DOWN is
/// terminal. A DOWN valve reports [SendStatus.unavailable], which sets
/// [ChannelHealth.pathDegraded] and drops the lane's score to zero, so the
/// fabric ranks it last and continues to the next lane that is still up.
/// Before that, a failed exchange rotates to the next candidate transport,
/// so a network that filters UDP/53 costs one failed send rather than the
/// whole lane.
///
/// Two refusals happen before the wire and leave [health] untouched, because
/// they say nothing about the path: a payload longer than [maxPayloadBytes],
/// and any send after [dispose].
class TxtQueryLane implements TransportChannel {
  /// Builds a lane over an explicit transport list, in the order to try.
  ///
  /// Prefer [TxtQueryLane.forValve] in apps; this constructor is for tests
  /// and for deployments that know exactly which resolver to use.
  TxtQueryLane({
    required this.domain,
    required List<TxtQueryTransport> transports,
    Duration timeout = const Duration(seconds: 4),
    this.failThreshold = 5,
    this.failWindow = const Duration(seconds: 60),
    String name = 'dns-valve',
  }) : _transports = List<TxtQueryTransport>.unmodifiable(transports),
       _timeout = timeout,
       _name = name,
       health = ChannelHealth(reliabilityPrior: 0.4, bandwidth: 0.05) {
    if (domain.trim().isEmpty) {
      throw ArgumentError.value(domain, 'domain', 'must name the valve zone');
    }
    if (transports.isEmpty) {
      throw ArgumentError.value(transports, 'transports', 'must not be empty');
    }
    if (failThreshold < 1) {
      throw ArgumentError.value(failThreshold, 'failThreshold', 'must be >= 1');
    }
  }

  /// Builds a lane from [valve], discovering this device's resolvers when
  /// the configuration does not name any.
  ///
  /// The candidate order is deliberate: the system's own resolvers first
  /// (a restricted network answers those because it has to), then the
  /// public resolvers, then DNS over HTTPS for a network that filters port
  /// 53 outright. On iOS and Android the first group is normally empty and
  /// the lane starts at the public resolvers.
  factory TxtQueryLane.forValve(
    TxtQueryValve valve, {
    Duration timeout = const Duration(seconds: 4),
    int failThreshold = 5,
    Duration failWindow = const Duration(seconds: 60),
    String name = 'dns-valve',
  }) {
    final resolvers = valve.resolvers.isNotEmpty
        ? valve.resolvers
        : TxtQueryResolvers.candidates();
    final doh = valve.dohEndpoints.isNotEmpty
        ? valve.dohEndpoints
        : TxtQueryResolvers.publicDohEndpoints;
    return TxtQueryLane(
      domain: valve.domain,
      transports: <TxtQueryTransport>[
        for (final resolver in resolvers) Udp53QueryTransport(resolver),
        for (final endpoint in doh) DohQueryTransport(endpoint),
      ],
      timeout: timeout,
      failThreshold: failThreshold,
      failWindow: failWindow,
      name: name,
    );
  }

  /// The most one payload may carry.
  ///
  /// The limit is policy, not a wire constraint: the sequence label holds
  /// far more chunks than this, but a payload of this size already costs
  /// 106 round trips. A longer one is refused as [SendStatus.transient] so
  /// the selector moves on to a lane that can carry it, instead of this one
  /// spending minutes on a frame another lane would deliver at once.
  static const int maxPayloadBytes = 4096;

  /// The valve's zone.
  final String domain;

  /// Failures inside [failWindow] that declare the valve DOWN.
  final int failThreshold;

  /// Sliding window the failure count is measured over.
  final Duration failWindow;

  final List<TxtQueryTransport> _transports;
  final Duration _timeout;
  final String _name;
  final Random _txids = Random.secure();
  final List<DateTime> _failures = <DateTime>[];

  int _transportIndex = 0;
  bool _down = false;
  bool _disposed = false;
  Future<void> _inFlight = Future<void>.value();

  /// Queries this lane has put on the wire, and answers that came back.
  int attempts = 0;
  int replies = 0;

  /// Bytes the responder returned for the last delivered payload.
  Uint8List? lastReply;

  /// Session id of the last payload sent, which is what a responder-side
  /// log correlates against.
  String? lastSessionId;

  @override
  final ChannelHealth health;

  @override
  String get name => _name;

  /// Whether the valve has been declared DOWN. Terminal: a DOWN lane never
  /// queries again, so the fabric is not held up by a dead path.
  bool get isDown => _down;

  /// The transport the next exchange will use.
  TxtQueryTransport get currentTransport => _transports[_transportIndex];

  @override
  Future<SendResult> send(List<int> payload) async {
    if (_disposed) {
      return SendResult(
        SendStatus.unavailable,
        error: StateError('$_name lane is disposed'),
      );
    }
    if (payload.length > maxPayloadBytes) {
      return SendResult(
        SendStatus.transient,
        error: ArgumentError.value(
          payload.length,
          'payload',
          'exceeds the lane limit of $maxPayloadBytes bytes',
        ),
      );
    }
    // One payload at a time: a session's chunks are ordered, and two
    // interleaved payloads would each be waiting on the other's answers.
    final mine = _inFlight.then((_) => _carry(payload));
    _inFlight = mine.then((_) {}, onError: (_) {});
    final result = await mine;
    health.observe(result);
    return result;
  }

  Future<SendResult> _carry(List<int> payload) async {
    if (_down) {
      return SendResult(
        SendStatus.unavailable,
        error: StateError('$_name valve is DOWN'),
      );
    }
    final started = DateTime.now();
    final encoded = TxtQueryWire.encodeQueries(payload, domain);
    lastSessionId = encoded.sessionId;
    Uint8List? answer;
    // The first chunk is also the probe: until one has been answered, a
    // failure means "this transport does not work here", so rotate and try
    // the same chunk on the next candidate. Re-sending chunk zero is safe —
    // the responder keys chunks by sequence number, not by arrival.
    var rotationsLeft = _transports.length - 1;
    for (var index = 0; index < encoded.names.length; index++) {
      while (true) {
        try {
          answer = await _query(encoded.names[index]);
          break;
        } catch (error) {
          if (_recordFailure()) {
            return SendResult(
              SendStatus.unavailable,
              error: StateError('$_name valve is DOWN: $error'),
            );
          }
          _rotateTransport();
          if (index > 0 || rotationsLeft <= 0) {
            return SendResult(SendStatus.transient, error: error);
          }
          rotationsLeft -= 1;
        }
      }
    }
    _failures.clear();
    lastReply = answer;
    return SendResult(
      SendStatus.ok,
      rttMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  /// Sends one query name and returns the bytes its TXT answer carried.
  Future<Uint8List> _query(String queryName) async {
    // A random transaction id per query (RFC 5452): a sequential one is
    // guessable, and this path talks to resolvers it does not control.
    final txid = _txids.nextInt(0x10000);
    final packet = TxtQueryWire.buildDnsQueryPacket(txid, queryName);
    attempts += 1;
    final response = await currentTransport.exchange(packet, txid, _timeout);
    final answer = TxtQueryWire.parseDnsAnswerPacket(response);
    if (answer.txid != txid) {
      throw TxtQueryWireException('answer txid ${answer.txid} != $txid');
    }
    final carried = answer.payload;
    if (answer.rcode != TxtQueryWire.rcodeNoError || carried == null) {
      throw TxtQueryWireException('rcode=${answer.rcode}');
    }
    replies += 1;
    try {
      return TxtQueryWire.unframeDown(carried);
    } on TxtQueryWireException {
      // An answer that is not framed is still an answer: the responder may
      // be serving a plain TXT record rather than the tunnel's own.
      return carried;
    }
  }

  /// Records one failure and reports whether it declared the valve DOWN.
  bool _recordFailure() {
    final now = DateTime.now();
    _failures.add(now);
    _failures.removeWhere((at) => now.difference(at) > failWindow);
    if (_failures.length >= failThreshold) {
      _down = true;
      return true;
    }
    return false;
  }

  void _rotateTransport() {
    _transportIndex = (_transportIndex + 1) % _transports.length;
  }

  @override
  Future<bool> probe() async => (await send(const <int>[])).delivered;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final transport in _transports) {
      await transport.dispose();
    }
  }
}
