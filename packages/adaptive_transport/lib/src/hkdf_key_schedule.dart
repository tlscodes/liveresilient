import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF (RFC 5869) over HMAC-SHA256: extract-then-expand key derivation.
///
/// Implemented exactly per the RFC so the appendix-A test vectors verify it
/// byte-for-byte (see phase7 tests).
class Hkdf {
  const Hkdf._();

  /// HKDF-Extract(salt, IKM) -> PRK (RFC 5869 section 2.2).
  static Uint8List extract(Uint8List salt, Uint8List ikm) {
    final effectiveSalt =
        salt.isEmpty ? Uint8List(sha256.blockSize ~/ 2) : salt;
    return Uint8List.fromList(Hmac(sha256, effectiveSalt).convert(ikm).bytes);
  }

  /// HKDF-Expand(PRK, info, L) -> OKM (RFC 5869 section 2.3).
  static Uint8List expand(Uint8List prk, Uint8List info, int length) {
    if (length <= 0 || length > 255 * 32) {
      throw ArgumentError.value(length, 'length', 'must be in [1, 255*32]');
    }
    final okm = BytesBuilder(copy: false);
    var previous = Uint8List(0);
    var counter = 1;
    while (okm.length < length) {
      final block = Hmac(sha256, prk)
          .convert([...previous, ...info, counter])
          .bytes;
      previous = Uint8List.fromList(block);
      okm.add(previous);
      counter++;
    }
    return Uint8List.sublistView(okm.toBytes(), 0, length);
  }

  /// One-call derive: extract then expand.
  static Uint8List derive({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) =>
      expand(extract(salt, ikm), info, length);
}

/// Epoch-based traffic-key rotation driven by HKDF-Expand.
///
/// Each epoch's key is derived from the previous epoch's key with the info
/// string `"relay rekey" || epoch`, mirroring the TLS 1.3 KeyUpdate ratchet
/// (RFC 8446 section 7.2): once an epoch is advanced, the old key cannot be
/// recomputed from the new one (one-way HMAC ratchet).
class RotatingKeySchedule {
  RotatingKeySchedule({
    required Uint8List initialSecret,
    this.keyLength = 32,
    this.messagesPerEpoch = 1 << 20,
  })  : _current = Uint8List.fromList(initialSecret),
        assert(keyLength > 0),
        assert(messagesPerEpoch > 0) {
    _current = Hkdf.derive(
      ikm: _current,
      salt: Uint8List(0),
      info: Uint8List.fromList(utf8.encode('relay epoch 0')),
      length: keyLength,
    );
  }

  Uint8List _current;
  int _epoch = 0;
  int _messagesInEpoch = 0;

  final int keyLength;

  /// How many protected messages an epoch may carry before rotation is
  /// required.
  final int messagesPerEpoch;

  int get epoch => _epoch;

  /// The traffic key for the current epoch. Callers must not cache it across
  /// [advance] calls.
  Uint8List get currentKey => Uint8List.fromList(_current);

  /// Ratchets to the next epoch and forgets the previous key material.
  void advance() {
    _epoch++;
    _messagesInEpoch = 0;
    final next = Hkdf.derive(
      ikm: _current,
      salt: Uint8List(0),
      info: Uint8List.fromList(utf8.encode('relay rekey $_epoch')),
      length: keyLength,
    );
    _current.fillRange(0, _current.length, 0);
    _current = next;
  }

  /// Records one protected message; returns true when the epoch limit was hit
  /// and [advance] ran automatically.
  bool recordMessage() {
    _messagesInEpoch++;
    if (_messagesInEpoch >= messagesPerEpoch) {
      advance();
      return true;
    }
    return false;
  }
}
