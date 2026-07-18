import 'package:call_core/src/validation.dart';
import 'package:test/test.dart';

void main() {
  group('containsControlCharacters', () {
    test('0x1f (just below the boundary) is a control character', () {
      expect(containsControlCharacters('\x1f'), isTrue);
    });

    test('0x20 (space, the boundary itself) is NOT a control character', () {
      expect(containsControlCharacters('\x20'), isFalse);
      expect(containsControlCharacters(' '), isFalse);
    });

    test('0x7f (DEL) is a control character', () {
      expect(containsControlCharacters('\x7f'), isTrue);
    });

    test('0x7e (just below DEL) is NOT a control character', () {
      expect(containsControlCharacters('\x7e'), isFalse);
    });

    test('tab (\\t, 0x09) is a control character', () {
      expect(containsControlCharacters('\t'), isTrue);
    });

    test('newline (\\n, 0x0a) is a control character', () {
      expect(containsControlCharacters('\n'), isTrue);
    });

    test('carriage return (\\r, 0x0d) is a control character', () {
      expect(containsControlCharacters('\r'), isTrue);
    });

    test('plain Farsi text passes', () {
      expect(containsControlCharacters('سلام دنیا'), isFalse);
    });

    test('plain English text passes', () {
      expect(containsControlCharacters('hello world'), isFalse);
    });

    test('an emoji (surrogate pair) passes', () {
      // U+1F600 GRINNING FACE encodes as the surrogate pair U+D83D U+DE00;
      // both code units are >= 0x20 and != 0x7F, so neither trips the
      // control-character check.
      expect(containsControlCharacters('😀'), isFalse);
      expect(containsControlCharacters('\u{1F600}'), isFalse);
    });

    test('a control character mixed into otherwise-plain text is caught', () {
      expect(containsControlCharacters('hello\x1fworld'), isTrue);
    });

    test('the empty string passes', () {
      expect(containsControlCharacters(''), isFalse);
    });
  });
}
