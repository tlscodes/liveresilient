import 'dart:typed_data';

import 'package:broadcast/src/wire.dart';
import 'package:test/test.dart';

void main() {
  group('WireWriter', () {
    test('writes big-endian fields at their declared widths', () {
      final out = WireWriter()
        ..u8(0x01)
        ..u16(0x0203)
        ..u32(0x04050607)
        ..u40(0x08090A0B0C)
        ..bytes(Uint8List.fromList([0xFF, 0xFE]));
      expect(out.take(), [
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0xFF,
        0xFE,
      ]);
    });

    test('reports the running length', () {
      final out = WireWriter()..u32(0);
      expect(out.length, 4);
      out.u40(0);
      expect(out.length, 9);
    });

    test('refuses a value too wide for its field', () {
      expect(() => WireWriter().u8(0x100), throwsArgumentError);
      expect(() => WireWriter().u16(0x10000), throwsArgumentError);
      expect(() => WireWriter().u32(0x100000000), throwsArgumentError);
      expect(() => WireWriter().u40(0x10000000000), throwsArgumentError);
    });

    test('refuses a negative value', () {
      expect(() => WireWriter().u8(-1), throwsArgumentError);
      expect(() => WireWriter().u40(-1), throwsArgumentError);
    });

    test('accepts the maximum of each field', () {
      final out = WireWriter()
        ..u8(0xFF)
        ..u16(0xFFFF)
        ..u32(0xFFFFFFFF)
        ..u40(0xFFFFFFFFFF);
      expect(out.take().every((b) => b == 0xFF), isTrue);
      expect(out.length, 12);
    });
  });

  group('WireReader', () {
    test('round-trips every field width', () {
      final bytes =
          (WireWriter()
                ..u8(0x7F)
                ..u16(0xBEEF)
                ..u32(0xDEADBEEF)
                ..u40(0xFFFFFFFFFF))
              .take();
      final reader = WireReader(bytes);
      expect(reader.u8(), 0x7F);
      expect(reader.u16(), 0xBEEF);
      expect(reader.u32(), 0xDEADBEEF);
      expect(reader.u40(), 0xFFFFFFFFFF);
      expect(reader.remaining, 0);
    });

    test('u40 keeps precision above the 32-bit boundary', () {
      // Naive shifting loses the top byte on the web number
      // representation; this asserts the multiply-based path.
      final bytes = Uint8List.fromList([0xFF, 0x00, 0x00, 0x00, 0x01]);
      expect(WireReader(bytes).u40(), 0xFF00000001);
    });

    test('bytes() returns a copy, not a view', () {
      final source = Uint8List.fromList([1, 2, 3, 4]);
      final taken = WireReader(source).bytes(4);
      source[0] = 99;
      expect(taken[0], 1);
    });

    test('throws FormatException past the end rather than reading zeros', () {
      final reader = WireReader(Uint8List.fromList([1, 2]));
      expect(reader.u8(), 1);
      expect(() => reader.u32(), throwsFormatException);
    });

    test('throws on a truncated fixed field', () {
      expect(
        () => WireReader(Uint8List.fromList([1, 2, 3, 4])).u40(),
        throwsFormatException,
      );
    });

    test('throws on a negative read length', () {
      expect(
        () => WireReader(Uint8List.fromList([1])).bytes(-1),
        throwsFormatException,
      );
    });

    test('remaining tracks consumption', () {
      final reader = WireReader(Uint8List(10));
      expect(reader.remaining, 10);
      reader.bytes(4);
      expect(reader.remaining, 6);
    });
  });
}
