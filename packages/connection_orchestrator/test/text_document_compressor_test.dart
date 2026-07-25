/// Phase 4a — document compression (text layer, gzip level 9).
import 'dart:math';

import 'package:connection_orchestrator/src/media_codecs/text_document_compressor.dart';
import 'package:test/test.dart';

void main() {
  const c = TextDocumentCompressor();

  test('round-trip is character-exact for ASCII, Persian, and mixed', () {
    const samples = [
      'The quick brown fox jumps over the lazy dog. 0123456789!@#\$%',
      'سلام دنیا؛ این یک سند فارسی است. صدا در سکوت منتقل می‌شود؟',
      'Mixed متن فارسی with English وسطِ خط، paths /usr/bin و اعداد ۱۲۳.',
    ];
    for (final s in samples) {
      expect(c.decompress(c.compress(s)), equals(s));
    }
  });

  test('empty and 1-character inputs are handled', () {
    for (final s in ['', 'a', 'ک']) {
      expect(c.decompress(c.compress(s)), equals(s));
    }
  });

  test('compressed size on a representative 10KB text: measured and pinned',
      () {
    // Representative document text: repeated natural-language sentences
    // with mild variation (deterministic).
    final rng = Random(42);
    final words = [
      'transfer', 'voice', 'channel', 'document', 'budget', 'silence',
      'datagram', 'parity', 'receiver', 'network', 'قرارداد', 'سند',
      'صوت', 'انتقال', 'شبکه'
    ];
    final sb = StringBuffer();
    while (sb.length < 10240) {
      sb.write(words[rng.nextInt(words.length)]);
      sb.write(rng.nextInt(12) == 0 ? '.\n' : ' ');
    }
    final text = sb.toString().substring(0, 10240);
    final compressed = c.compress(text);
    final ratio = compressed.length / 10240;
    // ignore: avoid_print
    print('document compressor: 10KB -> ${compressed.length} B '
        '(ratio ${ratio.toStringAsFixed(3)}, gzip level 9)');
    // Pinned from first measured run (1822 B); ~15% headroom so a zlib
    // version change cannot flake the gate.
    expect(compressed.length, lessThan(2100));
    expect(c.decompress(compressed), equals(text));
  });
}
