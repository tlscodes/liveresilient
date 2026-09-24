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
    this.attemptsPerChunk = 1,
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
    if (attemptsPerChunk < 1) {
      throw ArgumentError.value(
        attemptsPerChunk,
        'attemptsPerChunk',
        'must be >= 1',
      );
    }
  }

  /// How many times one chunk is sent on the current transport before the
  /// lane gives up on that transport.
  ///
  /// 1 is the strict policy: an unanswered chunk ends the send (the first
  /// chunk still probes every candidate). Above 1 the lane treats an
  /// unanswered query as what it usually is on the networks this lane
  /// exists for — a lost datagram, not a dead transport: the chunk is
  /// re-sent under a fresh transaction id, the wait per attempt follows the
  /// measured round trip of that transport ([TxtQueryRto]) instead of the
  /// full timeout, and once the attempts are spent the lane rotates to the
  /// next candidate mid-session as well. Re-sending is safe: the responder
  /// keys chunks by session id and sequence number, so a duplicate is
  /// idempotent, and a late answer to an earlier attempt fails the txid
  /// check. A whole send still counts as ONE failure against
  /// [failThreshold].
  ///
  /// The arithmetic behind the default [forValve] uses (a model, i.i.d.
  /// loss, not a measurement): a chunk needs its query and its answer to
  /// arrive, so at 10 % loss one attempt succeeds 81 % of the time and a
  /// four-chunk payload 43 %; with three attempts the chunk succeeds 99.3 %
  /// and the payload 97 %.
  final int attemptsPerChunk;

  /// One round-trip estimator per transport (a DoH endpoint and a UDP
  /// resolver do not share a round trip), created on first use.
  final Map<TxtQueryTransport, TxtQueryRto> _rtos =
      <TxtQueryTransport, TxtQueryRto>{};

  /// Builds a lane from [valve], discovering this device's resolvers when
  /// the configuration does not name any.
  ///
  /// The candidate order is deliberate: the system's own resolvers first
  /// (a restricted network answers those because it has to), then the
  /// public resolvers, then DNS over HTTPS for a network that filters port
  /// 53 outright. On iOS and Android the first group is normally empty and
  /// the lane starts at the public resolvers.
  ///
  /// Apps get the retry policy by default: this is the constructor the
  /// phone uses, and the phone is on the lossy link. The count is a safety
  /// cap; [chunkBudget] (time, derived from the responder's session TTL
  /// and the candidate count) is what actually bounds the attempts, so on a
  /// dead transport the lane still rotates after two or three waits while
  /// on a live lossy link it keeps re-sending. The arithmetic at 60 % i.i.d.
  /// loss (each attempt succeeds 0.4 × 0.4 = 16 %): three attempts deliver
  /// a one-chunk payload 41 % of the time, twenty inside the budget 97 %.
  /// On the rig, 2026-09-13, three attempts did lose that payload.
  factory TxtQueryLane.forValve(
    TxtQueryValve valve, {
    Duration timeout = const Duration(seconds: 4),
    int failThreshold = 5,
    Duration failWindow = const Duration(seconds: 60),
    int attemptsPerChunk = 24,
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
      attemptsPerChunk: attemptsPerChunk,
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

  /// Every candidate, in the order the lane rotates through them.
  List<TxtQueryTransport> get transports => _transports;

  /// Makes [transport] the one the next exchange starts on — the path a
  /// [TxtLetterProbe] saw reach the responder first. Rotation after it is
  /// unchanged. False when [transport] is not one of this lane's.
  bool preferTransport(TxtQueryTransport transport) {
    final at = _transports.indexOf(transport);
    if (at < 0) return false;
    _transportIndex = at;
    return true;
  }

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
    final EncodedQueries encoded;
    try {
      encoded = TxtQueryWire.encodeQueries(payload, domain);
    } on TxtQueryWireException catch (error) {
      // A domain the wire layer refuses (bad label, FQDN too long) is a
      // configuration problem, not a transport failure — it is the same on
      // every attempt, so it is reported like any other failed send instead
      // of throwing past health.observe in send() above.
      return SendResult(SendStatus.transient, error: error);
    }
    lastSessionId = encoded.sessionId;
    Uint8List? answer;
    // The first chunk is also the probe: until one has been answered, a
    // failure means "this transport does not work here", so rotate and try
    // the same chunk on the next candidate. Re-sending a chunk is safe on
    // any transport — the responder keys chunks by session id and sequence
    // number, not by arrival or by resolver.
    //
    // With [attemptsPerChunk] above 1 a chunk is first re-sent on the
    // current transport — at most that many times and for at most
    // [chunkBudget] — and once those are spent the lane rotates for that
    // chunk too, mid-session: a resolver that stops answering after chunk
    // zero is what a mobile-data-to-wifi switch looks like, and the session
    // outlives it on the responder ([responderSessionTtl]).
    final budget = chunkBudget;
    var rotationsLeft = _transports.length - 1;
    for (var index = 0; index < encoded.names.length; index++) {
      var attemptsLeft = attemptsPerChunk;
      // The budget is charged in timer values, not wall-clock: an
      // unanswered attempt spent exactly the wait it was handed, and a
      // paced retry after a fast negative spends the same, so on a real
      // link the two agree — while a test double that never waits still
      // sees the budget bite.
      var spent = Duration.zero;
      while (true) {
        final wait = _waitFor(currentTransport);
        final attemptStarted = DateTime.now();
        try {
          answer = await _query(encoded.names[index], wait);
          break;
        } catch (error) {
          if (_disposed) {
            return SendResult(
              SendStatus.unavailable,
              error: StateError('$_name lane is disposed'),
            );
          }
          attemptsLeft -= 1;
          spent += wait;
          final nextWait = _waitFor(currentTransport);
          if (attemptsLeft > 0 && spent + nextWait <= budget) {
            // Pacing: an unanswered query already waited its timer, but a
            // refused or mismatched answer came back at once — without a
            // wait, a budget of seconds against a resolver saying "no" in
            // 20 ms is hundreds of identical queries. The next attempt
            // waits what the timer would have.
            if (error is TxtQueryWireException) {
              final paced = wait - DateTime.now().difference(attemptStarted);
              if (paced > Duration.zero) await Future<void>.delayed(paced);
            }
            continue;
          }
          _rotateTransport();
          final mayRotate = index == 0 || attemptsPerChunk > 1;
          if (!mayRotate || rotationsLeft <= 0) {
            // Every candidate has now been tried for this send: it counts
            // as ONE failure against the threshold, not one per transport
            // rotated through — otherwise a single brief outage reaches
            // the default threshold from a single send() call, since a
            // phone's default candidate list is exactly failThreshold long.
            if (_recordFailure()) {
              return SendResult(
                SendStatus.unavailable,
                error: StateError('$_name valve is DOWN: $error'),
              );
            }
            return SendResult(SendStatus.transient, error: error);
          }
          rotationsLeft -= 1;
          attemptsLeft = attemptsPerChunk;
          spent = Duration.zero;
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

  /// How long the responder keeps a partly received payload before it
  /// evicts it: `session_ttl` in tools/t2/txt_query_server.py, idle-based.
  /// An estimate written here because the lane cannot measure it; a
  /// responder configured differently must be mirrored here.
  static const Duration responderSessionTtl = Duration(seconds: 60);

  /// How long one chunk may be re-sent on one transport before the lane
  /// rotates — zero under the strict policy.
  ///
  /// Every chunk of a payload must land inside [responderSessionTtl], or
  /// the responder opens a fresh buffer for the late one and the send
  /// reports ok for a payload that never reassembles. So the TTL, less two
  /// timeouts of margin, is shared across the candidates a chunk might
  /// travel: with the phone's five and a 4 s timeout that is 10.4 s each.
  /// Never below one timeout, so a transport that has never answered still
  /// gets one full wait. On a dead transport (no sample: the wait is the
  /// ceiling) the budget is two or three attempts, as the fixed count was;
  /// on a live lossy link (a wait of 300–600 ms) it is ten to twenty.
  Duration get chunkBudget {
    if (attemptsPerChunk <= 1) return Duration.zero;
    final shared = responderSessionTtl - _timeout * 2;
    final each = shared ~/ _transports.length;
    return each < _timeout ? _timeout : each;
  }

  /// The wait the next query on [transport] is handed.
  ///
  /// With one attempt per chunk it is the configured timeout, as before.
  /// With retries it follows the measured round trip of THIS transport
  /// ([TxtQueryRto]), so a lost datagram on a fast link costs hundreds of
  /// milliseconds rather than the whole timeout.
  Duration _waitFor(TxtQueryTransport transport) {
    if (attemptsPerChunk <= 1) return _timeout;
    return _rtos
        .putIfAbsent(transport, () => TxtQueryRto(ceiling: _timeout))
        .next;
  }

  /// Sends one query name, waiting [wait] for the answer, and returns the
  /// bytes its TXT answer carried.
  Future<Uint8List> _query(String queryName, Duration wait) async {
    // A random transaction id per query (RFC 5452): a sequential one is
    // guessable, and this path talks to resolvers it does not control.
    final txid = _txids.nextInt(0x10000);
    final packet = TxtQueryWire.buildDnsQueryPacket(txid, queryName);
    attempts += 1;
    final transport = currentTransport;
    final rto = _rtos.putIfAbsent(
      transport,
      () => TxtQueryRto(ceiling: _timeout),
    );
    final sent = DateTime.now();
    final Uint8List response;
    try {
      response = await transport.exchange(packet, txid, wait);
    } catch (_) {
      rto.backoff();
      rethrow;
    }
    final Uint8List carried;
    try {
      carried = _validated(response, txid, queryName);
    } on TxtQueryWireException {
      // A fast negative — REFUSED, an empty record, a mismatched answer —
      // is a failure that cost no wait, so it feeds the backoff like a lost
      // datagram and never the estimator: a resolver answering "no" in
      // 20 ms must not teach the lane a 20 ms round trip.
      rto.backoff();
      rethrow;
    }
    rto.sample(DateTime.now().difference(sent));
    replies += 1;
    try {
      return TxtQueryWire.unframeDown(carried);
    } on TxtQueryWireException {
      // An answer that is not framed is still an answer: the responder may
      // be serving a plain TXT record rather than the tunnel's own.
      return carried;
    }
  }

  /// The TXT bytes of [response], once it has been proven to be the answer
  /// to this query and not a refusal.
  Uint8List _validated(Uint8List response, int txid, String queryName) {
    final answer = TxtQueryWire.parseDnsAnswerPacket(response);
    if (answer.txid != txid) {
      throw TxtQueryWireException('answer txid ${answer.txid} != $txid');
    }
    // The question name carries this query's session id and nonce — an
    // attacker who does not know them cannot reproduce it, so checking it
    // raises the bar for a spoofed or stale answer far past the 16-bit
    // txid alone (RFC 5452 section 9.1 question-section matching).
    if (answer.questionName != null && answer.questionName != queryName) {
      throw TxtQueryWireException(
        'answer question "${answer.questionName}" != "$queryName"',
      );
    }
    final carried = answer.payload;
    if (answer.rcode != TxtQueryWire.rcodeNoError || carried == null) {
      throw TxtQueryWireException('rcode=${answer.rcode}');
    }
    return carried;
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
