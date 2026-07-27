import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

Uint8List _data(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + 7) & 0xFF));

void main() {
  group('build', () {
    test('indexes a 2 MB layer in 64 KB chunks', () {
      final list = LayerHashList.build(_data(2 * 1024 * 1024));
      expect(list.chunkCount, 32);
      expect(list.chunkSize, 64 * 1024);
      expect(list.totalLength, 2 * 1024 * 1024);
    });

    test('the flat list costs about a kilobyte for that layer', () {
      // The claim the design rests on: proving a 2 MB layer costs one
      // signature over roughly 1 KB, not a per-chunk Merkle path.
      final list = LayerHashList.build(_data(2 * 1024 * 1024));
      expect(list.encoded.length, 1 + 4 + 4 + 4 + 32 * 32);
      expect(list.encoded.length, lessThan(1100));
      final overhead = list.encoded.length / list.totalLength;
      expect(overhead, lessThan(0.001));
    });

    test('a short final chunk is sized correctly', () {
      final list = LayerHashList.build(
        _data(64 * 1024 + 100),
        chunkSize: 64 * 1024,
      );
      expect(list.chunkCount, 2);
      expect(list.chunkLengthAt(0), 64 * 1024);
      expect(list.chunkLengthAt(1), 100);
    });

    test('an exactly-divisible layer has no short chunk', () {
      final list = LayerHashList.build(
        _data(3 * minChunkSize),
        chunkSize: minChunkSize,
      );
      expect(list.chunkCount, 3);
      expect(list.chunkLengthAt(2), minChunkSize);
    });

    test('one chunk is the smallest valid list', () {
      final list = LayerHashList.build(_data(10), chunkSize: minChunkSize);
      expect(list.chunkCount, 1);
      expect(list.chunkLengthAt(0), 10);
    });

    test('refuses a chunk size outside the documented range', () {
      expect(
        () => LayerHashList.build(_data(100), chunkSize: minChunkSize - 1),
        throwsArgumentError,
      );
      expect(
        () => LayerHashList.build(_data(100), chunkSize: maxChunkSize + 1),
        throwsArgumentError,
      );
    });

    test('refuses empty data', () {
      expect(() => LayerHashList.build(Uint8List(0)), throwsArgumentError);
    });

    test('chunkLengthAt refuses an out-of-range index', () {
      final list = LayerHashList.build(_data(100), chunkSize: minChunkSize);
      expect(() => list.chunkLengthAt(1), throwsRangeError);
      expect(() => list.chunkLengthAt(-1), throwsRangeError);
    });
  });

  group('verifyChunk', () {
    late Uint8List data;
    late LayerHashList list;

    setUp(() {
      data = _data(64 * 1024 + 512);
      list = LayerHashList.build(data, chunkSize: 64 * 1024);
    });

    test('accepts every genuine chunk', () {
      for (var i = 0; i < list.chunkCount; i++) {
        expect(list.verifyChunk(i, list.chunkOf(data, i)), isTrue);
      }
    });

    test('rejects a chunk offered at the wrong index', () {
      expect(list.verifyChunk(1, list.chunkOf(data, 0)), isFalse);
    });

    test('rejects a chunk with one flipped byte', () {
      final chunk = list.chunkOf(data, 0);
      chunk[500] ^= 0x01;
      expect(list.verifyChunk(0, chunk), isFalse);
    });

    test('rejects a truncated or padded chunk', () {
      final genuine = list.chunkOf(data, 0);
      expect(
        list.verifyChunk(0, Uint8List.sublistView(genuine, 0, 100)),
        isFalse,
      );
      expect(list.verifyChunk(0, Uint8List.fromList([...genuine, 0])), isFalse);
    });

    test('rejects an out-of-range index instead of throwing', () {
      expect(list.verifyChunk(-1, list.chunkOf(data, 0)), isFalse);
      expect(list.verifyChunk(99, list.chunkOf(data, 0)), isFalse);
    });

    test('chunkOf refuses data of the wrong total length', () {
      expect(() => list.chunkOf(_data(10), 0), throwsArgumentError);
    });
  });

  group('parse', () {
    test('round-trips through the wire form', () {
      final data = _data(200 * 1024);
      final built = LayerHashList.build(data);
      final parsed = LayerHashList.parse(built.encoded);
      expect(parsed, isNotNull);
      expect(parsed!.chunkCount, built.chunkCount);
      expect(parsed.chunkSize, built.chunkSize);
      expect(parsed.totalLength, built.totalLength);
      expect(bytesEqual(parsed.hash, built.hash), isTrue);
      for (var i = 0; i < parsed.chunkCount; i++) {
        expect(parsed.verifyChunk(i, built.chunkOf(data, i)), isTrue);
      }
    });

    test('the list hash is the content hash of its own bytes', () {
      final built = LayerHashList.build(_data(50_000));
      expect(built.hash, contentHash(built.encoded));
    });

    test(
      'rejects a declared count that the declared length cannot produce',
      () {
        final built = LayerHashList.build(_data(200 * 1024));
        final bad = Uint8List.fromList(built.encoded);
        // Halve totalLength while leaving count alone.
        bad[5] = 0;
        bad[6] = 0x01;
        bad[7] = 0;
        bad[8] = 0;
        final reasons = <HashListRejection>[];
        expect(LayerHashList.parse(bad, onReject: reasons.add), isNull);
        expect(reasons, [HashListRejection.lengthMismatch]);
      },
    );

    test('rejects a hash array that does not match the declared count', () {
      final built = LayerHashList.build(_data(200 * 1024));
      final truncated = Uint8List.sublistView(
        built.encoded,
        0,
        built.encoded.length - 1,
      );
      final reasons = <HashListRejection>[];
      expect(
        LayerHashList.parse(
          Uint8List.fromList(truncated),
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [HashListRejection.malformed]);
    });

    test('rejects trailing bytes after the hash array', () {
      final built = LayerHashList.build(_data(200 * 1024));
      final padded = Uint8List.fromList([...built.encoded, 0]);
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(padded, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.malformed]);
    });

    test('rejects an unsupported version', () {
      final built = LayerHashList.build(_data(20_000));
      final bad = Uint8List.fromList(built.encoded)..[0] = 9;
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.unsupportedVersion]);
    });

    test('rejects a chunk size outside the range', () {
      final built = LayerHashList.build(_data(20_000));
      final bad = Uint8List.fromList(built.encoded);
      bad[1] = 0;
      bad[2] = 0;
      bad[3] = 0;
      bad[4] = 1;
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.chunkSizeOutOfRange]);
    });

    test('rejects a zero-length or zero-count list', () {
      final built = LayerHashList.build(_data(20_000));
      final zeroLength = Uint8List.fromList(built.encoded);
      for (var i = 5; i < 9; i++) {
        zeroLength[i] = 0;
      }
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(zeroLength, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.emptyList]);
    });

    test('rejects a header that ends mid-field', () {
      final truncated = Uint8List(3)..[0] = hashListVersion;
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(truncated, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.malformed]);
    });

    test('an empty buffer is refused on the version byte', () {
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(Uint8List(0), onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.malformed]);
    });

    test('rejects a count above the ceiling before allocating for it', () {
      // Declared count 2^17 with the smallest legal chunk size: the
      // length check would otherwise agree, so the ceiling has to be
      // what refuses it.
      final bad = Uint8List(13);
      bad[0] = hashListVersion;
      bad.buffer.asByteData().setUint32(1, minChunkSize);
      bad.buffer.asByteData().setUint32(5, minChunkSize * (1 << 17));
      bad.buffer.asByteData().setUint32(9, 1 << 17);
      final reasons = <HashListRejection>[];
      expect(LayerHashList.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [HashListRejection.tooManyChunks]);
    });
  });
}
