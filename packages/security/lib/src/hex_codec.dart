/// Shared lower-case hex encode/decode for raw key/fingerprint bytes.
///
/// Internal helper only — not exported from `security.dart`. Both
/// `identity_store.dart` and `key_store.dart` persist/compare byte
/// material as hex strings and previously carried identical private
/// copies of this logic; this file is the single source so the two
/// copies can't drift.
library;

import 'dart:typed_data';

/// Encodes [bytes] as lower-case hex, two characters per byte.
String hexEncode(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Decodes a lower-case (or upper-case) hex string back to bytes.
///
/// Throws [FormatException] if [hex] has an odd length.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('Hex string has odd length: ${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
