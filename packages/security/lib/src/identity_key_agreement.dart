/// Key agreement with the identity key itself.
///
/// An install's identity is an Ed25519 key, and its peers pin exactly that
/// key. To seal something to a pinned peer without a second key to publish,
/// certify and pin, the same key is used on the Montgomery curve: an
/// Ed25519 public key maps to one X25519 public key, and the Ed25519 seed
/// expands to the matching X25519 scalar. This is the mapping RFC 7748 and
/// RFC 8032 share (`u = (1 + y) / (1 - y)`), the one `age` uses for
/// ssh-ed25519 recipients. Signing and agreement never see the same input:
/// every signature here is over a domain-tagged SHA-256, and the shared
/// secret goes straight into a KDF with its own label.
///
/// No hand-rolled curve arithmetic for secrets: the scalar multiplication
/// is `package:cryptography`'s X25519. The only arithmetic here is the
/// public-key map, on public data.
library;

import 'dart:typed_data';

/// What an identity engine offers when its key can also agree.
///
/// The private key never crosses this interface — only the shared secret
/// does, and the caller must feed it to a KDF, never use it as a key.
abstract class IdentityKeyAgreement {
  /// X25519 between the identity key under [keyHandle] (as a Montgomery
  /// key) and [remoteX25519PublicKey]. Throws [StateError] when the handle
  /// has no key and [ArgumentError] for a remote key that is not 32 bytes
  /// or that yields the all-zero secret (a low-order point).
  Future<Uint8List> agree({
    required String keyHandle,
    required Uint8List remoteX25519PublicKey,
  });
}

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

/// The X25519 public key that belongs to [ed25519PublicKey].
///
/// Throws [ArgumentError] for a key that is not 32 bytes, whose `y` is not
/// a field element, or for `y = 1` (the identity point, which has no
/// Montgomery image).
Uint8List ed25519PublicKeyToX25519(Uint8List ed25519PublicKey) {
  if (ed25519PublicKey.length != 32) {
    throw ArgumentError.value(
      ed25519PublicKey.length,
      'ed25519PublicKey',
      'must be 32 bytes',
    );
  }
  // Little-endian y with the sign bit of x in the top bit.
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    final byte = i == 31 ? ed25519PublicKey[i] & 0x7f : ed25519PublicKey[i];
    y = (y << 8) | BigInt.from(byte);
  }
  if (y >= _p) {
    throw ArgumentError('ed25519PublicKey: y is not a field element');
  }
  final denominator = (BigInt.one - y) % _p;
  if (denominator == BigInt.zero) {
    throw ArgumentError('ed25519PublicKey: the identity point has no image');
  }
  var u = ((BigInt.one + y) * denominator.modInverse(_p)) % _p;
  final out = Uint8List(32);
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    out[i] = (u & mask).toInt();
    u >>= 8;
  }
  return out;
}
