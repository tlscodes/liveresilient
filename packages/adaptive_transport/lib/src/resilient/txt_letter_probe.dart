import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'txt_query_lane.dart';
import 'txt_query_transport.dart';
import 'txt_query_wire.dart';

/// One probe exchange: which resolver carried it and what came back.
class TxtProbeAnswer {
  const TxtProbeAnswer({
    required this.index,
    required this.label,
    required this.nonce,
    this.winnerNonce,
    this.rank,
    this.error,
  });

  /// Position of the resolver in the probe's transport list.
  final int index;
  final String label;

  /// The nonce this resolver's probe carried (hex, 16 chars).
  final String nonce;

  /// The nonce the responder logged FIRST for this probe group, as it
  /// reported it in this answer. Null when no answer came back.
  final String? winnerNonce;

  /// 1-based arrival rank of THIS probe in the responder's log.
  final int? rank;

  /// Why no usable answer came back.
  final Object? error;

  bool get answered => winnerNonce != null;
}

/// What a probe found.
class TxtProbeOutcome {
  const TxtProbeOutcome({
    required this.groupId,
    required this.answers,
    this.winnerIndex,
  });

  /// Hex id shared by the probes of one run; the responder ranks nonces
  /// inside it.
  final String groupId;
  final List<TxtProbeAnswer> answers;

  /// The resolver whose nonce the responder logged first, or null when no
  /// probe was answered — the letter then waits in the queue.
  final int? winnerIndex;

  bool get reachedServer => winnerIndex != null;

  /// One greppable line for the phone's event log, the same on the app and
  /// the rig peer: `group=<hex> winner=<i|null> <label>:<nonce>:<rank>...`.
  /// The group and nonces match the responder's `probe group=` lines, so
  /// tools/t2/probe_check.sh can be read against it. A resolver with no
  /// answer shows `-` or its error type instead of a rank.
  String describe() =>
      'group=$groupId winner=$winnerIndex '
      '${answers.map((a) => '${a.label}:${a.nonce}:'
          '${a.rank ?? (a.error == null ? '-' : a.error.runtimeType)}').join(' ')}';
}

/// Races one tiny probe through each resolver and lets the SERVER'S log
/// pick the path.
///
/// Every resolver gets its own nonce inside one probe group. The responder
/// (tools/t2/txt_query_server.py, `PRB1` payloads) logs each nonce as it
/// arrives and answers every probe with the nonce it logged first. So the
/// winner is the resolver whose query reached our server first — not the
/// one whose answer happened to reach the phone first, which is decided by
/// the return path and says nothing about how the letter's chunks will
/// travel.
///
/// A probe payload is 20 bytes (`PRB1` + 8-byte group + 8-byte nonce), one
/// query name, so a probe costs one round trip per resolver, all in
/// parallel.
class TxtLetterProbe {
  TxtLetterProbe({
    required this.domain,
    required List<TxtQueryTransport> transports,
    this.timeout = const Duration(seconds: 4),
    Random? random,
  }) : _transports = List<TxtQueryTransport>.unmodifiable(transports),
       _random = random ?? Random.secure() {
    if (transports.isEmpty) {
      throw ArgumentError.value(transports, 'transports', 'must not be empty');
    }
  }

  /// Probes three of [lane]'s own UDP/53 resolvers: the device's resolver
  /// (the operator's, first in the lane's list), 8.8.8.8 and 1.1.1.1 —
  /// falling back to the next UDP candidates when one of those is absent.
  /// The transports are shared with the lane, so the winner can be handed
  /// to [TxtQueryLane.preferTransport]; the probe never disposes them.
  factory TxtLetterProbe.forLane(
    TxtQueryLane lane, {
    Duration timeout = const Duration(seconds: 4),
    Random? random,
  }) {
    final udp = lane.transports.whereType<Udp53QueryTransport>().toList();
    final picked = <TxtQueryTransport>[];
    void take(TxtQueryTransport? t) {
      if (t != null && !picked.contains(t) && picked.length < 3) picked.add(t);
    }

    Udp53QueryTransport? byHost(String host) {
      for (final t in udp) {
        if (t.resolver.host == host) return t;
      }
      return null;
    }

    final system = udp.where(
      (t) => t.resolver.host != '8.8.8.8' && t.resolver.host != '1.1.1.1',
    );
    take(system.isEmpty ? null : system.first);
    take(byHost('8.8.8.8'));
    take(byHost('1.1.1.1'));
    for (final t in lane.transports) {
      take(t);
    }
    return TxtLetterProbe(
      domain: lane.domain,
      transports: picked,
      timeout: timeout,
      random: random,
    );
  }

  static const List<int> magic = <int>[0x50, 0x52, 0x42, 0x31]; // "PRB1"
  static const int idBytes = 8;

  final String domain;
  final Duration timeout;
  final List<TxtQueryTransport> _transports;
  final Random _random;

  List<TxtQueryTransport> get transports => _transports;

  Future<TxtProbeOutcome> run() async {
    final group = _bytes(idBytes);
    final nonces = [for (final _ in _transports) _bytes(idBytes)];
    final answers = await Future.wait([
      for (var i = 0; i < _transports.length; i++)
        _probeOne(i, group, nonces[i]),
    ]);
    // Every answer names the responder's first-logged nonce; they agree
    // unless a resolver replays a stale answer, so the first answered one
    // is taken and must name a nonce this run actually sent.
    int? winner;
    for (final answer in answers) {
      final w = answer.winnerNonce;
      if (w == null) continue;
      final at = nonces.indexWhere((n) => _hex(n) == w);
      if (at >= 0) {
        winner = at;
        break;
      }
    }
    return TxtProbeOutcome(
      groupId: _hex(group),
      answers: answers,
      winnerIndex: winner,
    );
  }

  Future<TxtProbeAnswer> _probeOne(
    int i,
    Uint8List group,
    Uint8List nonce,
  ) async {
    final transport = _transports[i];
    final nonceHex = _hex(nonce);
    try {
      final payload = <int>[...magic, ...group, ...nonce];
      final names = TxtQueryWire.encodeQueries(payload, domain).names;
      if (names.length != 1) {
        throw StateError('probe must fit one query name, got ${names.length}');
      }
      final txid = _random.nextInt(0x10000);
      final packet = TxtQueryWire.buildDnsQueryPacket(txid, names.single);
      final response = await transport.exchange(packet, txid, timeout);
      final parsed = TxtQueryWire.parseDnsAnswerPacket(response);
      if (parsed.txid != txid) {
        throw TxtQueryWireException('probe txid ${parsed.txid} != $txid');
      }
      if (parsed.questionName != null && parsed.questionName != names.single) {
        throw TxtQueryWireException('probe answer for another question');
      }
      final carried = parsed.payload;
      if (parsed.rcode != TxtQueryWire.rcodeNoError || carried == null) {
        throw TxtQueryWireException('probe rcode=${parsed.rcode}');
      }
      final down = TxtQueryWire.unframeDown(carried);
      // Reply: "PRB1" + group(8) + winner nonce(8) + rank(1).
      if (down.length != magic.length + idBytes * 2 + 1 ||
          !_startsWith(down, magic) ||
          !_equal(down.sublist(4, 12), group)) {
        throw TxtQueryWireException('probe reply is not for this group');
      }
      return TxtProbeAnswer(
        index: i,
        label: transport.label,
        nonce: nonceHex,
        winnerNonce: _hex(down.sublist(12, 20)),
        rank: down[20],
      );
    } catch (error) {
      return TxtProbeAnswer(
        index: i,
        label: transport.label,
        nonce: nonceHex,
        error: error,
      );
    }
  }

  Uint8List _bytes(int n) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);
}

/// Where a letter ended up.
enum LetterRoute { sent, queued, tooLarge }

class LetterDispatch {
  const LetterDispatch(this.route, {this.probe, this.via, this.error});
  final LetterRoute route;
  final TxtProbeOutcome? probe;

  /// Label of the resolver the letter left through.
  final String? via;
  final Object? error;
}

/// Sends a letter through the resolver the probe picked; a letter no
/// resolver could carry waits in [queue] for [flush].
///
/// The letter itself goes through [TxtQueryLane] with the winner first and
/// the other resolvers after it, so a winner that dies mid-letter still
/// rotates instead of losing the letter.
class TxtLetterCourier {
  TxtLetterCourier({
    required this.probe,
    TxtQueryLane Function(List<TxtQueryTransport> ordered)? laneFor,
  }) : _laneFor =
           laneFor ??
           ((ordered) => TxtQueryLane(
             domain: probe.domain,
             transports: ordered,
             timeout: probe.timeout,
             attemptsPerChunk: 3,
           ));

  /// Hard cap on one letter, the lane's own limit.
  static const int maxLetterBytes = TxtQueryLane.maxPayloadBytes;

  final TxtLetterProbe probe;
  final TxtQueryLane Function(List<TxtQueryTransport> ordered) _laneFor;

  /// Letters waiting for a path, oldest first.
  final List<Uint8List> queue = <Uint8List>[];

  Future<LetterDispatch> send(List<int> letter) async {
    if (letter.length > maxLetterBytes) {
      return LetterDispatch(
        LetterRoute.tooLarge,
        error: ArgumentError.value(
          letter.length,
          'letter',
          'exceeds $maxLetterBytes bytes',
        ),
      );
    }
    final outcome = await probe.run();
    final winner = outcome.winnerIndex;
    if (winner == null) {
      queue.add(Uint8List.fromList(letter));
      return LetterDispatch(LetterRoute.queued, probe: outcome);
    }
    final all = probe.transports;
    final ordered = <TxtQueryTransport>[
      all[winner],
      for (var i = 0; i < all.length; i++)
        if (i != winner) all[i],
    ];
    // The lane is a throwaway here: disposing it would close the probe's
    // own transports, which the next letter reuses.
    final result = await _laneFor(ordered).send(letter);
    if (!result.delivered) {
      queue.add(Uint8List.fromList(letter));
      return LetterDispatch(
        LetterRoute.queued,
        probe: outcome,
        error: result.error,
      );
    }
    return LetterDispatch(
      LetterRoute.sent,
      probe: outcome,
      via: all[winner].label,
    );
  }

  /// Retries every queued letter once, in order; returns how many left.
  Future<int> flush() async {
    final pending = List<Uint8List>.of(queue);
    queue.clear();
    var sent = 0;
    for (final letter in pending) {
      final d = await send(letter);
      if (d.route == LetterRoute.sent) sent += 1;
    }
    return sent;
  }
}

/// Adds the secondary IPs from [TxtQueryResolvers.publicResolversFallback]
/// — ONLY when none of [TxtQueryResolvers.publicResolvers] (8.8.8.8,
/// 1.1.1.1, 9.9.9.9) is already racing in [transports]. The system
/// resolver and every other candidate already in [transports] are
/// returned unchanged; no address outside that fixed, already-published
/// list is ever added — never a discovered one. A pure function — it
/// schedules nothing and disposes nothing, so a caller with no absence
/// to fix pays only one pass over [transports].
List<TxtQueryTransport> withFallbackIfDoorAbsent(
  List<TxtQueryTransport> transports,
) {
  final hasDoor = transports.any(
    (t) =>
        TxtQueryResolvers.publicResolvers.any((r) => t.label.contains(r.host)),
  );
  if (hasDoor) return transports;
  return [
    ...transports,
    for (final resolver in TxtQueryResolvers.publicResolversFallback)
      Udp53QueryTransport(resolver),
  ];
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool _startsWith(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
