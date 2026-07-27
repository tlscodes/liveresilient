import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  group('MessageCoalescer', () {
    test('many small messages round-trip through one frame', () {
      final messages = [
        [1, 2, 3],
        List.generate(200, (i) => i % 256),
        <int>[],
        [255],
      ];
      expect(
        MessageCoalescer.unpack(MessageCoalescer.pack(messages)),
        messages,
      );
    });

    test('frame overhead is small for tiny messages', () {
      final messages = [
        for (var i = 0; i < 50; i++) [i, i, i],
      ];
      final frame = MessageCoalescer.pack(messages);
      final rawBytes = 50 * 3;
      expect(frame.length, lessThan(rawBytes + 60), reason: '~1B/message');
    });

    test('truncated frame is rejected, not mis-parsed', () {
      final frame = MessageCoalescer.pack([
        [1, 2, 3, 4, 5],
      ]);
      expect(
        MessageCoalescer.unpack(frame.sublist(0, frame.length - 2)),
        isNull,
      );
    });
  });

  group('WeakLinkCompressor', () {
    test('compressible text shrinks and round-trips', () {
      final payload = List.filled(4000, 65); // very compressible
      final encoded = WeakLinkCompressor.encode(payload);
      expect(encoded.length, lessThan(payload.length ~/ 4));
      expect(WeakLinkCompressor.decode(encoded), payload);
    });

    test('incompressible data ships raw with 1 byte overhead', () {
      var x = 88172645463325252; // xorshift64 — bytes zlib cannot shrink
      final payload = List.generate(500, (_) {
        x ^= x << 13;
        x ^= x >>> 7;
        x ^= x << 17;
        return x & 0xff;
      });
      final encoded = WeakLinkCompressor.encode(payload);
      expect(encoded.length, payload.length + 1);
      expect(encoded.first, 0, reason: 'raw flag chosen');
      expect(WeakLinkCompressor.decode(encoded), payload);
    });

    test('corrupt frames return null instead of throwing', () {
      expect(WeakLinkCompressor.decode([]), isNull);
      expect(WeakLinkCompressor.decode([9, 1, 2]), isNull);
      expect(WeakLinkCompressor.decode([1, 0, 0, 0]), isNull);
    });
  });

  group('ParityGroup', () {
    test('any single lost chunk is rebuilt without retransmission', () {
      const parityGroup = ParityGroup();
      final chunks = [
        List.generate(100, (i) => i),
        List.generate(100, (i) => 255 - i),
        List.generate(100, (i) => (i * 3) % 256),
        List.generate(40, (i) => i + 7), // short tail chunk
      ];
      final parity = parityGroup.parityOf(chunks);

      for (var lost = 0; lost < chunks.length; lost++) {
        final present = [
          for (var i = 0; i < chunks.length; i++)
            if (i != lost) chunks[i],
        ];
        final recovered = parityGroup.recover(
          present,
          parity,
          lostLength: chunks[lost].length,
        );
        expect(recovered, chunks[lost], reason: 'chunk $lost rebuilt');
      }
    });

    test('overhead is exactly one chunk per group', () {
      const parityGroup = ParityGroup();
      final chunks = [for (var i = 0; i < 4; i++) List.filled(1000, i)];
      expect(parityGroup.parityOf(chunks).length, 1000);
    });
  });

  group('full weak-link pipeline', () {
    test('coalesce → compress → chunk+parity survives one chunk loss', () {
      final messages = [
        for (var i = 0; i < 30; i++)
          List.filled(80, i), // chatty small messages
      ];
      final frame = WeakLinkCompressor.encode(MessageCoalescer.pack(messages));

      // Chunk the frame into 4 pieces + parity, lose piece 2 in transit.
      final size = (frame.length + 3) ~/ 4;
      final chunks = [
        for (var i = 0; i < 4; i++)
          frame.sublist(
            i * size,
            (i + 1) * size > frame.length ? frame.length : (i + 1) * size,
          ),
      ];
      const parityGroup = ParityGroup();
      final parity = parityGroup.parityOf(chunks);
      final present = [chunks[0], chunks[1], chunks[3]];
      final rebuilt = parityGroup.recover(
        present,
        parity,
        lostLength: chunks[2].length,
      );

      final reassembled = [
        ...chunks[0],
        ...chunks[1],
        ...rebuilt,
        ...chunks[3],
      ];
      final decoded = MessageCoalescer.unpack(
        WeakLinkCompressor.decode(reassembled)!,
      );
      expect(decoded, messages);
    });
  });
}
