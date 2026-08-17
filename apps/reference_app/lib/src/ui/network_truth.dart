/// Shared "network-truth" vocabulary for the UI layer.
///
/// The rule every widget in this app obeys: **UI state is derived from a
/// real network signal, never invented.** Each value below names the signal
/// that produces it; if no signal exists, the state does not exist either
/// (that is why there is no "queued" — today's controller hands a message to
/// the messenger before the entry is even visible, so the first observable
/// truth is already "written to the channel").
library;

import 'dart:collection';

import 'package:adaptive_transport/adaptive_transport.dart'
    show NativeShapeAbsent, NativeShapeAbsentCause, NativeShapeAvailability;
import 'package:flutter/foundation.dart' show immutable;

/// Truth ladder for one outgoing message.
enum MessageTruthStatus {
  /// The send future is still in flight (frame not yet written). Usually
  /// sub-frame for text; visible for large staged content.
  sending,

  /// The messenger's `send()` completed: the frame was written to the
  /// channel. Says nothing about the far side — one grey tick.
  sent,

  /// The peer's real ack arrived (`DeliveryState.delivered` on the
  /// messenger's deliveries stream) — two ticks.
  delivered,

  /// Content proven end-to-end: sha of the received bytes matches the
  /// announced digest (staged photos / attachments) — shield badge.
  verified,

  /// The messenger reported `DeliveryState.failed` after retry exhaustion.
  /// Terminal for this attempt; the UI offers retry.
  failed,
}

/// One reading of the live path, sourced from real RTCStats deltas
/// ([WebRtcPathChannel] / SendResult) or from the loopback demo's own
/// counters — never synthesized inside a widget.
@immutable
class CallQualityReading {
  const CallQualityReading({
    required this.at,
    this.rttMs,
    this.lossFraction,
    this.bitrateBps,
  });

  /// When the reading was taken (monotonic enough for charting).
  final Duration at;

  /// Round-trip time in milliseconds; null when the stats had no answer yet.
  final int? rttMs;

  /// Packet-loss fraction 0..1 over the last interval; null = unknown.
  final double? lossFraction;

  /// Estimated available/used bitrate in bits per second; null = unknown.
  final int? bitrateBps;
}

/// Coarse quality band for coloring the gauge and sparklines.
enum QualityBand { good, fair, poor, unknown }

/// Maps a reading to its band. Thresholds follow the project's measured
/// operating points: the ladder treats rtt≈2s/loss≥15% networks as
/// survivable, so "poor" here starts well before that cliff.
QualityBand bandOf(CallQualityReading? r) {
  if (r == null) return QualityBand.unknown;
  final rtt = r.rttMs;
  final loss = r.lossFraction;
  if (rtt == null && loss == null) return QualityBand.unknown;
  if ((loss ?? 0) >= 0.12 || (rtt ?? 0) >= 700) return QualityBand.poor;
  if ((loss ?? 0) >= 0.04 || (rtt ?? 0) >= 280) return QualityBand.fair;
  return QualityBand.good;
}

/// Display text for the native shape capability, derived from the transport
/// package's own [NativeShapeAvailability] value.
///
/// This function is the ONLY place in the app where text about this
/// capability is written. Every screen must render its words through here,
/// because a screen that authors its own sentence can claim something the
/// code cannot back — the transport package's value is the sole signal, and
/// this is its sole translation.
///
/// Both switches are exhaustive with no `default` and no `_` on purpose:
/// when the package gains a second availability member (or a new cause),
/// this function stops compiling instead of silently rendering today's
/// wording for a state it was never written about.
String nativeShapeAvailabilityText(NativeShapeAvailability availability) =>
    switch (availability) {
      NativeShapeAbsent(:final cause) => switch (cause) {
        NativeShapeAbsentCause.noModuleLinked =>
          'Native shape support is not available in this build: '
              'no native module is linked into the app.',
        NativeShapeAbsentCause.moduleReportedUnavailable =>
          'Native shape support is not available in this build: '
              'the linked native module reported itself unavailable.',
        NativeShapeAbsentCause.probeSucceededButPresentStateNotRepresentable =>
          'Native shape support is not available in this build: '
              'a probe succeeded, but this build cannot represent a '
              'working state, so none is claimed.',
      },
    };

/// Fixed-capacity ring of recent readings for sparklines: O(1) append,
/// no per-frame allocation, capacity chosen for ~2 minutes at 1 Hz.
class QualityHistory {
  QualityHistory({this.capacity = 120});

  final int capacity;
  final ListQueue<CallQualityReading> _ring = ListQueue();

  void add(CallQualityReading r) {
    if (_ring.length == capacity) _ring.removeFirst();
    _ring.addLast(r);
  }

  /// Oldest→newest view for painting.
  Iterable<CallQualityReading> get readings => _ring;

  CallQualityReading? get latest => _ring.isEmpty ? null : _ring.last;

  int get length => _ring.length;
}
