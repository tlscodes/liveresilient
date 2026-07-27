import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

void main() {
  group('contentHash', () {
    test('is SHA-256 and 32 bytes wide', () {
      // The empty-input SHA-256 digest, a fixed published value: this
      // pins the algorithm, not just self-consistency.
      expect(
        hexEncode(contentHash(Uint8List(0))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(contentHash(Uint8List.fromList([1, 2, 3])).length, hashBytes);
    });

    test('differs for inputs differing in one bit', () {
      final a = contentHash(Uint8List.fromList([0x00]));
      final b = contentHash(Uint8List.fromList([0x01]));
      expect(bytesEqual(a, b), isFalse);
    });
  });

  group('authorIdFor', () {
    test('is the first eight bytes of the key hash', () {
      final key = Uint8List.fromList(List.filled(32, 7));
      final id = authorIdFor(key);
      expect(id.length, authorIdBytes);
      expect(id, contentHash(key).sublist(0, authorIdBytes));
    });

    test('is stable across calls', () {
      final key = Uint8List.fromList(List.filled(32, 3));
      expect(bytesEqual(authorIdFor(key), authorIdFor(key)), isTrue);
    });

    test('refuses a key that is not 32 bytes', () {
      expect(() => authorIdFor(Uint8List(31)), throwsArgumentError);
      expect(() => authorIdFor(Uint8List(33)), throwsArgumentError);
    });
  });

  group('bytesEqual', () {
    test('compares content, not identity', () {
      expect(
        bytesEqual(
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([1, 2, 3]),
        ),
        isTrue,
      );
    });

    test('is false for different lengths and for one differing byte', () {
      expect(bytesEqual(Uint8List(3), Uint8List(4)), isFalse);
      expect(
        bytesEqual(
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([1, 2, 4]),
        ),
        isFalse,
      );
    });

    test('two empty lists are equal', () {
      expect(bytesEqual(Uint8List(0), Uint8List(0)), isTrue);
    });
  });

  group('hex', () {
    test('round-trips arbitrary bytes', () {
      final bytes = Uint8List.fromList([0x00, 0x0F, 0xA5, 0xFF]);
      expect(hexEncode(bytes), '000fa5ff');
      expect(hexDecode(hexEncode(bytes)), bytes);
    });

    test('accepts uppercase input', () {
      expect(hexDecode('ABCDEF'), [0xAB, 0xCD, 0xEF]);
    });

    test('rejects an odd length', () {
      expect(() => hexDecode('abc'), throwsFormatException);
    });

    test('rejects a non-hex character instead of coercing it', () {
      expect(() => hexDecode('zz'), throwsFormatException);
      expect(() => hexDecode('0g'), throwsFormatException);
    });

    test('empty string decodes to empty bytes', () {
      expect(hexDecode(''), isEmpty);
    });
  });

  test('zeroHash is 32 zero bytes', () {
    expect(zeroHash.length, hashBytes);
    expect(zeroHash.every((b) => b == 0), isTrue);
  });
}
