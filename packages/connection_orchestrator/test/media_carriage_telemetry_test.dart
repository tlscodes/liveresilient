import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_carriage.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

void main() {
  group('MediaCarriage full-MTU carriage (truncation regression)', () {
    test('blockSize 1400 datagrams roundtrip on both carriers', () {
      for (final carrier in MediaCarrier.values) {
        final carriage = MediaCarriage(
          carrier: carrier,
          mtuBlockSize: 1400,
          random: Random(9),
        );
        for (var t = 0; t < 20; t++) {
          final bytes = Uint8List.fromList(
            List.generate(60 + t, (i) => (i * 31 + t) & 0xFF),
          );
          final out = carriage.unwrap(carriage.wrap(TaggedDatagram(t, bytes)));
          expect(out.transferId, t);
          expect(out.bytes, equals(bytes));
        }
        expect(carriage.frameDecodeFailures, 0);
        expect(carriage.unpadFailures, 0);
      }
    });

    test('carrier framing failure and unpad failure count separately', () {
      final carriage = MediaCarriage(mtuBlockSize: 64, random: Random(2));
      // Garbage wire bytes: carrier-level decode failure.
      expect(() => carriage.unwrap(Uint8List(3)), throwsFormatException);
      expect(carriage.frameDecodeFailures, 1);
      expect(carriage.unpadFailures, 0);
      // Valid HTTP/2 frame, corrupted padding trailer: unpad failure.
      final wire = carriage.wrap(TaggedDatagram(1, Uint8List(40)));
      wire[wire.length - 2] = 0xFF;
      wire[wire.length - 1] = 0xFF;
      expect(() => carriage.unwrap(wire), throwsFormatException);
      expect(carriage.frameDecodeFailures, 1);
      expect(carriage.unpadFailures, 1);
    });
  });

  group('RatelessDecoder rejection telemetry', () {
    test('CRC and structural rejects are counted, not silent', () {
      final enc = RatelessEncoder(
        Uint8List.fromList(List.generate(200, (i) => i & 0xFF)),
      );
      final dec = RatelessDecoder();
      // Corrupt one datagram's payload: CRC reject.
      final bad = enc.datagramAt(0);
      bad[6] ^= 0xFF;
      expect(dec.addDatagram(bad), isFalse);
      expect(dec.crcRejectCount, 1);
      // Too-short datagram: structural reject.
      expect(dec.addDatagram(Uint8List(3)), isFalse);
      expect(dec.structuralRejectCount, 1);
      // Clean feed still decodes.
      var esi = 0;
      while (!dec.isComplete) {
        dec.addDatagram(enc.datagramAt(esi++));
      }
      expect(dec.data.length, 200);
      expect(dec.crcRejectCount, 1);
      expect(dec.structuralRejectCount, 1);
    });
  });
}
