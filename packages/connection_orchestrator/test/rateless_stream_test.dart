import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(int n, Random rng) =>
    Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

void main() {
  final rng = Random(20260725);

  group('RatelessEncoder/Decoder', () {
    test('round-trip with zero loss is bit-exact for 1B/100B/2KB/64KB', () {
      for (final size in [1, 100, 2048, 65536]) {
        final data = _randomBytes(size, rng);
        final enc = RatelessEncoder(data);
        final dec = RatelessDecoder();
        var fed = 0;
        while (!dec.isComplete) {
          dec.addDatagram(enc.nextDatagram());
          fed++;
          expect(
            fed,
            lessThan(enc.blockCount * 3 + 30),
            reason: 'decode did not converge for $size B',
          );
        }
        expect(dec.data, equals(data), reason: 'size $size');
      }
    });

    test('decodes from a random subset in random order, bit-exact', () {
      final data = _randomBytes(4096, rng);
      final enc = RatelessEncoder(data);
      final n = enc.blockCount;
      // Generate 3N datagrams, drop half at random, shuffle the rest.
      final pool = List.generate(3 * n, (i) => enc.datagramAt(i))
        ..removeWhere((_) => rng.nextBool())
        ..shuffle(rng);
      final dec = RatelessDecoder();
      for (final d in pool) {
        dec.addDatagram(d);
        if (dec.isComplete) break;
      }
      expect(dec.isComplete, isTrue);
      expect(dec.data, equals(data));
    });

    test('any single bit flip is rejected, never decoded', () {
      final data = _randomBytes(512, rng);
      final enc = RatelessEncoder(data);
      final clean = enc.datagramAt(0);
      for (var bit = 0; bit < clean.length * 8; bit++) {
        final corrupt = Uint8List.fromList(clean);
        corrupt[bit ~/ 8] ^= 1 << (bit % 8);
        final dec = RatelessDecoder();
        expect(dec.addDatagram(corrupt), isFalse, reason: 'bit $bit accepted');
        expect(dec.decodedBlockCount, 0);
      }
    });

    test('overhead epsilon < 1.6 (measured)', () {
      // Random-subset reception (systematic prefix partially lost), the
      // realistic regime. Average over trials.
      final data = _randomBytes(8192, rng);
      final enc = RatelessEncoder(data);
      final n = enc.blockCount;
      var totalUsed = 0;
      const trials = 10;
      for (var t = 0; t < trials; t++) {
        final dec = RatelessDecoder();
        var esi = 0;
        var used = 0;
        while (!dec.isComplete) {
          // 50% loss pattern: skip datagrams at random.
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
        'rateless overhead epsilon (measured): '
        '${epsilon.toStringAsFixed(3)} over $trials trials, N=$n',
      );
      expect(epsilon, lessThan(1.6));
    });

    test('decoder memory stays bounded under 20x overfeed', () {
      final data = _randomBytes(4096, rng);
      final enc = RatelessEncoder(data);
      final n = enc.blockCount;
      final dec = RatelessDecoder();
      // Feed only parity (worst case for buffering) then everything, 20x.
      for (var esi = n; esi < n + 20 * n && esi <= 0xFFFF; esi++) {
        dec.addDatagram(enc.datagramAt(esi));
        expect(dec.pendingSymbolCount, lessThanOrEqualTo(n));
      }
      for (var esi = 0; esi < n; esi++) {
        dec.addDatagram(enc.datagramAt(esi));
        expect(dec.pendingSymbolCount, lessThanOrEqualTo(n));
      }
      expect(dec.isComplete, isTrue);
      expect(dec.data, equals(data));
    });

    test('datagram size stays within 36-60 bytes', () {
      final enc = RatelessEncoder(_randomBytes(1000, rng));
      final d = enc.nextDatagram();
      expect(d.length, inInclusiveRange(36, 60));
    });
  });
}
