/// The quality ladder, with every rung's cost taken from a MEASUREMENT.
///
/// Provenance of the numbers (2026-08-01, `tool/mode_matrix.dart` swept 96
/// combinations of frame rate x shaped share x payload size x fanout, 4000
/// frames each; every trace scored by the engine's `trace-gate` against an
/// independently seeded reference profile). Only five combinations were on the
/// cost/leak frontier — nothing else was both cheaper and lower-leak — and all
/// five had frameRate 6 and fanout 1:
///
/// ```text
///   id                     mean_B   wire_B/s        kl
///   fr6_sh0_pl20_fo1         20.0        267    3.2372
///   fr6_sh25_pl20_fo1        90.4       1206    1.9434
///   fr6_sh50_pl20_fo1       168.0       2240    0.9813
///   fr6_sh100_pl20_fo1      312.8       4170    0.0068
/// ```
///
/// Three findings that shape this ladder, and are why it has the rungs it has:
///
///  * Shaped share is the ONLY effective lever. Raising the frame rate or the
///    fanout never lowered leak — fanout 2 produced the same kl at twice the
///    bytes. So the ladder varies shaped share, and treats fanout as a
///    reliability knob whose byte cost must be paid out of the same budget.
///  * The lever is sharply non-linear: 50% → 100% shaped costs 1.9x the bytes
///    and drops leak by a factor of 144. Partial shaping is therefore poor
///    value in the middle and only worth it as a step on the way.
///  * Payload size is irrelevant once shaping is on: 20 B and 40 B both land at
///    312.8 B mean, because the target dwarfs both.
///
/// The rungs are ordered by BYTE COST, ascending. The governor walks down when
/// the link cannot pay, and up only after sustained evidence it can.
library;

/// One rung of the ladder: what it costs, what it leaks, what it gives up.
class QualityRung {
  const QualityRung({
    required this.name,
    required this.frameRate,
    required this.shapedShare,
    required this.fanout,
    required this.measuredWireBps,
    required this.measuredKl,
    required this.givesUp,
  });

  /// Stable identifier, used in logs and in the self-audit record.
  final String name;

  /// Voice frames per second this rung emits.
  final int frameRate;

  /// Fraction of frames padded to a web-profile target, 0.0 to 1.0.
  final double shapedShare;

  /// Copies sent per frame. Above 1 this multiplies bytes without lowering
  /// leak — it buys delivery probability, nothing else.
  final int fanout;

  /// Wire byte rate measured for this configuration, including the 55% framing
  /// overhead the audit reports. Null where the combination was not measured.
  final double? measuredWireBps;

  /// Leak divergence measured for this configuration against the reference
  /// profile. Null where not measured.
  final double? measuredKl;

  /// Plain statement of what this rung sacrifices, for the user-facing
  /// explanation and for the audit trail. A rung whose cost is not named is a
  /// rung nobody can reason about.
  final String givesUp;

  /// True when this rung's cost is a measurement rather than an estimate.
  bool get isMeasured => measuredWireBps != null && measuredKl != null;
}

/// The ladder, cheapest first.
///
/// `survival` sits below every measured rung on purpose: it is the rung the
/// governor falls to when nothing else fits, and its only promise is that
/// voice keeps flowing. It is deliberately cheaper than the cheapest MEASURED
/// rung, because a rung that cannot be afforded is not a fallback.
const List<QualityRung> qualityLadder = [
  QualityRung(
    // Provenance: DOCS-ALL/FINAL-REPORT.md:110 states payload_bitrate
    // 31.8000 bps and wire_bitrate 32.0000 bps for this codec — BITS per
    // second, measured on a recording, not a live call. This ladder is in
    // BYTES per second, so the wire figure converts as 32.0 / 8 = 4.0 B/s.
    // It is already a wire figure in its source; the 55% framing-overhead
    // divisor that applies to the other rungs must NOT be applied here.
    // No leak (kl) measurement exists for this rung, hence measuredKl null.
    name: 'ultra-lean-31.8',
    frameRate: 6,
    shapedShare: 0.0,
    fanout: 1,
    measuredWireBps: 4.0,
    measuredKl: null,
    givesUp:
        'speaker identity is not preserved at this rate; this is a '
        'last-resort path, not a replacement for the normal codec, and the '
        '31.8 bps figure was measured on a recording, not a live call',
  ),
  QualityRung(
    name: 'survival',
    frameRate: 6,
    shapedShare: 0.0,
    fanout: 1,
    measuredWireBps: 267,
    measuredKl: 3.2372,
    givesUp: 'all size shaping and all redundancy; voice only, lowest rate',
  ),
  QualityRung(
    name: 'lean',
    frameRate: 12,
    shapedShare: 0.0,
    fanout: 1,
    measuredWireBps: 533,
    measuredKl: 3.2372,
    givesUp: 'all size shaping and all redundancy',
  ),
  QualityRung(
    name: 'normal',
    frameRate: 25,
    shapedShare: 0.0,
    fanout: 1,
    measuredWireBps: 1111,
    measuredKl: 3.2372,
    givesUp: 'size shaping entirely; this is the ordinary call',
  ),
  QualityRung(
    name: 'shaped-quarter',
    frameRate: 6,
    shapedShare: 0.25,
    fanout: 1,
    measuredWireBps: 1206,
    measuredKl: 1.9434,
    givesUp: 'three quarters of frames stay unshaped; no redundancy',
  ),
  QualityRung(
    name: 'shaped-half',
    frameRate: 6,
    shapedShare: 0.5,
    fanout: 1,
    measuredWireBps: 2240,
    measuredKl: 0.9813,
    givesUp: 'half the frames stay unshaped; no redundancy',
  ),
  QualityRung(
    name: 'shaped-full',
    frameRate: 6,
    shapedShare: 1.0,
    fanout: 1,
    measuredWireBps: 4170,
    measuredKl: 0.0068,
    givesUp: 'frame rate down to 6/s and 15x the bytes, to erase the size tell',
  ),
];

/// Index of the rung the governor falls back to when it cannot afford anything.
/// Kept as a named constant so the invariant "there is always somewhere to go"
/// is stated once and enforced by a test. Since the ultra-lean-31.8 rung was
/// added as the cheapest entry, it is the last-resort rung.
const int survivalRungIndex = 0;
