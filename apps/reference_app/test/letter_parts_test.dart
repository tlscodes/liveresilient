// The parts of a letter, without a network: ten parts back to the original
// bytes, one missing part is "incomplete" and never a crash, and the Dart
// splitter produces exactly the bytes the Python mirror pinned in the
// golden (tools/t2/goldens/letter_parts_10.bin, 2-byte length prefix per
// part).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_parts.dart';

Uint8List goldenPayload() =>
    Uint8List.fromList([for (var i = 0; i < 40000; i++) i & 0xFF]);

List<Uint8List> readGolden() {
  final bytes = File(
    '../../tools/t2/goldens/letter_parts_10.bin',
  ).readAsBytesSync();
  final parts = <Uint8List>[];
  var at = 0;
  while (at < bytes.length) {
    final len = (bytes[at] << 8) | bytes[at + 1];
    parts.add(Uint8List.sublistView(bytes, at + 2, at + 2 + len));
    at += 2 + len;
  }
  return parts;
}

void main() {
  test('a payload under the cap goes bare, untouched', () {
    final small = Uint8List.fromList(List<int>.filled(4096, 7));
    final parts = splitLetter(small);
    expect(parts, hasLength(1));
    expect(identical(parts.single, small), isTrue);
    expect(parseLetterPart(small), isNull);
  });

  test('ten parts, each under the cap, back to the original bytes', () {
    final payload = goldenPayload();
    final parts = splitLetter(payload, id: 0x0BADCAFE);
    expect(parts, hasLength(10));
    for (final p in parts) {
      expect(p.length, lessThanOrEqualTo(4096));
    }
    final asm = LetterAssembler(0x0BADCAFE);
    // Any order: shuffled deterministically.
    final order = List<int>.generate(10, (i) => i)..shuffle(Random(7));
    for (final i in order) {
      expect(asm.add(parseLetterPart(parts[i])!), isTrue);
    }
    expect(asm.isComplete, isTrue);
    expect(asm.missing, isEmpty);
    expect(asm.assemble(), payload);
  });

  test('one part missing: incomplete, missing names it, assemble is null', () {
    final parts = splitLetter(goldenPayload(), id: 1);
    final asm = LetterAssembler(1);
    for (var i = 0; i < parts.length; i++) {
      if (i == 6) continue;
      asm.add(parseLetterPart(parts[i])!);
    }
    expect(asm.isComplete, isFalse);
    expect(asm.received, 9);
    expect(asm.total, 10);
    expect(asm.missing, [6]);
    expect(asm.assemble(), isNull);
    // The late part completes it.
    expect(asm.add(parseLetterPart(parts[6])!), isTrue);
    expect(asm.assemble(), goldenPayload());
  });

  test(
    'a duplicate, a foreign part, and a contradicting total are refused',
    () {
      final parts = splitLetter(goldenPayload(), id: 2);
      final other = splitLetter(goldenPayload(), id: 3);
      final asm = LetterAssembler(2);
      expect(asm.add(parseLetterPart(parts[0])!), isTrue);
      expect(asm.add(parseLetterPart(parts[0])!), isFalse);
      expect(asm.add(parseLetterPart(other[1])!), isFalse);
      final lying = Uint8List.fromList(parts[1])..[9] = 4;
      expect(asm.add(parseLetterPart(lying)!), isFalse);
      expect(asm.received, 1);
    },
  );

  test('a corrupted slice is a digest mismatch, not a picture', () {
    final parts = splitLetter(goldenPayload(), id: 4);
    final asm = LetterAssembler(4);
    for (var i = 0; i < parts.length; i++) {
      final p = Uint8List.fromList(parts[i]);
      if (i == 3) p[100] ^= 0xFF;
      asm.add(parseLetterPart(p)!);
    }
    expect(asm.isComplete, isTrue);
    expect(asm.assemble, throwsA(isA<LetterDigestMismatch>()));
  });

  test('more than the ceiling is refused before anything is sent', () {
    final tooBig = Uint8List(letterMaxTotalBytes() + 1);
    expect(() => splitLetter(tooBig), throwsA(isA<LetterTooLong>()));
    final justFits = Uint8List(letterMaxTotalBytes());
    expect(splitLetter(justFits, id: 5), hasLength(letterMaxParts));
    expect(letterMaxParts, 60);
  });

  test(
    'the header is not mistaken for a part in a picture or a voice note',
    () {
      final jpeg = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        ...List.filled(64, 0),
      ]);
      final voice = Uint8List.fromList([
        0x11,
        0xD4,
        0x02,
        0x00,
        ...List.filled(64, 0),
      ]);
      expect(parseLetterPart(jpeg), isNull);
      expect(parseLetterPart(voice), isNull);
      expect(parseLetterPart(Uint8List(5)), isNull);
    },
  );

  test('the Dart splitter matches the Python golden byte for byte', () {
    final golden = readGolden();
    final ours = splitLetter(goldenPayload(), id: 0x0BADCAFE);
    expect(golden, hasLength(10));
    expect(ours, hasLength(10));
    for (var i = 0; i < 10; i++) {
      expect(ours[i], golden[i], reason: 'part $i');
    }
    final asm = LetterAssembler(0x0BADCAFE);
    for (final g in golden) {
      asm.add(parseLetterPart(g)!);
    }
    expect(asm.assemble(), goldenPayload());
    expect(idHex(0x0BADCAFE), '0badcafe');
  });
}
