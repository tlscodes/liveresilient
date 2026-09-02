/// Turns the transport's own stats samples into the reading the call screen
/// charts, so the gauge shows measured numbers instead of a demo profile.
///
/// This is a projection, not a computation: every field comes from
/// [RtcStatsSample], which the adaptation ladder already consumes. The only
/// judgement here is which throughput to show — incoming, because the gauge
/// answers "how is this call arriving for me", and a send-side figure would
/// read as the same question with a different answer.
library;

import 'package:media_webrtc/media_webrtc.dart' show RtcStatsSample;

import 'ui/network_truth.dart';

/// Label shown beside live readings, so the source chip never disappears —
/// it changes text, and a viewer can always tell what they are looking at.
const String liveQualitySourceLabel = 'live path stats';

CallQualityReading readingFromSample(
  RtcStatsSample s, {
  required Duration at,
}) => CallQualityReading(
  at: at,
  rttMs: s.rttMs,
  lossFraction: s.packetLossFraction,
  bitrateBps: s.incomingBitrateBps,
);
