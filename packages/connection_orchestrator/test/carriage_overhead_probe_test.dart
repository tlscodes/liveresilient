/// What a cliff-free datagram actually costs on each carrier, measured.
///
/// Written to answer one question with numbers instead of intuition: if the
/// transfer id has to grow from two bytes to four, what does that cost per
/// datagram? "About 3%" is a guess; the padding block size may absorb it
/// entirely, or may not. The wire is quantized, so the answer is not obtained
/// by dividing.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

Uint8List _rlncDatagram() {
  final encoder = RlncEncoder(
    Uint8List.fromList(List.generate(600, (i) => i & 0xFF)),
    blockSize: LayeredRedundancyAllocator.mandatedBlockSize,
  );
  return encoder.datagramAt(0);
}

void main() {
  test('the RLNC datagram is 60 bytes at the mandated block size', () {
    expect(LayeredRedundancyAllocator.mandatedBlockSize, 55);
    expect(_rlncDatagram().length, 60);
    expect(LayeredRedundancyAllocator().datagramBytes, 60);
  });

  test('measured wire cost per carrier, and what padding already absorbs', () {
    final datagram = _rlncDatagram();
    final sizes = <String, int>{};

    for (final carrier in MediaCarrier.values) {
      final carriage = MediaCarriage(carrier: carrier);
      // objectId 0 is the only cliff-free address the carrier accepts today,
      // which is itself the finding in cliff_free_carriage_seam_test.dart.
      final wire = carriage.wrap(TaggedDatagram(0, datagram));
      sizes[carrier.name] = wire.length;
      // ignore: avoid_print
      print(
        'carriage ${carrier.name}: 60 B datagram -> ${wire.length} B on the '
        'wire (+${wire.length - 60} B, '
        '${(100 * (wire.length - 60) / 60).toStringAsFixed(1)}%)',
      );
    }

    // Padding is to a multiple of mtuBlockSize (default 64), so a 60-byte
    // datagram already carries slack. That slack is the budget available for a
    // WIDER TRANSFER ID before any datagram crosses a block boundary — and it
    // is the number that decides whether widening the id is free or not.
    //
    // Measured by differencing two carriages rather than by arithmetic: the
    // quantization is the whole question, so it must be observed.
    final unpadded =
        MediaCarriage(carrier: MediaCarrier.sctpDataChannel, mtuBlockSize: 1)
            .wrap(TaggedDatagram(0, datagram))
            .length;
    final padded64 = sizes[MediaCarrier.sctpDataChannel.name]!;
    // ignore: avoid_print
    print(
      'padding slack at mtuBlockSize 64: ${padded64 - unpadded} B '
      '(sctp wire ${unpadded} B unpadded vs ${padded64} B padded)',
    );

    // Round trip must survive, or none of the above is a cost worth quoting.
    for (final carrier in MediaCarrier.values) {
      final carriage = MediaCarriage(carrier: carrier);
      final wire = carriage.wrap(TaggedDatagram(0, datagram));
      final back = carriage.unwrap(wire);
      expect(back.transferId, 0);
      expect(back.bytes, datagram, reason: '${carrier.name} round trip');
    }

    expect(sizes.length, MediaCarrier.values.length);
  });

  test('the wire cost is a DISTRIBUTION, and the design quotes the floor', () {
    // The single sample above is not a cost. `MicroDatagramLane` pads for
    // traffic-analysis resistance, so the expansion varies per datagram, and a
    // budget built on one observation is built on a coin flip.
    //
    // This matters far past tidiness. Every byte threshold in the cliff-free
    // documents — the 9.09% framing floor at blockSize 55, the epsilon of the
    // rateless code, the 1.2/(1-p) redundancy law, the N_bytes rung ladder —
    // is computed on the 60-byte RLNC DATAGRAM. What the link actually carries
    // is the wrapped frame. If the wrapper is not ~1.0x, every one of those
    // numbers is optimistic by the wrapper's factor, and a rung that "fits
    // under the link" on paper does not fit in the air.
    const samples = 200;
    for (final carrier in MediaCarrier.values) {
      final carriage = MediaCarriage(carrier: carrier);
      final encoder = RlncEncoder(
        Uint8List.fromList(List.generate(4000, (i) => (i * 31) & 0xFF)),
        blockSize: LayeredRedundancyAllocator.mandatedBlockSize,
      );

      var min = 1 << 30;
      var max = 0;
      var total = 0;
      for (var i = 0; i < samples; i++) {
        final n = carriage.wrap(TaggedDatagram(0, encoder.datagramAt(i))).length;
        if (n < min) min = n;
        if (n > max) max = n;
        total += n;
      }
      final mean = total / samples;
      // ignore: avoid_print
      print(
        '${carrier.name}: $samples datagrams of 60 B -> '
        'min $min · mean ${mean.toStringAsFixed(1)} · max $max B '
        '(expansion x${(mean / 60).toStringAsFixed(2)})',
      );

      // The assertion is deliberately weak, because the point of the test is
      // the printed number, not a bar to clear. What must hold is only that
      // the wrapper never SHRINKS a datagram — anything else would mean the
      // measurement is reading the wrong thing.
      expect(min, greaterThanOrEqualTo(60), reason: carrier.name);
    }
  });
}
