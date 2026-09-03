/// The send budget the call's data lanes (photos, video notes) are allowed
/// next to the audio and the control plane — a MODEL of the live path, not a
/// constant.
///
/// Measured on the rig (bandwidth profile, 32 kbit/s, 2026-09-04): an
/// unbudgeted lane filled whatever audio left free, the shared queue grew to
/// ~1.9 s of round trip, loss rose past 20 % and the call fell into survival
/// mode while the photo never verified. The E2E harness had proved the cure
/// on the same profile — a fixed quarter of the LINK for the lane — but the
/// harness knew the link from its shaping defines. The app does not, so the
/// quarter is taken from what the path itself reports:
///
/// 1. The transport's congestion-control estimate of available outgoing
///    bandwidth (the selected candidate pair's `availableOutgoingBitrate`),
///    when the stats carry it: budget = 25 % of it.
/// 2. Otherwise a delay-based control on the path's round trip: the budget
///    grows ×1.25 per round trip while the round trip stays near the lowest
///    seen, and shrinks ×0.7 when it inflates past 1.5× that floor (or by
///    150 ms) — the lane's own queueing is the inflation, so it backs off
///    before audio pays for it.
///
/// Both are clamped to [minBytesPerSec, maxBytesPerSec]; with no readings at
/// all the lane runs at [initialBytesPerSec]. Also derives the retransmit
/// floor a lane sender should start from (2.5 round trips, 700 ms..10 s).
library;

import 'dart:math';

import 'package:clock/clock.dart';

class LaneGovernor {
  LaneGovernor({
    required this.readRttMs,
    this.readAvailableOutgoingBps,
    this.share = 0.25,
    int initialBytesPerSec = 16 * 1024,
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
  }

  /// The path's latest round trip in milliseconds, null before a reading.
  final int? Function() readRttMs;

  /// The transport's available-outgoing-bandwidth estimate in bit/s, null
  /// when the stats carry none.
  final int? Function()? readAvailableOutgoingBps;

  /// The lane's share of a known link.
  final double share;
  final int minBytesPerSec;
  final int maxBytesPerSec;
  final Clock _clock;

  double _budget;
  double? _minRttMs;
  DateTime? _lastStepAt;

  /// Why the last budget was what it was — for the row note and the panel.
  String lastReason = 'initial';

  /// The budget in bytes per second, re-derived on every call (lane senders
  /// read it per chunk).
  int budgetBytesPerSec() {
    final available = readAvailableOutgoingBps?.call();
    if (available != null && available > 0) {
      final fromLink = (available * share / 8).round().clamp(
        minBytesPerSec,
        maxBytesPerSec,
      );
      _budget = fromLink.toDouble();
      lastReason = 'link estimate ${available}bps × $share';
      return fromLink;
    }
    final rtt = readRttMs();
    if (rtt == null) {
      lastReason = 'no readings yet';
      return _budget.round();
    }
    final rttMs = rtt.toDouble();
    final floor = _minRttMs;
    // The lowest round trip seen, forgotten slowly so a path that genuinely
    // changed (a new route after recovery) can establish a new floor.
    _minRttMs = floor == null ? rttMs : min(rttMs, floor * 1.001);
    final now = _clock.now();
    final stepEvery = Duration(milliseconds: max(200, rtt));
    final last = _lastStepAt;
    if (last != null && now.difference(last) < stepEvery) {
      return _budget.round();
    }
    _lastStepAt = now;
    final base = _minRttMs!;
    final inflated = rttMs > max(base * 1.5, base + 150);
    if (inflated) {
      _budget = max(minBytesPerSec.toDouble(), _budget * 0.7);
      lastReason = 'rtt ${rtt}ms inflated over floor ${base.round()}ms';
    } else {
      _budget = min(maxBytesPerSec.toDouble(), _budget * 1.25);
      lastReason = 'rtt ${rtt}ms near floor ${base.round()}ms';
    }
    return _budget.round();
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
