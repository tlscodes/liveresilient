/// The smallest thing a person can carry that starts everything else.
///
/// A device that has never connected knows no author and no relay, and no
/// network path will tell it — that is the situation this format exists
/// for. So the first bytes have to arrive by some means a person can
/// perform: a photographed code, a printed line, a note read over a phone
/// call that still works.
///
/// The code carries exactly two things: one relay to ask, and the author's
/// root key. Everything else — the full relay list, the publishing
/// certificate, every post — is fetched afterwards and verified against
/// that key, so the channel the code arrived on needs no integrity of its
/// own and the relay it names needs no trust. If someone hands over a
/// tampered code, the reader follows a different author entirely rather
/// than a forged version of the right one, which is a failure a person can
/// see.
///
/// Text form is Crockford base32: no letters that look like digits, case
/// insensitive, with a checksum so a mistyped character is caught rather
/// than becoming a different key.
library;

import 'dart:typed_data';

import 'broadcast_ids.dart';

/// The only bootstrap version this build understands.
const int bootstrapVersion = 1;

/// Longest relay host accepted in a code.
const int maxBootstrapHostLength = 40;

/// Alphabet without I, L, O or U: nothing that a reader or a listener can
/// confuse with a digit or with each other.
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// One relay and one author, small enough to move by hand.
class BootstrapCode {
  BootstrapCode({required this.host, required this.rootPublicKey}) {
    if (host.isEmpty || host.length > maxBootstrapHostLength) {
      throw ArgumentError.value(
        host,
        'host',
        'must be 1..$maxBootstrapHostLength characters',
      );
    }
    for (final unit in host.codeUnits) {
      final isLower = unit >= 0x61 && unit <= 0x7A;
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isPunct = unit == 0x2D || unit == 0x2E;
      if (!isLower && !isDigit && !isPunct) {
        throw ArgumentError.value(
          host,
          'host',
          'a hostname here is lowercase letters, digits, dots and hyphens',
        );
      }
    }
    if (rootPublicKey.length != 32) {
      throw ArgumentError.value(
        rootPublicKey.length,
        'rootPublicKey.length',
        'an Ed25519 public key is 32 bytes',
      );
    }
  }

  /// Hostname of one relay to start from. The scheme is always https —
  /// carrying it would spend characters on a constant.
  final String host;

  /// The author's long-lived identity key, in full.
  ///
  /// Carried whole rather than as a fingerprint so the code is
  /// self-contained: nothing has to be fetched before anything can be
  /// verified, and the relay named here is never trusted for it.
  final Uint8List rootPublicKey;

  /// The origin to read from.
  Uri get origin => Uri(scheme: 'https', host: host);

  /// This author's address prefix, as the relay paths spell it.
  Uint8List get authorId => authorIdFor(rootPublicKey);

  /// `u8 version · u8 hostLength · host · key32 · u16 checksum`
  Uint8List encodeBytes() {
    final hostBytes = Uint8List.fromList(host.codeUnits);
    final out = Uint8List(2 + hostBytes.length + 32 + 2);
    out[0] = bootstrapVersion;
    out[1] = hostBytes.length;
    out.setRange(2, 2 + hostBytes.length, hostBytes);
    out.setRange(
      2 + hostBytes.length,
      2 + hostBytes.length + 32,
      rootPublicKey,
    );
    final checksum = _crc16(out, out.length - 2);
    out[out.length - 2] = (checksum >> 8) & 0xFF;
    out[out.length - 1] = checksum & 0xFF;
    return out;
  }

  /// The form a person carries: uppercase base32 in groups of four.
  ///
  /// Grouping is for the human, not the format — [parse] ignores spacing
  /// and hyphens entirely, so a code can be written down however it is
  /// easiest to read back.
  String encode({bool grouped = true}) {
    final raw = _base32Encode(encodeBytes());
    if (!grouped) return raw;
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i += 4) {
      if (i > 0) out.write('-');
      out.write(raw.substring(i, i + 4 > raw.length ? raw.length : i + 4));
    }
    return out.toString();
  }

  /// Parse a code as typed, spoken or scanned.
  ///
  /// Returns null on anything that is not a whole, checksummed code — a
  /// wrong character produces nothing rather than a different author.
  static BootstrapCode? parse(String text) {
    final bytes = _base32Decode(text);
    if (bytes == null) return null;
    return decodeBytes(bytes);
  }

  /// Parse the binary form, as scanned from a code or read from a file.
  static BootstrapCode? decodeBytes(Uint8List bytes) {
    if (bytes.length < 2 + 1 + 32 + 2) return null;
    if (bytes[0] != bootstrapVersion) return null;
    final hostLength = bytes[1];
    if (hostLength == 0 || hostLength > maxBootstrapHostLength) return null;
    if (bytes.length != 2 + hostLength + 32 + 2) return null;

    final expected = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
    if (_crc16(bytes, bytes.length - 2) != expected) return null;

    try {
      return BootstrapCode(
        host: String.fromCharCodes(
          Uint8List.sublistView(bytes, 2, 2 + hostLength),
        ),
        rootPublicKey: Uint8List.fromList(
          Uint8List.sublistView(bytes, 2 + hostLength, 2 + hostLength + 32),
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BootstrapCode &&
      other.host == host &&
      bytesEqual(other.rootPublicKey, rootPublicKey);

  @override
  int get hashCode => Object.hash(host, hexEncode(rootPublicKey));

  @override
  String toString() => 'BootstrapCode($host, ${hexEncode(authorId)})';
}

/// CRC-16/CCITT-FALSE over the first [length] bytes.
///
/// Present to catch a human error, not an attack: a single wrong character
/// in a spoken or copied code should fail rather than resolve to some
/// other author.
int _crc16(Uint8List bytes, int length) {
  var crc = 0xFFFF;
  for (var i = 0; i < length; i++) {
    crc ^= bytes[i] << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

String _base32Encode(Uint8List bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 0x1F]);
      bits -= 5;
    }
  }
  if (bits > 0) {
    out.write(_alphabet[(buffer << (5 - bits)) & 0x1F]);
  }
  return out.toString();
}

Uint8List? _base32Decode(String text) {
  var buffer = 0;
  var bits = 0;
  final out = <int>[];
  for (final rune in text.toUpperCase().runes) {
    final char = String.fromCharCode(rune);
    // Spacing, hyphens and the separators people naturally add are not
    // part of the code.
    if (char == '-' || char == ' ' || char == '\n' || char == '\r') continue;
    // The characters Crockford excludes are accepted as the digits they
    // are mistaken for, because a person reading aloud will say them.
    final normalized = switch (char) {
      'O' => '0',
      'I' || 'L' => '1',
      'U' => 'V',
      _ => char,
    };
    final value = _alphabet.indexOf(normalized);
    if (value < 0) return null;
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }
  if (out.isEmpty) return null;
  return Uint8List.fromList(out);
}
