/// Closes the seam `LaneAggregationProbe` was written against.
///
/// WHY THIS FILE EXISTS. `adaptive_transport.LaneAggregationProbe` decides
/// whether parallel lanes actually add throughput, and it deliberately does not
/// generate its own traffic: it takes a `SymbolCarryingWindow` port so the
/// measurement rides on REAL rateless symbols (probe cost 0 bytes). Nothing
/// supplied that port, so the probe had zero call sites anywhere in the repo —
/// tested, exported, and never run.
///
/// The port has to live here rather than in `adaptive_transport`, because it
/// needs `RlncEncoder`, and `connection_orchestrator` depends on
/// `adaptive_transport` and not the other way round. Implementing it in the
/// lower package would invert the graph.
///
/// The measurement that matters is DELIVERED rank growth, not injected bytes: a
/// queue-shaping middlebox accepts everything and delays it, so counting sends
/// classifies an interface-bound link as per-flow every time. This carrier
/// therefore counts only symbols the receiver reports as innovative.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

import 'gf256_rlnc_stream.dart';
import 'layered_redundancy_allocator.dart';

/// Sends one symbol on one lane. Returns the send outcome so RTT can be read.
///
/// Implemented over the fabric's per-lane send (`PathSelector` picks lanes by
/// health; here the LANE IS NAMED, because the probe is measuring lanes, not
/// letting the router choose).
typedef LaneSymbolSender =
    Future<SendResult> Function(String laneId, Uint8List datagram);

/// How many of the symbols sent so far the receiver has actually used.
///
/// Under a back-channel this is the decoder's reported rank. Feedback-free
/// (DTN, the P9 profile), no honest number exists — the carrier then reports
/// zero innovative symbols, which makes the probe admit no extra lane. That is
/// the correct failure direction: without evidence, do not aggregate.
typedef InnovativeRankReader = FutureOr<int> Function();

/// One-way delay estimate in milliseconds, or null when unknown.
typedef OwdReader = FutureOr<int?> Function();

class RlncProbeCarrier {
  RlncProbeCarrier({
    required this.sendOnLane,
    required this.readInnovativeRank,
    this.readOwdMs,
    this.blockSize = LayeredRedundancyAllocator.mandatedBlockSize,
    this.maxSymbolsPerWindow = 2048,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? _wallClockMs {
    if (maxSymbolsPerWindow < 1) {
      throw RangeError.value(
        maxSymbolsPerWindow,
        'maxSymbolsPerWindow',
        'must be >= 1',
      );
    }
  }

  final LaneSymbolSender sendOnLane;
  final InnovativeRankReader readInnovativeRank;
  final OwdReader? readOwdMs;

  /// Injectable clock, matching the package's existing convention (see
  /// `ConnectionFabric`, `EphemeralAggregationMemory`). Goodput is
  /// symbols-per-elapsed-time, so a test that cannot control elapsed time
  /// cannot make a deterministic assertion about a lane decision — and a
  /// flaky transport test is worse than none.
  final int Function() nowMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 55 by the framing mandate: the datagram is 60 B, exactly the micro lane's
  /// budget, and the framing floor is 5/55 = 9.12%.
  final int blockSize;

  /// Hard bound on symbols per window, independent of the clock.
  ///
  /// Without it the emission loop can spin forever: on a fast host with an
  /// in-memory lane, sends complete inside one millisecond tick, so
  /// `elapsed < window` never becomes false and the window never closes. A
  /// time-only termination condition is a latent hang, not a tight loop.
  final int maxSymbolsPerWindow;

  /// Symbols emitted, per lane, across every window. Telemetry only.
  final Map<String, int> symbolsPerLane = {};

  /// Bytes this carrier generated that did NOT carry transfer payload.
  ///
  /// Structurally zero, and const so it cannot drift: the carrier emits the
  /// transfer's own symbols and has no code path that manufactures traffic.
  /// Surfaced rather than left implicit so the probe's zero-cost claim is
  /// checkable from outside.
  static const int syntheticBytes = 0;

  /// The largest ESI the 16-bit wire header can carry.
  static const int maxEsi = 0xFFFF;

  /// True when the MOST RECENT window stopped because ESI space ran out rather
  /// than because the window closed.
  ///
  /// Reset at the start of every window. It was a latch: once any window
  /// exhausted the space, every later reading reported exhaustion forever,
  /// including for a carrier rebound to a fresh encoder at ESI 0 — a permanent
  /// false alarm on a field whose whole job is to be believed.
  bool esiSpaceExhausted = false;

  /// Next ESI to hand out, shared by every window this carrier produces.
  ///
  /// INSTANCE state, not per-closure. When it lived in the closure, two
  /// `windowFor` calls on one carrier each started at `startEsi` and emitted
  /// the SAME esis against the same encoder — linearly dependent symbols, the
  /// precise waste the mod-M partition rule exists to prevent, on a link that
  /// by definition has no bandwidth to waste.
  int _nextEsi = 0;

  /// Builds a [SymbolCarryingWindow] for [encoder]'s stream.
  ///
  /// [startEsi] is where this window begins in ESI space; the carrier advances
  /// it, so successive windows never repeat a symbol.
  ///
  /// ESI partition rule (spec F-6): lane m of an M-lane trial emits ESIs
  /// congruent to m modulo M. Free choice measured 8-9 duplicate symbols and
  /// ~10% wasted time per object; duplicates are linearly dependent and buy
  /// exactly nothing.
  SymbolCarryingWindow windowFor(RlncEncoder encoder, {int startEsi = 0}) {
    if (startEsi < 0 || startEsi > maxEsi) {
      throw RangeError.range(startEsi, 0, maxEsi, 'startEsi');
    }
    // The counter advances monotonically across every window this carrier
    // makes; a later windowFor never rewinds it back over symbols already sent.
    if (startEsi > _nextEsi) _nextEsi = startEsi;

    return (List<String> laneIds, Duration window) async {
      esiSpaceExhausted = false;
      if (laneIds.isEmpty) {
        return LaneWindowSample(
          innovativeSymbols: 0,
          elapsed: window,
          owdMs: 0,
          symbolBytes: blockSize,
        );
      }

      final rankBefore = await readInnovativeRank();
      final startedMs = nowMs();
      final rtts = <int>[];
      final m = laneIds.length;

      // Emit until the window closes. The ESI stride keeps every lane's
      // symbols distinct without any coordination at run time.
      var elapsedMs = 0;
      var emitted = 0;
      while (elapsedMs < window.inMilliseconds &&
          emitted + m <= maxSymbolsPerWindow) {
        if (_nextEsi + m - 1 > maxEsi) {
          esiSpaceExhausted = true;
          break;
        }
        for (var i = 0; i < m; i++) {
          final esi = _nextEsi + i;
          final datagram = encoder.datagramAt(esi);
          final laneId = laneIds[i];
          final result = await sendOnLane(laneId, datagram);
          symbolsPerLane.update(laneId, (v) => v + 1, ifAbsent: () => 1);
          final rtt = result.rttMs;
          if (rtt != null) rtts.add(rtt);
        }
        _nextEsi += m;
        emitted += m;
        // A clock that steps BACKWARD (NTP correction, timezone change on the
        // wall clock this defaults to) would make elapsed negative, keep the
        // loop running to the symbol budget, and then the one-millisecond floor
        // below would report the whole window as 1 ms — goodput inflated a
        // thousandfold, and every lane admitted on a link that cannot carry
        // them. Time never runs backwards here.
        final measured = nowMs() - startedMs;
        elapsedMs = measured > elapsedMs ? measured : elapsedMs;
      }

      final rankAfter = await readInnovativeRank();
      final gained = rankAfter - rankBefore;

      final explicitOwd = await readOwdMs?.call();
      final owd = explicitOwd ??
          (rtts.isEmpty
              ? 0
              : (rtts.reduce((a, b) => a + b) / rtts.length / 2).round());

      return LaneWindowSample(
        innovativeSymbols: gained < 0 ? 0 : gained,
        // Goodput divides by this, so a zero-length window would be an
        // infinity. One millisecond is the smallest honest floor.
        elapsed: Duration(milliseconds: elapsedMs < 1 ? 1 : elapsedMs),
        owdMs: owd,
        symbolBytes: blockSize,
        syntheticBytes: syntheticBytes,
      );
    };
  }

  /// Total symbols this carrier has emitted across every window and lane.
  int get symbolsEmitted =>
      symbolsPerLane.values.fold(0, (a, b) => a + b);
}

/// Convenience: run the probe over a live transfer and return the lanes to use.
///
/// Callers hold a [PathSelector] for routing and this for the decision; the two
/// stay separate because the router must keep working unchanged when the probe
/// says "one lane" (which is the correct answer on most mobile networks).
///
/// The probe is rebound rather than rebuilt — [LaneAggregationProbe.rebind]
/// copies the tuning in one place, so a field added to the probe cannot be
/// silently dropped here.
Future<LaneAggregationVerdict> probeLanesForTransfer({
  required LaneAggregationProbe probe,
  required RlncProbeCarrier carrier,
  required RlncEncoder tier0Encoder,
  required String networkFingerprint,
  required List<LaneCandidate> candidates,
  int startEsi = 0,
}) {
  return probe
      .rebind(carrier.windowFor(tier0Encoder, startEsi: startEsi))
      .run(
        networkFingerprint: networkFingerprint,
        candidates: candidates,
      );
}

/// Translates a verdict into the router setting that acts on it.
///
/// This is the last hop of the decision: without it the probe is an opinion
/// nobody applies. `fanout` is how many top-ranked lanes `PathSelector` sends
/// the same chunk on, which is exactly what "use these N lanes" means for a
/// rateless stream — except that with distinct ESIs per lane the copies are not
/// redundant, they are additional coverage.
RouterConfig routerConfigFor(
  LaneAggregationVerdict verdict, {
  required RouterConfig current,
  bool batteryOk = true,
}) {
  // Extra lanes mean extra radios awake, so a low battery collapses even a
  // proven per-flow win back to one lane. Computed here rather than through
  // AdaptiveAggregationPolicy because that class also answers questions about
  // INTERFACES, and passing the admitted-lane count as an interface count
  // would be a plausible-looking lie.
  final lanes = batteryOk
      ? (verdict.admitted.isEmpty ? 1 : verdict.admitted.length)
      : 1;
  return RouterConfig(
    maxFailover: current.maxFailover < lanes ? lanes : current.maxFailover,
    fanout: lanes,
  );
}
