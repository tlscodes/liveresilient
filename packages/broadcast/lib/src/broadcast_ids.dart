/// Content addressing primitives for the broadcast layer.
///
/// Every object in this package is named by the SHA-256 of its own bytes,
/// so a reader can name what it wants before it trusts where it came
/// from, and a relay can decide two copies are the same without parsing
/// either one.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Length of every content hash on the wire.
const int hashBytes = 32;

/// Length of the truncated author identifier carried in a descriptor.
///
/// Eight bytes is a deliberate trade: it keeps the descriptor small, and
/// it is never the only thing checked. A reader always verifies the
/// full 32-byte root key against this identifier before accepting a
/// post, so a collision here buys an attacker nothing.
const int authorIdBytes = 8;

/// The all-zero hash, used as the `prev` link of a genesis descriptor.
final Uint8List zeroHash = Uint8List(hashBytes);

/// SHA-256 over [input].
Uint8List contentHash(Uint8List input) =>
    Uint8List.fromList(crypto.sha256.convert(input).bytes);

/// The stable short identifier of a root identity key.
///
/// This is derived from the *root* key, never from a publishing key, so
/// it survives publishing-key rotation — an author keeps one address
/// for life.
Uint8List authorIdFor(Uint8List rootPublicKey) {
  if (rootPublicKey.length != 32) {
    throw ArgumentError.value(
      rootPublicKey.length,
      'rootPublicKey.length',
      'an Ed25519 public key is 32 bytes',
    );
  }
  return Uint8List.fromList(
    contentHash(rootPublicKey).sublist(0, authorIdBytes),
  );
}

/// Whether [a] and [b] hold the same bytes.
bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

const String _hexDigits = '0123456789abcdef';

/// Lowercase hex for [bytes].
String hexEncode(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(_hexDigits[(b >> 4) & 0x0F]);
    out.write(_hexDigits[b & 0x0F]);
  }
  return out.toString();
}

/// Parse lowercase or uppercase hex into bytes.
///
/// Throws [FormatException] on odd length or a non-hex character, so a
/// malformed address from an untrusted source fails at the boundary
/// instead of producing silently wrong bytes.
Uint8List hexDecode(String text) {
  if (text.length.isOdd) {
    throw const FormatException('hex string must have an even length');
  }
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexValue(text.codeUnitAt(i * 2));
    final lo = _hexValue(text.codeUnitAt(i * 2 + 1));
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexValue(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  throw FormatException('not a hex digit: ${String.fromCharCode(codeUnit)}');
}
