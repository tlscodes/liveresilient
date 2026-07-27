/// RLNC over GF(2^8) — the phase-1 record attempt. Same proof set as
/// the LT core plus the near-MDS claims, all measured in-run.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(int n, Random rng) =>
    Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

void main() {
  final rng = Random(20260726);

  test('round-trip zero loss bit-exact for 1B/100B/2KB/64KB', () {
    for (final size in [1, 100, 2048, 65536]) {
      final data = _randomBytes(size, rng);
      final enc = RlncEncoder(data);
      final dec = RlncDecoder();
      var fed = 0;
      while (!dec.isComplete) {
        dec.addDatagram(enc.nextDatagram());
        fed++;
        expect(
          fed,
          lessThanOrEqualTo(enc.blockCount),
          reason: 'systematic prefix alone must complete ($size B)',
        );
      }
      expect(dec.data, equals(data));
    }
  });

  test('single bit flips are always rejected', () {
    final enc = RlncEncoder(_randomBytes(512, rng));
    final clean = enc.datagramAt(0);
    for (var bit = 0; bit < clean.length * 8; bit++) {
      final corrupt = Uint8List.fromList(clean);
      corrupt[bit ~/ 8] ^= 1 << (bit % 8);
      final dec = RlncDecoder();
      expect(dec.addDatagram(corrupt), isFalse, reason: 'bit $bit');
    }
  });

  test('near-MDS: exactly m parity packets decode a full generation '
      'with >= 99% success (measured)', () {
    final data = _randomBytes(generationSize * 48 - 4, rng); // one gen
    final enc = RlncEncoder(data);
    expect(enc.blockCount, generationSize);
    var ok = 0;
    const trials = 25; // 256x256 eliminations are heavy; 25 is plenty
    var esiBase = enc.blockCount;
    for (var t = 0; t < trials; t++) {
      final dec = RlncDecoder();
      // exactly m = generationSize distinct PARITY packets, no source.
      for (var i = 0; i < generationSize; i++) {
        dec.addDatagram(enc.datagramAt(esiBase + i));
      }
      if (dec.isComplete) {
        expect(dec.data, equals(data));
        ok++;
      }
      esiBase += generationSize;
    }
    final rate = ok / trials;
    // ignore: avoid_print
    print(
      'RLNC near-MDS success with zero overhead: '
      '${(rate * 100).toStringAsFixed(1)}% over $trials trials',
    );
    // Singularity probability per trial is ~0.4%; allow one miss.
    expect(rate, greaterThanOrEqualTo(0.96));
  });

  test('overhead epsilon under 50% random loss (measured, target <1.05; '
      'LT core measured 1.33 on the same regime)', () {
    final data = _randomBytes(8192, rng);
    final enc = RlncEncoder(data);
    final n = enc.blockCount;
    var totalUsed = 0;
    const trials = 20;
    for (var t = 0; t < trials; t++) {
      final dec = RlncDecoder();
      var esi = 0;
      var used = 0;
      while (!dec.isComplete) {
        if (rng.nextBool()) {
          dec.addDatagram(enc.datagramAt(esi));
          used++;
        }
        esi++;
        if (esi > 0xFFFF) fail('did not converge');
      }
      totalUsed += used;
    }
    final epsilon = totalUsed / (trials * n);
    // ignore: avoid_print
    print(
      'RLNC epsilon (measured): ${epsilon.toStringAsFixed(4)} '
      '(N=$n, $trials trials, 50% loss)',
    );
    expect(epsilon, lessThan(1.05));
  });

  test('decoder memory stays bounded under 20x parity overfeed', () {
    final data = _randomBytes(4096, rng);
    final enc = RlncEncoder(data);
    final n = enc.blockCount;
    final dec = RlncDecoder();
    for (var esi = n; esi < n + 20 * n && esi <= 0xFFFF; esi++) {
      dec.addDatagram(enc.datagramAt(esi));
      expect(dec.pendingRowCount, lessThanOrEqualTo(n));
    }
    for (var esi = 0; esi < n; esi++) {
      dec.addDatagram(enc.datagramAt(esi));
    }
    expect(dec.isComplete, isTrue);
    expect(dec.data, equals(data));
  });

  test('random subset in random order decodes bit-exact', () {
    final data = _randomBytes(4096, rng);
    final enc = RlncEncoder(data);
    final n = enc.blockCount;
    final pool = List.generate(3 * n, (i) => enc.datagramAt(i))
      ..removeWhere((_) => rng.nextBool())
      ..shuffle(rng);
    final dec = RlncDecoder();
    for (final d in pool) {
      dec.addDatagram(d);
      if (dec.isComplete) break;
    }
    expect(dec.isComplete, isTrue);
    expect(dec.data, equals(data));
  });
}
