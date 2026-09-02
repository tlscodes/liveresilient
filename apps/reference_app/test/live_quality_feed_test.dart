/// Pins the projection from measured stats to the reading the gauge charts.
///
/// This is the seam where a real number could quietly become a wrong one: the
/// gauge cannot tell a mis-scaled figure from a correct one, and neither can a
/// screenshot. The previous version of this screen showed a scripted profile
/// for months without anything failing, which is the argument for testing the
/// projection rather than trusting it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart' show RtcStatsSample;
import 'package:reference_app/src/live_quality_feed.dart';

RtcStatsSample _sample({
  double loss = 0.0,
  int rttMs = 0,
  int incoming = 0,
  int outgoing = 0,
}) => RtcStatsSample(
  packetLossFraction: loss,
  rttMs: rttMs,
  jitterMs: 0,
  incomingBitrateBps: incoming,
  outgoingBitrateBps: outgoing,
  availableOutgoingBitrateBps: null,
  timestampMs: 0,
);

void main() {
  group('readingFromSample', () {
    test('carries loss, round-trip time and throughput unchanged', () {
      final r = readingFromSample(
        _sample(loss: 0.42, rttMs: 830, incoming: 24000),
        at: const Duration(seconds: 7),
      );

      expect(r.lossFraction, 0.42);
      expect(r.rttMs, 830);
      expect(r.bitrateBps, 24000);
      expect(r.at, const Duration(seconds: 7));
    });

    test('charts the incoming rate, not the outgoing one', () {
      // The gauge answers "how is this call arriving for me". Showing the send
      // side would be the same question with a different answer, and nothing
      // on screen would reveal the swap.
      final r = readingFromSample(
        _sample(incoming: 12000, outgoing: 96000),
        at: Duration.zero,
      );
      expect(r.bitrateBps, 12000);
    });

    test('a zero reading stays zero rather than becoming unknown', () {
      // Null means "the stats had no answer yet" in this type. A measured zero
      // is a real, different fact — a stalled path — and collapsing the two
      // would make a dead link look like a starting one.
      final r = readingFromSample(_sample(), at: Duration.zero);
      expect(r.lossFraction, 0.0);
      expect(r.rttMs, 0);
      expect(r.bitrateBps, 0);
      expect(r.lossFraction, isNotNull);
    });

    test('total loss is carried as 1.0, not clamped away', () {
      final r = readingFromSample(_sample(loss: 1.0), at: Duration.zero);
      expect(r.lossFraction, 1.0);
    });

    test('the live label is distinct from the demo one', () {
      // The chip must change text rather than disappear when data becomes
      // real, so "where did this come from" is answerable at every moment.
      expect(liveQualitySourceLabel, isNotEmpty);
      expect(liveQualitySourceLabel, isNot('synthetic demo profile'));
    });
  });
}
