@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/cliff_free_reassembler.dart';
import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:test/test.dart';

List<Uint8List> _layers() => [
  Uint8List.fromList(List.generate(1024, (i) => (i * 7) & 0xFF)),
  Uint8List.fromList(List.generate(2048, (i) => (i * 11) & 0xFF)),
  Uint8List.fromList(List.generate(4096, (i) => (i * 13) & 0xFF)),
];

void main() {
  group('CliffFreeReassembler', () {
    test('absorbs datagrams in any order across layers, byte-exact', () {
      final layers = _layers();
      final encs = [for (final l in layers) RlncEncoder(l, blockSize: 55)];
      // Build all datagrams (1.0x, clean channel), tag with layer, shuffle
      // globally — the hostile ordering.
      final tagged = <(int, Uint8List)>[];
      for (var li = 0; li < encs.length; li++) {
        for (var i = 0; i < encs[li].blockCount; i++) {
          tagged.add((li, encs[li].datagramAt(i)));
        }
      }
      tagged.shuffle(Random(3));
      final r = CliffFreeReassembler(layerCount: 3);
      for (final (li, d) in tagged) {
        r.addDatagram(li, d);
      }
      expect(r.isComplete, isTrue);
      for (var li = 0; li < 3; li++) {
        expect(r.layerData(li), equals(layers[li]));
      }
    });

    test('a later layer never needs an earlier one to decode', () {
      final layers = _layers();
      final enc2 = RlncEncoder(layers[2], blockSize: 55);
      final r = CliffFreeReassembler(layerCount: 3);
      for (var i = 0; i < enc2.blockCount; i++) {
        r.addDatagram(2, enc2.datagramAt(i));
      }
      expect(r.isLayerDecoded(2), isTrue,
          reason: 'L2 decodes with zero bytes of L0/L1 seen');
      expect(r.decodedLayerCount, 1);
      expect(r.usableLayerCount, 0,
          reason: 'renderable prefix is still empty — decode progress and '
              'renderable quality are separate numbers');
      // L0 arrives last; the prefix unlocks without touching L2 again.
      final enc0 = RlncEncoder(layers[0], blockSize: 55);
      for (var i = 0; i < enc0.blockCount; i++) {
        r.addDatagram(0, enc0.datagramAt(i));
      }
      expect(r.usableLayerCount, 1);
      expect(r.usableBytes(), equals(layers[0]));
    });

    test('duplicates and post-completion datagrams are free no-ops', () {
      final l0 = _layers().first;
      final enc = RlncEncoder(l0, blockSize: 55);
      final r = CliffFreeReassembler(layerCount: 1);
      for (var i = 0; i < enc.blockCount; i++) {
        r.addDatagram(0, enc.datagramAt(i));
      }
      expect(r.isComplete, isTrue);
      expect(r.addDatagram(0, enc.datagramAt(0)), isFalse);
      expect(r.layerData(0), equals(l0));
    });

    test('guards its arguments', () {
      expect(() => CliffFreeReassembler(layerCount: 0), throwsArgumentError);
      final r = CliffFreeReassembler(layerCount: 2);
      expect(() => r.addDatagram(2, Uint8List(60)), throwsRangeError);
      expect(() => r.layerData(1), throwsStateError);
    });
  });
}
