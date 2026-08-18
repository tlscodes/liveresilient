/// LaneAggregationProbe — decides whether parallel multi-lane transmission
/// actually buys throughput on THIS network, and admits only the lanes that do.
///
/// Two bottleneck classes produce opposite answers:
/// - per-flow shaping (fair queueing, per-5-tuple rate limits): M lanes carry
///   roughly M x R, so aggregation is a real win;
/// - interface-bound shaping (per-subscriber / per-radio caps): M lanes divide
///   one budget, so aggregation buys nothing — and, per RFC 6356's coupled
///   congestion control principle and RFC 8085's circuit-breaker guidance for
///   non-congestion-controlled flows, taking a larger share of a *shared*
///   bottleneck with parallel flows would also be impermissible. The two align:
///   where aggregation would be unfair, it also does not help.
///
/// Which class applies is a property of the network, not of this code, so it is
/// measured rather than assumed. Design constants below come from a simulation
/// sweep over per-flow / per-device / mixed topologies with 15% measurement
/// noise (40 seeds): greedy admission with median-of-3 windows classified
/// 113/120 correctly, versus 75/120 for a single global threshold, which failed
/// every mixed-topology case.
///
/// Dependency note: RLNC symbol production lives in `connection_orchestrator`,
/// which depends on this package — not the other way round. The probe therefore
/// takes a [SymbolCarryingWindow] port; the orchestrator supplies an
/// implementation backed by `RlncEncoder` + [PathSelector]. That keeps the
/// package graph acyclic and keeps this class unit-testable without codecs.
library;

import 'transport_channel.dart';

/// Outcome of one measurement window over a candidate lane set.
///
/// [innovativeSymbols] is the decoder-side rank increase, NOT the number of
/// symbols the sender injected. A queue-shaping middlebox accepts injected
/// bytes and delays them, so sender-side counting misclassifies an
/// interface-bound link as per-flow; in the sweep that error occurred on 100%
/// of per-device runs.
class LaneWindowSample {
  const LaneWindowSample({
    required this.innovativeSymbols,
    required this.elapsed,
    required this.owdMs,
    required this.symbolBytes,
    this.syntheticBytes = 0,
  });

  /// Symbols that increased decoder rank during the window.
  final int innovativeSymbols;

  /// Wall-clock length of the window.
  final Duration elapsed;

  /// One-way delay estimate for the window: receiver timestamp delta when a
  /// back-channel exists, otherwise RTT/2 from [SendResult.rttMs]. Consumed
  /// only by the bufferbloat guard.
  final int owdMs;

  /// Payload bytes per symbol (55 under the block-size mandate).
  final int symbolBytes;

  /// Bytes emitted that did NOT carry transfer payload. Must stay 0: the probe
  /// carries real tier-0 symbols instead of generating synthetic traffic, so
  /// every probe byte still counts toward decode. Surfaced (rather than
  /// assumed) so a regression that reintroduces synthetic probing is visible.
  final int syntheticBytes;

  double get goodputBps {
    final ms = elapsed.inMilliseconds;
    if (ms <= 0) return 0;
    return innovativeSymbols * symbolBytes * 8 * 1000 / ms;
  }
}

/// Emits real tier-0 symbols across [laneIds] for [window] and reports what the
/// decoder actually gained. Implemented over `RlncEncoder` + [PathSelector].
typedef SymbolCarryingWindow =
    Future<LaneWindowSample> Function(List<String> laneIds, Duration window);

/// How the link limits throughput.
enum BottleneckClass {
  /// Every offered lane added goodput: per-flow shaping.
  perFlow,

  /// No additional lane added goodput: one device-wide budget.
  perDevice,

  /// Some lanes added goodput and some did not — typically two lanes behind one
  /// interface plus one on a second interface.
  mixed,

  /// Fewer than two candidates, or no measurement was possible.
  unknown,
}

/// Immutable result of one probe run.
class LaneAggregationVerdict {
  const LaneAggregationVerdict({
    required this.admitted,
    required this.classification,
    required this.baseGoodputBps,
    required this.finalGoodputBps,
    required this.syntheticProbeBytes,
    required this.abortedByDelay,
    required this.windowsUsed,
  });

  /// Lane names to transmit on, always including the first candidate.
  final List<String> admitted;
  final BottleneckClass classification;
  final double baseGoodputBps;
  final double finalGoodputBps;

  /// Invariant: 0. See [LaneWindowSample.syntheticBytes].
  final int syntheticProbeBytes;

  /// True when a trial was stopped because added load only lengthened the
  /// queue. The lanes admitted before the abort remain valid.
  final bool abortedByDelay;

  final int windowsUsed;

  double get gainFactor =>
      baseGoodputBps <= 0 ? 1.0 : finalGoodputBps / baseGoodputBps;

  bool get aggregationEnabled => admitted.length > 1;

  Map<String, Object?> toTelemetry() => <String, Object?>{
    'admitted': admitted,
    'class': classification.name,
    'gain': double.parse(gainFactor.toStringAsFixed(3)),
    'syntheticProbeBytes': syntheticProbeBytes,
    'abortedByDelay': abortedByDelay,
    'windows': windowsUsed,
  };
}

/// Cache of verdicts per (network fingerprint, candidate set). The fingerprint
/// is supplied by the caller — this package never inspects network identity.
abstract interface class AggregationMemory {
  LaneAggregationVerdict? recall(String fingerprint, List<String> lanes);
  void remember(
    String fingerprint,
    List<String> lanes,
    LaneAggregationVerdict verdict,
  );
}

/// In-memory [AggregationMemory] with a TTL. Verdicts expire because the
/// network can change under a stationary device (cell handover, policy change).
class EphemeralAggregationMemory implements AggregationMemory {
  EphemeralAggregationMemory({
    required this.nowMs,
    this.ttl = const Duration(minutes: 30),
    this.maxEntries = 64,
  }) {
    if (maxEntries < 1) {
      throw RangeError.value(maxEntries, 'maxEntries', 'must be >= 1');
    }
  }

  final int Function() nowMs;
  final Duration ttl;

  /// Hard cap on remembered verdicts.
  ///
  /// Expiry alone does not bound this map: `recall` only ever removes the ONE
  /// key it was asked about, so nothing sweeps entries for networks the device
  /// never returns to. A phone that rides a train through forty cells, or an
  /// app left running for a week, accumulates a permanent entry per
  /// (network, lane-set) pair for the process lifetime. A cache with no
  /// eviction is a leak wearing a cache's name.
  final int maxEntries;

  final Map<String, (int, LaneAggregationVerdict)> _entries = {};

  String _key(String fingerprint, List<String> lanes) =>
      '$fingerprint|${(List.of(lanes)..sort()).join(',')}';

  @override
  LaneAggregationVerdict? recall(String fingerprint, List<String> lanes) {
    final e = _entries[_key(fingerprint, lanes)];
    if (e == null) return null;
    if (nowMs() - e.$1 > ttl.inMilliseconds) {
      _entries.remove(_key(fingerprint, lanes));
      return null;
    }
    return e.$2;
  }

  @override
  void remember(
    String fingerprint,
    List<String> lanes,
    LaneAggregationVerdict verdict,
  ) {
    final now = nowMs();
    _entries[_key(fingerprint, lanes)] = (now, verdict);
    if (_entries.length <= maxEntries) return;

    // Sweep the genuinely expired first — they are free to drop and dropping
    // them is what the TTL promised.
    _entries.removeWhere((_, e) => now - e.$1 > ttl.inMilliseconds);
    // Still over: evict oldest-first. A verdict is a measurement of a network
    // the device may never see again; the newest ones are the ones worth
    // keeping.
    while (_entries.length > maxEntries) {
      var oldestKey = _entries.keys.first;
      var oldestAt = _entries[oldestKey]!.$1;
      for (final entry in _entries.entries) {
        if (entry.value.$1 < oldestAt) {
          oldestAt = entry.value.$1;
          oldestKey = entry.key;
        }
      }
      _entries.remove(oldestKey);
    }
  }

  /// Entries currently held. Telemetry, and the number a leak would show in.
  int get entryCount => _entries.length;
}

/// A candidate lane and the physical interface it rides on. Interface identity
/// drives ordering: a lane on an unused interface is tried before an extra lane
/// on an interface already admitted, because only the former can add capacity
/// under an interface-bound cap.
class LaneCandidate {
  const LaneCandidate({
    required this.laneId,
    required this.interfaceId,
    this.score = 0,
  });

  final String laneId;
  final String interfaceId;

  /// Ranking hint, typically [ChannelHealth.score].
  final double score;
}

class LaneAggregationProbe {
  LaneAggregationProbe({
    required this.carryWindow,
    this.memory,
    this.minAdd = 0.25,
    this.windows = 3,
    this.confirmations = 1,
    this.window = const Duration(seconds: 2),
    this.delayGuardFactor = 1.5,
    this.maxLanes = 3,
  }) {
    if (minAdd <= 0) throw RangeError.value(minAdd, 'minAdd', 'must be > 0');
    if (windows < 1) throw RangeError.value(windows, 'windows', 'must be >= 1');
    // An EVEN window count has no median. `g[g.length ~/ 2]` then takes the
    // upper of the two middle samples — the MAXIMUM of a pair — which biases
    // every decision toward admitting a lane, on a class whose entire purpose
    // is to refuse lanes that do not help. The class advertises median-of-N;
    // it now enforces the only N for which that sentence is true.
    if (windows.isEven) {
      throw ArgumentError.value(
        windows,
        'windows',
        'must be odd: an even count has no median, and taking the upper of '
            'two middle samples biases toward admitting a lane',
      );
    }
    if (confirmations < 1) {
      throw RangeError.value(confirmations, 'confirmations', 'must be >= 1');
    }
    if (maxLanes < 1) {
      throw RangeError.value(maxLanes, 'maxLanes', 'must be >= 1');
    }
    if (delayGuardFactor <= 1.0) {
      throw RangeError.value(
        delayGuardFactor,
        'delayGuardFactor',
        'must be > 1',
      );
    }
  }

  /// Port that emits real transfer symbols and reports decoder-side gain.
  final SymbolCarryingWindow carryWindow;

  final AggregationMemory? memory;

  /// Minimum fractional goodput gain for a lane to be admitted. At 0.25 the
  /// sweep rejected noise-driven admissions while still admitting a genuinely
  /// additive second interface.
  final double minAdd;

  /// Measurement windows per decision, combined by median. Single-window
  /// decisions over-enabled 11/40 (per-device) and 9/40 (mixed); median-of-3
  /// reduced both to 3/40.
  final int windows;

  /// Consecutive median-decisions a candidate must win before admission.
  ///
  /// 1 is the fast path used during a live transfer. 2 is the hysteresis
  /// setting: measured over 200 seeds it cut spurious admissions on an
  /// interface-bound link from 1.5% to 0.5% at no cost in overall accuracy
  /// (0.982 -> 0.983), because a lane that only looked additive through
  /// measurement noise rarely looks additive twice. Median-of-3 alone cannot
  /// reach zero — noise is unbounded — so a caller that must not over-enable
  /// (battery-critical, metered link) sets this to 2.
  final int confirmations;

  final Duration window;

  /// Abort a trial when its one-way delay exceeds this multiple of the
  /// baseline's: added load that only queues is not capacity.
  final double delayGuardFactor;

  final int maxLanes;

  /// Returns a probe identical to this one but measuring through [port].
  ///
  /// Exists so callers in other packages do not hand-copy the settings: the
  /// symbol-carrying port lives in `connection_orchestrator` (it needs the RLNC
  /// encoder), while the tuning lives here. A hand-rolled copy silently drops
  /// any field added later — this cannot.
  LaneAggregationProbe rebind(SymbolCarryingWindow port) =>
      LaneAggregationProbe(
        carryWindow: port,
        memory: memory,
        minAdd: minAdd,
        windows: windows,
        confirmations: confirmations,
        window: window,
        delayGuardFactor: delayGuardFactor,
        maxLanes: maxLanes,
      );

  /// Orders candidates: highest score first, but the first lane of each new
  /// interface outranks a second lane on an already-seen interface.
  ///
  /// Duplicate lane ids are rejected rather than deduplicated: the same lane
  /// offered twice would be measured as if it were extra capacity, which is
  /// the exact mistake this whole class exists to prevent.
  static List<LaneCandidate> orderCandidates(List<LaneCandidate> candidates) {
    final ids = <String>{};
    for (final c in candidates) {
      if (!ids.add(c.laneId)) {
        throw ArgumentError.value(
          c.laneId,
          'candidates',
          'duplicate lane id',
        );
      }
    }
    final byScore = List.of(candidates)
      ..sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    final firstOfInterface = <LaneCandidate>[];
    final rest = <LaneCandidate>[];
    for (final c in byScore) {
      if (seen.add(c.interfaceId)) {
        firstOfInterface.add(c);
      } else {
        rest.add(c);
      }
    }
    return [...firstOfInterface, ...rest];
  }

  /// Runs greedy admission. Safe to call during the first seconds of a
  /// transfer: the windows carry that transfer's own tier-0 symbols.
  Future<LaneAggregationVerdict> run({
    required String networkFingerprint,
    required List<LaneCandidate> candidates,
  }) async {
    final ordered = orderCandidates(candidates).take(maxLanes).toList();
    if (ordered.isEmpty) {
      return const LaneAggregationVerdict(
        admitted: <String>[],
        classification: BottleneckClass.unknown,
        baseGoodputBps: 0,
        finalGoodputBps: 0,
        syntheticProbeBytes: 0,
        abortedByDelay: false,
        windowsUsed: 0,
      );
    }

    final laneIds = ordered.map((c) => c.laneId).toList();
    final cached = memory?.recall(networkFingerprint, laneIds);
    if (cached != null) return cached;

    final admitted = <String>[laneIds.first];
    var windowsUsed = 0;
    var synthetic = 0;

    final base = await _median(admitted);
    windowsUsed += base.windows;
    synthetic += base.synthetic;
    var current = base.goodputBps;
    final baseOwd = base.owdMs;
    var aborted = false;

    if (ordered.length > 1) {
      outer:
      for (final candidate in ordered.skip(1)) {
        final trial = [...admitted, candidate.laneId];
        var passes = 0;
        var lastGoodput = current;

        for (var attempt = 0; attempt < confirmations; attempt++) {
          final m = await _median(trial);
          windowsUsed += m.windows;
          synthetic += m.synthetic;

          if (baseOwd > 0 && m.owdMs > baseOwd * delayGuardFactor) {
            aborted = true;
            break outer;
          }
          // No evidence means no aggregation. A trial that delivered nothing
          // can never justify a lane, INCLUDING when the baseline also
          // delivered nothing — which is exactly the feedback-free (DTN) case,
          // where rank growth is unobservable. An earlier form admitted every
          // lane when the baseline read zero; that is the wrong failure
          // direction, and lighting up extra radios on a link nobody can
          // measure is the most expensive way to learn nothing.
          final justified = m.goodputBps > 0 &&
              (current <= 0 || m.goodputBps >= current * (1 + minAdd));
          if (justified) {
            passes++;
            lastGoodput = m.goodputBps;
          } else {
            break; // one failed confirmation is enough to reject
          }
        }

        if (passes == confirmations) {
          admitted.add(candidate.laneId);
          current = lastGoodput;
        }
      }
    }

    final verdict = LaneAggregationVerdict(
      admitted: List.unmodifiable(admitted),
      classification: _classify(
        admitted.length,
        ordered.length,
        abortedByDelay: aborted,
      ),
      baseGoodputBps: base.goodputBps,
      finalGoodputBps: current,
      syntheticProbeBytes: synthetic,
      abortedByDelay: aborted,
      windowsUsed: windowsUsed,
    );
    memory?.remember(networkFingerprint, laneIds, verdict);
    return verdict;
  }

  Future<({double goodputBps, int owdMs, int windows, int synthetic})> _median(
    List<String> lanes,
  ) async {
    final g = <double>[];
    final d = <int>[];
    var synthetic = 0;
    for (var i = 0; i < windows; i++) {
      final s = await carryWindow(lanes, window);
      g.add(s.goodputBps);
      d.add(s.owdMs);
      synthetic += s.syntheticBytes;
    }
    g.sort();
    d.sort();
    return (
      goodputBps: g[g.length ~/ 2],
      owdMs: d[d.length ~/ 2],
      windows: windows,
      synthetic: synthetic,
    );
  }

  BottleneckClass _classify(
    int admitted,
    int offered, {
    required bool abortedByDelay,
  }) {
    if (offered <= 1) return BottleneckClass.unknown;
    // A delay-aborted trial proves the extra load queued rather than flowed,
    // which is the interface-bound signature even if a lane slipped in first.
    if (abortedByDelay && admitted == 1) return BottleneckClass.perDevice;
    if (admitted == 1) return BottleneckClass.perDevice;
    if (admitted == offered) return BottleneckClass.perFlow;
    return BottleneckClass.mixed;
  }
}

/// Turns a verdict into transport settings.
///
/// Layers are DEFERRED, never dropped: dropping an enhancement layer would
/// break the monotone-quality invariant and the bit-exact tail of the layered
/// format. Payload size is NOT reduced to fit a rate cap — per-datagram framing
/// costs 5 bytes regardless of payload, so shrinking the block raises total wire
/// bytes (measured +5.7% at block size 31 versus 55 for a ~3.4 KB object). The
/// adaptive knobs against a hard cap are the redundancy factor and the pacer.
class AdaptiveAggregationPolicy {
  const AdaptiveAggregationPolicy({
    required this.verdict,
    required this.distinctInterfaces,
    this.batteryOk = true,
  });

  final LaneAggregationVerdict verdict;

  /// Physically distinct interfaces available (wifi, cellular, second SIM,
  /// mesh peer). Only a different interface can raise capacity under a
  /// device-wide cap.
  final int distinctInterfaces;

  final bool batteryOk;

  static const int mandatedBlockSize = 55;

  /// The only mitigation that can raise throughput under an interface-bound
  /// cap: move traffic to another interface.
  bool get shouldOffloadToSecondInterface =>
      verdict.classification == BottleneckClass.perDevice &&
      distinctInterfaces > 1 &&
      batteryOk;

  /// Spend the whole scarce budget on tier-0 first; enhancement layers wait
  /// (they are never discarded).
  bool get deferEnhancementLayers =>
      verdict.classification != BottleneckClass.perFlow;

  /// Lanes the transport should actually use, battery-gated: extra lanes mean
  /// extra radios awake.
  ///
  /// NEVER ZERO. The previous form returned 0 for an empty verdict — and a
  /// router told to use no lanes does not fail loudly, it silently stops
  /// sending. Its sibling `routerConfigFor` floored the same quantity at 1, so
  /// two code paths answered one question differently and only one of them was
  /// safe. One lane is the floor everywhere: the acknowledged path always
  /// exists, and "we could not measure" must never mean "do not transmit".
  int get lanesToUse {
    final admitted = verdict.admitted.length;
    if (!batteryOk) return 1;
    return admitted < 1 ? 1 : admitted;
  }

  /// Block size follows the lane MTU only, capped at the mandated 55 and never
  /// reduced to fit a rate budget.
  /// The smallest datagram the block-size range can produce: 31 payload bytes
  /// plus the 5-byte header.
  static const int minViableMtu = 36;

  int blockSizeFor({required int laneMtuBytes}) {
    // A lane that cannot carry 36 bytes cannot carry this coding at all.
    // Clamping silently to 31 returned a block LARGER than the MTU from a
    // method whose contract is "follows the lane MTU" — every datagram would
    // then be fragmented or dropped, and the cause would be a value this
    // method invented. Refuse instead of lying.
    if (laneMtuBytes < minViableMtu) {
      throw ArgumentError.value(
        laneMtuBytes,
        'laneMtuBytes',
        'below $minViableMtu: no legal block size fits, so this lane cannot '
            'carry RLNC datagrams at all',
      );
    }
    final fromMtu = laneMtuBytes - 5;
    return fromMtu >= mandatedBlockSize ? mandatedBlockSize : fromMtu;
  }
}
