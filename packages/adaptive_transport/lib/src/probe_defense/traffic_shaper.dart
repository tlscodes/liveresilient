/// Behavioral traffic shaping: length distribution and timing jitter.
///
/// Length and timing are what survive encryption. A voice codec emitting a
/// frame every 20 ms at a near-constant size draws a rectangle in the
/// (length, inter-arrival) plane that a statistical classifier recognizes
/// without reading a single plaintext byte. Two levers answer that:
///
/// 1. **Length** — pad each frame to a target drawn from a distribution
///    instead of to its own natural size, so the wire length stops being a
///    function of the payload.
/// 2. **Timing** — insert microsecond-scale jitter, more of it during
///    bursts, so inter-arrival times stop being a clock.
///
/// Both cost something real, and the cost is stated rather than hidden:
/// padding spends bandwidth, jitter spends latency. The defaults here are
/// deliberately modest — a voice call that jitters itself into 40 ms of
/// added delay has defeated its own purpose. [TrafficShapingPolicy.voice]
/// is the tuned-for-calls preset; [TrafficShapingPolicy.aggressive] trades
/// call quality for flatter statistics and should be a user-visible choice,
/// not a silent default.
///
/// The padded wire format is byte-compatible with [MicroDatagramLane] —
/// `payload · random pad · u16 big-endian padLength` — so a frame shaped
/// here decodes with `decodeAndStripPadding` and the two can be mixed on
/// one path.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';

/// How a target wire length is drawn.
enum LengthDistribution {
  /// Every frame keeps its natural length (plus the 2-byte trailer).
  none,

  /// Target drawn uniformly from `[payload, payload + maxPadding]`.
  uniform,

  /// Target drawn from a normal distribution centered [gaussianMean] bytes
  /// above the payload. Produces a bell of lengths rather than the flat
  /// band uniform padding produces — a classifier trained on "flat band =
  /// padded" does not fire on it.
  gaussian,

  /// Target snapped up to the next entry in a fixed ladder of lengths, so
  /// the wire shows a handful of common sizes and nothing between them.
  /// The ladder is the same set of MTU-friendly sizes ordinary TLS records
  /// land on.
  bucketed,
}

/// Tunables for [TrafficShaper].
class TrafficShapingPolicy {
  const TrafficShapingPolicy({
    this.distribution = LengthDistribution.gaussian,
    this.maxPadding = 96,
    this.gaussianMean = 32,
    this.gaussianStdDev = 16,
    this.lengthBuckets = const [64, 128, 256, 512, 1024, 1350],
    this.recordSizeLimit = 16385,
    this.minJitter = Duration.zero,
    this.maxJitter = const Duration(microseconds: 1500),
    this.burstThreshold = 4,
    this.burstWindow = const Duration(milliseconds: 20),
    this.burstJitterMultiplier = 3,
  });

  final LengthDistribution distribution;

  /// Upper bound on padding bytes added to any one frame. Bounds the
  /// bandwidth cost: at 50 frames/second, 96 bytes is under 40 kbit/s.
  final int maxPadding;

  final int gaussianMean;
  final int gaussianStdDev;

  /// Ladder used by [LengthDistribution.bucketed], ascending.
  final List<int> lengthBuckets;

  /// TLS 1.3 `record_size_limit` (RFC 8449) to advertise. Capping records
  /// below the 16 KiB maximum makes our record-length histogram look like a
  /// browser's rather than like a bulk transfer.
  final int recordSizeLimit;

  final Duration minJitter;

  /// Ceiling on delay added to any single frame outside a burst. Kept at
  /// 1.5 ms so shaping stays under the human threshold for a voice path.
  final Duration maxJitter;

  /// Frames within [burstWindow] before the sender counts as bursting.
  final int burstThreshold;
  final Duration burstWindow;

  /// How much [maxJitter] is multiplied by while bursting — bursts are the
  /// most legible timing feature, so they get the most disruption.
  final int burstJitterMultiplier;

  /// Tuned for a live call: shaping present, latency budget respected.
  static const TrafficShapingPolicy voice = TrafficShapingPolicy();

  /// Flatter statistics at a real cost in latency and bandwidth.
  static const TrafficShapingPolicy aggressive = TrafficShapingPolicy(
    distribution: LengthDistribution.bucketed,
    maxPadding: 512,
    maxJitter: Duration(microseconds: 8000),
    burstJitterMultiplier: 4,
  );

  /// Shaping off — for measuring what shaping costs.
  static const TrafficShapingPolicy disabled = TrafficShapingPolicy(
    distribution: LengthDistribution.none,
    maxPadding: 0,
    maxJitter: Duration.zero,
  );
}

/// Chooses wire lengths and pads frames to them.
class TrafficShaper {
  /// [random] defaults to [Random.secure]; a non-secure RNG is test-only
  /// and must be opted into, because padding content and length choice are
  /// both security surfaces.
  TrafficShaper({
    this.policy = TrafficShapingPolicy.voice,
    Random? random,
    bool allowInsecureRandom = false,
  }) : _random = random ?? Random.secure() {
    if (random != null && !allowInsecureRandom) {
      throw ArgumentError(
        'Injected RNG requires allowInsecureRandom: true (test-only)',
      );
    }
  }

  final TrafficShapingPolicy policy;
  final Random _random;

  /// Two-byte big-endian pad-length trailer, matching [MicroDatagramLane].
  static const int trailerBytes = 2;

  /// Padding bytes to add to a [payloadLength]-byte payload, always in
  /// `[0, policy.maxPadding]`.
  int paddingFor(int payloadLength) {
    switch (policy.distribution) {
      case LengthDistribution.none:
        return 0;
      case LengthDistribution.uniform:
        return policy.maxPadding == 0 ? 0 : _random.nextInt(policy.maxPadding + 1);
      case LengthDistribution.gaussian:
        final draw = _gaussian(policy.gaussianMean, policy.gaussianStdDev);
        return draw.round().clamp(0, policy.maxPadding);
      case LengthDistribution.bucketed:
        final target = _nextBucket(payloadLength + trailerBytes);
        if (target == null) return 0;
        return (target - payloadLength - trailerBytes).clamp(
          0,
          policy.maxPadding,
        );
    }
  }

  /// Pads [payload] to its drawn target length.
  ///
  /// Wire format: `payload · random pad · u16 big-endian padLength`.
  Uint8List shape(List<int> payload) {
    final padLength = paddingFor(payload.length);
    final out = Uint8List(payload.length + padLength + trailerBytes);
    out.setRange(0, payload.length, payload);
    for (var i = 0; i < padLength; i++) {
      out[payload.length + i] = _random.nextInt(256);
    }
    out[out.length - 2] = (padLength >> 8) & 0xFF;
    out[out.length - 1] = padLength & 0xFF;
    return out;
  }

  /// Reverses [shape]. Throws [FormatException] on a frame whose trailer
  /// does not describe its own length.
  static Uint8List unshape(Uint8List frame) {
    if (frame.length < trailerBytes) {
      throw FormatException(
        'frame shorter than the $trailerBytes-byte pad trailer: '
        '${frame.length}',
      );
    }
    final padLength =
        (frame[frame.length - 2] << 8) | frame[frame.length - 1];
    final originalLength = frame.length - trailerBytes - padLength;
    if (originalLength < 0) {
      throw FormatException('invalid padding boundary length: $padLength');
    }
    return Uint8List.sublistView(frame, 0, originalLength);
  }

  /// Smallest bucket at or above [length], or null when [length] already
  /// exceeds the ladder (an oversized frame is not stretched further).
  int? _nextBucket(int length) {
    for (final bucket in policy.lengthBuckets) {
      if (bucket >= length) return bucket;
    }
    return null;
  }

  /// One draw from N(mean, stdDev) via the Box-Muller transform.
  double _gaussian(num mean, num stdDev) {
    // nextDouble() can return 0, and log(0) is -infinity.
    final u1 = 1.0 - _random.nextDouble();
    final u2 = _random.nextDouble();
    final magnitude = sqrt(-2.0 * log(u1));
    return mean + stdDev * magnitude * cos(2 * pi * u2);
  }
}

/// Adds delay between frames, more of it while the sender is bursting.
///
/// Burst detection is a sliding count of send times: once
/// [TrafficShapingPolicy.burstThreshold] frames fall inside
/// [TrafficShapingPolicy.burstWindow], the jitter ceiling is multiplied.
/// The state is deliberately observable ([isBursting], [recentSendCount])
/// so a caller can surface what shaping is costing rather than guess.
class AdaptiveJitter {
  AdaptiveJitter({
    this.policy = TrafficShapingPolicy.voice,
    Random? random,
    bool allowInsecureRandom = false,
  }) : _random = random ?? Random.secure() {
    if (random != null && !allowInsecureRandom) {
      throw ArgumentError(
        'Injected RNG requires allowInsecureRandom: true (test-only)',
      );
    }
  }

  final TrafficShapingPolicy policy;
  final Random _random;
  final List<DateTime> _sendTimes = [];

  /// Frames sent within the burst window as of now.
  int get recentSendCount {
    _expire();
    return _sendTimes.length;
  }

  /// Whether the sender is currently in a burst.
  bool get isBursting => recentSendCount >= policy.burstThreshold;

  /// Draws the delay for the next frame and records it as sent.
  ///
  /// Uniform over `[minJitter, ceiling]`, where the ceiling is
  /// [TrafficShapingPolicy.maxJitter] multiplied while bursting. Uniform
  /// rather than Gaussian on purpose: a normal delay distribution has a
  /// recognizable mean, and it is the *mean* that a timing classifier locks
  /// onto first.
  Duration nextDelay() {
    final bursting = isBursting;
    _sendTimes.add(clock.now());

    final ceiling = bursting
        ? policy.maxJitter * policy.burstJitterMultiplier
        : policy.maxJitter;
    final floor = policy.minJitter;
    final spread = ceiling.inMicroseconds - floor.inMicroseconds;
    if (spread <= 0) return floor;
    return Duration(
      microseconds: floor.inMicroseconds + _random.nextInt(spread + 1),
    );
  }

  /// Waits [nextDelay] before returning. A zero delay does not yield, so
  /// the disabled policy costs nothing.
  Future<void> pace() async {
    final delay = nextDelay();
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  void _expire() {
    final cutoff = clock.now().subtract(policy.burstWindow);
    _sendTimes.removeWhere((t) => t.isBefore(cutoff));
  }
}
