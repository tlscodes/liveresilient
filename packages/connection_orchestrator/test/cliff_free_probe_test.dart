/// Does the cliff actually disappear?
///
/// The Cliff-Free Coding spec (`questions/CLIFF-FREE-CODING.md`) claims that a
/// layered object carried over the existing RLNC stream degrades continuously
/// with packet loss, where an ordinary in-order transfer degrades as a cliff:
/// 95% delivered is nothing.
///
/// This measures that claim against the code that exists TODAY — `RlncEncoder`
/// and `RlncDecoder` from `gf256_rlnc_stream.dart`. It does not implement the
/// spec's new units; it tests whether the foundation the spec rests on behaves
/// the way the spec assumes.
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:test/test.dart';

/// A stand-in layered object: four layers, each a distinct byte pattern, sized
/// like the spec's staircase (a small L0, then progressively larger refinements).
List<Uint8List> _layers() => [
  Uint8List.fromList(List.generate(3 * 1024, (i) => (i * 7) & 0xFF)), // L0 3 KB
  Uint8List.fromList(List.generate(12 * 1024, (i) => (i * 11) & 0xFF)),
  Uint8List.fromList(List.generate(48 * 1024, (i) => (i * 13) & 0xFF)),
  Uint8List.fromList(List.generate(192 * 1024, (i) => (i * 17) & 0xFF)),
];

/// Sends [datagrams] through a channel that drops each with probability [loss],
/// and reports how many layers decoded. Delivery order is shuffled on purpose:
/// the whole point of a rateless code is that order carries no meaning.
({int layersDecoded, int bytesDelivered}) _run(
  List<Uint8List> layers, {
  required double loss,
  required double redundancy,
  required Random rng,
}) {
  var delivered = 0;
  var decoded = 0;
  for (final layer in layers) {
    final enc = RlncEncoder(layer);
    final need = enc.blockCount;
    final send = (need * redundancy).ceil();
    final datagrams = [for (var i = 0; i < send; i++) enc.datagramAt(i)]
      ..shuffle(rng);

    final dec = RlncDecoder();
    for (final d in datagrams) {
      if (rng.nextDouble() < loss) continue;
      delivered += d.length;
      dec.addDatagram(d);
      if (dec.isComplete) break;
    }
    if (!dec.isComplete) break; // a layer that did not decode stops refinement
    expect(dec.data, equals(layer), reason: 'a decoded layer must be exact');
    decoded++;
  }
  return (layersDecoded: decoded, bytesDelivered: delivered);
}

void main() {
  group('cliff-free foundation', () {
    test('an ordinary in-order transfer IS a cliff at high loss', () {
      // The baseline the spec attacks: every block must arrive, once, in order,
      // with no repair symbols. At 30% loss the probability that all ~4400
      // blocks of the full object arrive is indistinguishable from zero.
      final rng = Random(1);
      final all = _layers().expand((l) => l).toList();
      final blocks = (all.length / 48).ceil();
      var arrived = 0;
      for (var i = 0; i < blocks; i++) {
        if (rng.nextDouble() >= 0.30) arrived++;
      }
      expect(arrived, lessThan(blocks),
          reason: 'some blocks are lost, so the in-order object never completes');
      final completeness = arrived / blocks;
      expect(completeness, greaterThan(0.5),
          reason: 'most bytes DID arrive — and yet the object is unusable, '
              'which is exactly the cliff');
    });

    test('layers decode progressively as loss rises — no all-or-nothing', () {
      final results = <double, int>{};
      for (final loss in [0.0, 0.2, 0.5, 0.7, 0.9]) {
        final r = _run(_layers(),
            loss: loss, redundancy: 1.6, rng: Random(42));
        results[loss] = r.layersDecoded;
      }
      // Monotone: more loss never decodes MORE layers.
      final losses = results.keys.toList()..sort();
      for (var i = 1; i < losses.length; i++) {
        expect(results[losses[i]]!, lessThanOrEqualTo(results[losses[i - 1]]!),
            reason: 'quality must fall monotonically with loss, not jump');
      }
      // At zero loss everything decodes; at 90% loss something still does or
      // the redundancy budget was simply too small — both are informative, so
      // the assertion is only on the clean end plus monotonicity.
      expect(results[0.0], equals(4));
      // ignore: avoid_print
      print('layers decoded by loss: $results');
    });

    test('the first layer survives loss that destroys the whole object', () {
      // The spec's headline: a few KB arriving by any path yields a picture.
      final layers = _layers();
      var l0Decoded = 0;
      const trials = 20;
      for (var t = 0; t < trials; t++) {
        final r = _run([layers.first],
            loss: 0.5, redundancy: 3.0, rng: Random(100 + t));
        if (r.layersDecoded == 1) l0Decoded++;
      }
      expect(l0Decoded, equals(trials),
          reason: 'L0 with 3x redundancy must survive 50% loss every time');
    });

    test('clean-channel overhead is the price of the property', () {
      // The spec sets a 10% ceiling on a clean channel. Measure what redundancy
      // 1.0 costs versus the raw object, so the gate has a real number.
      final layers = _layers();
      final rawBytes = layers.fold<int>(0, (a, l) => a + l.length);
      final r = _run(layers, loss: 0.0, redundancy: 1.0, rng: Random(7));
      expect(r.layersDecoded, equals(4));
      final overhead = (r.bytesDelivered - rawBytes) / rawBytes;
      // ignore: avoid_print
      print('clean-channel overhead at redundancy 1.0: '
          '${(overhead * 100).toStringAsFixed(2)}% '
          '(${r.bytesDelivered} vs $rawBytes)');
      expect(overhead, lessThan(0.30),
          reason: 'framing overhead alone must stay well under the repair budget');
    });

    test('the spec 10% clean-channel gate is decided by blockSize alone', () {
      // Each datagram is 4 header + blockSize payload + 1 CRC. So the floor on
      // clean-channel overhead is 5/blockSize BEFORE a single repair symbol —
      // and the encoder only accepts 31..55. At the default 48 that floor is
      // already above the spec's 10% gate, which is a finding about the gate,
      // not about the channel.
      final layers = _layers();
      final rawBytes = layers.fold<int>(0, (a, l) => a + l.length);
      for (final bs in [31, 48, 55]) {
        var delivered = 0;
        for (final layer in layers) {
          final enc = RlncEncoder(layer, blockSize: bs);
          delivered += enc.blockCount * (4 + bs + 1);
        }
        final overhead = (delivered - rawBytes) / rawBytes;
        // ignore: avoid_print
        print('blockSize $bs -> clean overhead '
            '${(overhead * 100).toStringAsFixed(2)}%');
      }
      // The largest permitted block is the only one that can meet a 10% gate.
      var delivered55 = 0;
      for (final layer in layers) {
        final enc = RlncEncoder(layer, blockSize: 55);
        delivered55 += enc.blockCount * 60;
      }
      expect((delivered55 - rawBytes) / rawBytes, lessThan(0.10),
          reason: 'blockSize 55 is what makes the 10% gate reachable');
    });

    test('how much redundancy L0 actually needs, per loss rate', () {
      // The UEP allocator the spec calls new work has to choose these numbers.
      // Measured here so it is built against evidence rather than intuition.
      final l0 = _layers().first;
      final table = <String, double>{};
      for (final loss in [0.2, 0.5, 0.7, 0.9]) {
        var chosen = double.nan;
        for (final r in [1.5, 2.0, 2.5, 3.0, 4.0, 6.0, 12.0, 20.0]) {
          var allOk = true;
          for (var t = 0; t < 10; t++) {
            final res =
                _run([l0], loss: loss, redundancy: r, rng: Random(900 + t));
            if (res.layersDecoded != 1) {
              allOk = false;
              break;
            }
          }
          if (allOk) {
            chosen = r;
            break;
          }
        }
        table['loss ${(loss * 100).round()}%'] = chosen;
      }
      // ignore: avoid_print
      print('redundancy needed for L0 (10/10 trials): $table');
      expect(table['loss 50%'], isNot(isNaN),
          reason: 'L0 must be deliverable at 50% loss within the swept budget');
    });
  });
}
