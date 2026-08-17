// Prints what admission actually decides at the bandwidths gate 1f names, so
// the 1f tests assert measured values instead of assumed ones. Kept in the
// repository because "what does 16 kbit/s admit" is asked every time someone
// reads that gate, and re-deriving it by hand is how wrong constants get
// written into tests.
//
//   dart run example/probe_admission.dart
import 'package:media_webrtc/media_webrtc.dart';

void main() {
  for (final streams in [1, 2]) {
    for (final bw in [64000, 32000, 24000, 16000, 12000, 8000]) {
      final admission = OpusWireBudget.forBandwidth(
        bw,
        concurrentStreams: streams,
      );
      final text = switch (admission) {
        OpusWireFitted(budget: final b) =>
          'fitted   rate=${b.opusRateBps} ptime=${b.ptimeMs} '
              'wire=${b.chosenWireRateBps} occupancy='
              '${b.occupancy!.toStringAsFixed(3)}',
        OpusWireUnconstrained() => 'unconstrained',
        OpusWireNoCandidateFits(
          cause: final c,
          cheapestWireRateBps: final cheap,
          minimumBandwidthBps: final min,
        ) =>
          'refused  cause=$c cheapestWire=$cheap minBandwidth=$min',
      };
      print('streams=$streams bw=$bw  ->  $text');
    }
  }
}
