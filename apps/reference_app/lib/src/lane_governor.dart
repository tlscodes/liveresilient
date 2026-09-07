/// The send budget the call's data lanes (photos, voice notes, video notes)
/// are allowed next to the audio and the control plane — a MODEL of what the
/// path has actually delivered, not of what the transport guesses.
///
/// Measured on the rig (narrow profile, 16 kbit/s dummynet with live audio,
/// 2026-09-04): the previous governor took the transport's
/// `availableOutgoingBitrate` × share as a FLOOR of the budget. The estimate
/// was fiction on that link — the budget went 40000 → 8404 → 175006 B/s
/// during a photo and 1.6 MB/s → 4194304 B/s (the cap) during a voice note
/// while the link had ~570 B/s left after the survival audio. The result was
/// a 14.6 s round trip, 70 % loss, duplicates; the voice note failed and the
/// video never arrived. The extreme profile (the same 16 kbit/s plus 1 s of
/// delay and 15 % loss) did BETTER — the failure was flooding, not capacity.
///
/// This model answers with three rules:
///
/// 1. The rate comes from REAL delivery. Lane senders and the text messenger
///    call [reportAcked] with every acknowledged payload; the bytes acked over
///    the last max(4 s, 4 round trips) are the [measuredBytesPerSec], and that
///    measured rate is the floor of the budget — never a cap. The transport's
///    estimate is only named in [lastReason] so the log can show what it
///    claimed; it never moves the budget.
/// 2. Before the first ack the budget is a conservative fixed floor:
///    [initialBytesPerSec] defaults to 570 B/s, derived from the narrow link:
///    16000 bit/s minus the survival audio (8 kbit/s payload at 120 ms
///    packets of ~172 bytes on the wire ≈ 11.5 kbit/s) leaves ~4.5 kbit/s,
///    ≈ 560-570 B/s. A link that is faster proves it through acks within a
///    few round trips; a link that is slower is not made worse by the start.
/// 3. Per round trip (a step every max(200 ms, rtt)) a delay control decides
///    the direction: while the round trip stays near the lowest seen the
///    budget grows — doubling in slow start until the first inflation, ×1.25
///    afterwards — and when it inflates past max(1.5 × floor, floor + 150 ms)
///    it shrinks ×0.7 (the lane's own queueing is the inflation, so it backs
///    off before audio pays for it). Inside a step nothing changes except
///    the measured floor.
///
/// Both are clamped to [minBytesPerSec, maxBytesPerSec]. Also derives the
/// retransmit floor a lane sender should start from (2.5 round trips,
/// 700 ms..10 s).
library;

import 'dart:math';

import 'package:clock/clock.dart';

class LaneGovernor {
  LaneGovernor({
    required this.readRttMs,
    this.readAvailableOutgoingBps,
    this.share = 0.25,
    int initialBytesPerSec = 570,
    this.minBytesPerSec = 400,
    this.maxBytesPerSec = 4 << 20,
    Clock? clock,
  }) : _budget = initialBytesPerSec.toDouble(),
       _clock = clock ?? const Clock() {
    if (share <= 0 || share > 1) {
      throw ArgumentError.value(share, 'share', 'must be in (0, 1]');
    }
    if (minBytesPerSec < 1 || maxBytesPerSec < minBytesPerSec) {
      throw ArgumentError('min/max bytes per second are inconsistent');
    }
    if (initialBytesPerSec < 1) {
      throw ArgumentError.value(
        initialBytesPerSec,
        'initialBytesPerSec',
        'must be positive',
      );
    }
  }

  /// The path's latest round trip in milliseconds, null before a reading.
  final int? Function() readRttMs;

  /// The transport's available-outgoing-bandwidth estimate in bit/s, null
  /// when the stats carry none. Logged in [lastReason] only; it never moves
  /// the budget (see the library comment for the measured reason).
  final int? Function()? readAvailableOutgoingBps;

  /// The lane's share of a known link — kept for callers that pass it; the
  /// estimate it would apply to is no longer a budget input.
  final double share;
  final int minBytesPerSec;
  final int maxBytesPerSec;
  final Clock _clock;

  /// The shortest window the delivery measurement covers, in ms. Four
  /// seconds spans several round trips on any link the app is expected to
  /// run on (the rig's worst measured floor is ~1 s); on slower paths the
  /// window widens to four round trips so one ack burst does not read as
  /// the rate.
  static const int minMeasureWindowMs = 4000;

  /// The samples must span at least this long before they are a rate: one
  /// second is the shortest interval over which "bytes per second" is a
  /// measurement rather than a burst.
  static const int minMeasureSpanMs = 1000;

  /// How long the last measurement keeps capping the budget at twice its
  /// value after the sample window emptied (a lull between transfers).
  static const int measuredCapTtlMs = 30000;
  int? _lastMeasured;
  DateTime? _lastMeasuredAt;
  late final int _initial = _budget.round();

  double _budget;
  double? _minRttMs;
  DateTime? _lastStepAt;
  bool _slowStart = true;
  String _phase = 'no-rtt';
  final List<({int atMs, int bytes})> _acks = [];

  /// Why the last budget was what it was — one line naming every input:
  ///
  /// ```
  /// budget=<B/s> measured=<B/s or -> rtt=<ms> floor=<ms>
  /// <slow-start|probing|inflated|no-rtt> estimate=<bps or ->
  /// ```
  String lastReason = 'initial';

  /// A lane or the messenger reports [bytes] of payload the peer just
  /// acknowledged. The sample is kept for max(4 s, 4 round trips).
  void reportAcked(int bytes) {
    if (bytes <= 0) return;
    final nowMs = _clock.now().millisecondsSinceEpoch;
    _acks.add((atMs: nowMs, bytes: bytes));
    _prune(nowMs);
  }

  /// The delivery rate the path has proved: acked bytes over the window,
  /// divided by the time from the oldest kept sample to now. Null until the
  /// window holds at least two samples spanning at least [minMeasureSpanMs].
  int? measuredBytesPerSec() {
    final nowMs = _clock.now().millisecondsSinceEpoch;
    _prune(nowMs);
    if (_acks.length < 2) return null;
    final spanMs = nowMs - _acks.first.atMs;
    if (spanMs < minMeasureSpanMs) return null;
    var total = 0;
    for (final ack in _acks) {
      total += ack.bytes;
    }
    return (total * 1000 / spanMs).round();
  }

  int _measureWindowMs() {
    final rtt = readRttMs();
    return max(minMeasureWindowMs, 4 * (rtt ?? 0));
  }

  void _prune(int nowMs) {
    final oldest = nowMs - _measureWindowMs();
    _acks.removeWhere((ack) => ack.atMs < oldest);
  }

  /// The budget in bytes per second, re-derived on every call (lane senders
  /// read it per chunk). The measured delivery rate is always its floor; the
  /// delay control moves it once per round trip; the transport estimate is
  /// reported and ignored.
  int budgetBytesPerSec() {
    final estimate = readAvailableOutgoingBps?.call();
    final measured = measuredBytesPerSec();
    final rtt = readRttMs();
    if (rtt == null) {
      // No round trip yet (the stats feed can lag the call by a minute):
      // the budget still grows by MEASUREMENT so a transfer that starts
      // before the first sample is not pinned at the floor (measured
      // 2026-09-04: 570 B/s would take a 234 KB photo ~400 s on an
      // unshaped link). Without any measurement the growth stops at
      // 4x the initial floor: nothing has vouched for more.
      _phase = 'no-rtt';
      final now = _clock.now();
      final last = _lastStepAt;
      if (last == null) {
        _lastStepAt = now; // the first call reports the floor, no step
      } else if (now.difference(last) >= const Duration(milliseconds: 200)) {
        _lastStepAt = now;
        final growth = _slowStart ? 2.0 : 1.25;
        _budget = min(maxBytesPerSec.toDouble(), _budget * growth);
      }
      _applyMeasuredBounds(measured, now, unmeasuredCap: 4 * _initial);
      _describe(measured, rtt, estimate);
      return _budget.round();
    }
    final rttMs = rtt.toDouble();
    final previousFloor = _minRttMs;
    // The lowest round trip seen, forgotten slowly (0.1 % per reading) so a
    // path that genuinely changed (a new route after recovery) can establish
    // a new floor.
    _minRttMs = previousFloor == null
        ? rttMs
        : min(rttMs, previousFloor * 1.001);
    final now = _clock.now();
    final stepEvery = Duration(milliseconds: max(200, rtt));
    final last = _lastStepAt;
    if (last != null && now.difference(last) < stepEvery) {
      // Inside the current round trip: no new step, only the bounds.
      _applyMeasuredBounds(measured, now);
      _describe(measured, rtt, estimate);
      return _budget.round();
    }
    _lastStepAt = now;
    final base = _minRttMs!;
    final inflated = rttMs > max(base * 1.5, base + 150);
    if (inflated) {
      _budget = max(minBytesPerSec.toDouble(), _budget * 0.7);
      _slowStart = false;
      _phase = 'inflated';
    } else {
      final growth = _slowStart ? 2.0 : 1.25;
      _budget = min(maxBytesPerSec.toDouble(), _budget * growth);
      _phase = _slowStart ? 'slow-start' : 'probing';
    }
    _applyMeasuredBounds(measured, now);
    _describe(measured, rtt, estimate);
    return _budget.round();
  }

  /// The measured delivery rate bounds the budget on BOTH sides: a fresh
  /// measurement is the floor (the link just carried that much), and
  /// twice the last measurement (kept for [measuredCapTtlMs]) is the cap
  /// — the probing headroom. Growth alone could climb to the maximum on a
  /// path whose round trip never reads as inflated; the cap is what
  /// holds a 2 KB/s pipe near 2 KB/s. With no measurement inside the
  /// ttl, [unmeasuredCap] (if given) is the only ceiling.
  void _applyMeasuredBounds(int? measured, DateTime now, {int? unmeasuredCap}) {
    if (measured != null) {
      _lastMeasured = measured;
      _lastMeasuredAt = now;
      final floor = min(measured, maxBytesPerSec).toDouble();
      if (_budget < floor) _budget = floor;
    }
    final recent = _lastMeasured;
    final at = _lastMeasuredAt;
    double? cap;
    if (recent != null &&
        at != null &&
        now.difference(at).inMilliseconds <= measuredCapTtlMs) {
      cap = min(2 * recent, maxBytesPerSec).toDouble();
    } else if (unmeasuredCap != null) {
      cap = min(unmeasuredCap, maxBytesPerSec).toDouble();
    }
    if (cap != null && _budget > cap) _budget = cap;
    if (_budget < minBytesPerSec) _budget = minBytesPerSec.toDouble();
  }

  void _describe(int? measured, int? rtt, int? estimate) {
    final floor = _minRttMs;
    lastReason =
        'budget=${_budget.round()} '
        'measured=${measured ?? '-'} '
        'rtt=${rtt ?? '-'} '
        'floor=${floor == null ? '-' : floor.round()} '
        '$_phase '
        'estimate=${estimate ?? '-'}';
  }

  /// The retransmit wait a lane sender should start from: two and a half
  /// round trips, never under [floor] and never over ten seconds. The sender
  /// keeps adapting from its own acks after that.
  Duration retransmitAfter({
    Duration floor = const Duration(milliseconds: 700),
  }) {
    final rtt = readRttMs();
    if (rtt == null) return floor;
    final ms = (rtt * 2.5).round().clamp(floor.inMilliseconds, 10000);
    return Duration(milliseconds: ms);
  }
}
