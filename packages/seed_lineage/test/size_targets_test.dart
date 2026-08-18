/// Cross-language vectors for the seeded stream and the size-target draw.
///
/// The expected values below were PRINTED BY THE ENGINE ITSELF
/// (`cargo run -p shaping --example vectors`, 2026-08-01) — not re-derived from
/// the same formulas on this side. Re-deriving would only prove the two
/// descriptions match; running the other implementation proves the two OUTPUTS
/// match, which is the property the shaping layer actually depends on.
library;

import 'dart:typed_data';

import 'package:seed_lineage/seed_lineage.dart';
import 'package:test/test.dart';

final Uint8List fixedManifestHash = Uint8List.fromList(
  List<int>.generate(32, (i) => i),
);

const int rootSeed = 1337;

/// From the engine: `next_u64 x6`.
///
/// The fourth draw, 9599475733468981044 as an unsigned 64-bit value, is above
/// 2^63 and therefore has no Dart literal: Dart ints are signed. It is written
/// here as the same 64 bits interpreted as signed (value - 2^64), which is
/// exactly what [SeedStream.nextU64] returns for it. Writing the unsigned
/// decimal would not compile, and rounding it into a double would silently
/// change the bits — the whole point of the vector.
const List<int> engineDraws = [
  5246037602978357082,
  2078107814799198468,
  6684455220917201609,
  -8847268340240570572, // unsigned 9599475733468981044
  8117873592052955944,
  7117074566834704854,
];

/// From the engine: `next_target x12`.
const List<int> engineTargets = [
  53,
  102,
  86,
  80,
  125,
  142,
  57,
  99,
  57,
  41,
  876,
  69,
];

void main() {
  SeedStream stream() => SeedStream.forPath(
    rootSeed: rootSeed,
    manifestHash: fixedManifestHash,
    logicalPath: shapingTargetsPath,
  );

  test('the raw stream matches the engine draw-for-draw', () {
    final s = stream();
    final got = [for (var i = 0; i < engineDraws.length; i++) s.nextU64()];
    expect(got, engineDraws);
  });

  test('crossing the 4-draw block boundary stays in step', () {
    // The 5th and 6th draws come from the second block. Asserted separately
    // because an off-by-one in the refill rule would still pass a 4-draw test.
    final s = stream();
    for (var i = 0; i < 4; i++) {
      s.nextU64();
    }
    expect(s.nextU64(), engineDraws[4]);
    expect(s.nextU64(), engineDraws[5]);
  });

  test('size targets match the engine target-for-target', () {
    final t = SizeTargets(rootSeed: rootSeed, manifestHash: fixedManifestHash);
    final got = [for (var i = 0; i < engineTargets.length; i++) t.nextTarget()];
    expect(got, engineTargets);
  });

  test('targets stay inside the declared 70/30 web mix bounds', () {
    final t = SizeTargets(rootSeed: rootSeed, manifestHash: fixedManifestHash);
    for (var i = 0; i < 500; i++) {
      final v = t.nextTarget();
      final small = v >= 40 && v < 160;
      final large = v >= 200 && v < 1400;
      expect(small || large, isTrue, reason: 'target $v outside both modes');
    }
  });

  test('padding grows to the target and never shrinks', () {
    expect(padTo([1, 2, 3], 6), Uint8List.fromList([1, 2, 3, 0, 0, 0]));
    expect(padTo([1, 2, 3, 4], 2), Uint8List.fromList([1, 2, 3, 4]));
  });

  test('nextBelow rejects a non-positive bound', () {
    expect(() => stream().nextBelow(0), throwsArgumentError);
  });
}
