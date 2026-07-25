/// Document compression for the media transport stage.
///
/// Strategy per the brief: keep only the text layer (layout and embedded
/// resources are discarded by the caller before this point — this class
/// takes the extracted text), and compress with the maximum level
/// available in-process. Today that is `dart:io` gzip at level 9; a
/// Brotli or Zstandard binding would compress further but is an explicit
/// dependency decision, deliberately not made silently here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TextDocumentCompressor {
  const TextDocumentCompressor();

  static final _codec = GZipCodec(level: 9);

  /// UTF-8 encode then gzip at maximum level. Character-exact round-trip
  /// for any Unicode text, including empty input.
  Uint8List compress(String text) =>
      Uint8List.fromList(_codec.encode(utf8.encode(text)));

  String decompress(Uint8List compressed) =>
      utf8.decode(_codec.decode(compressed));
}
