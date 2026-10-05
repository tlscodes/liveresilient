// A letter locked to the recipient's pinned identity key.
//
// What the relay holds is a box: a magic, a length, a one-time public key
// and ciphertext. It names no sender and no recipient. The recipient is
// whoever owns the mailbox it was put in — and the box only opens there,
// because the recipient's install id and key are bound into the key
// derivation and into the sender's signature. The sender is named, and
// proven, INSIDE the ciphertext: install id, identity key, and a signature
// over everything the recipient is about to trust.
//
// Locked to the pinned key itself, not to a second key: an Ed25519 identity
// key has one X25519 twin (security/identity_key_agreement.dart), so anyone
// whose key is pinned can be written to with nothing further exchanged.
//
// Lengths are padded to a multiple of [sealedBucket] before sealing, so a
// receipt and a short letter are the same size on the wire and the relay
// cannot tell them apart.
//
// What this is not: forward secret on the recipient's side. The sender's
// half of the agreement is a one-time key, the recipient's is its identity
// key — someone who later takes that key and kept the boxes can open them.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:security/security.dart';

import '../peer_identity.dart' show AppIdentity;

/// "VKSL1".
const List<int> sealedMagic = [0x56, 0x4B, 0x53, 0x4C, 0x31];

/// Plaintext is padded to a multiple of this before sealing.
const int sealedBucket = 256;

/// The most a letter's body may be. The relay queues at most 4 MiB for an
/// absent peer; this keeps one letter far below that.
const int sealedMaxBody = 60000;

const int _installBytes = AppIdentity.installIdBytes;
const int _headerBytes = 1 + 1 + _installBytes + 32 + 16 + 8 + 4;
const int _sigBytes = 64;
const int _macBytes = 16;
const int _frameHeader = 5 + 4;

enum SealedKind {
  /// Something a person wrote.
  letter(1),

  /// "I opened letter X": the letter's id and the SHA-256 of its body.
  receipt(2);

  const SealedKind(this.wire);
  final int wire;

  static SealedKind? fromWire(int value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// What a box held, after it opened and its signature checked out against
/// the key it names. Whether that key is the one PINNED for
/// [senderInstall] is the caller's question — this class never reads pins.
class OpenedBox {
  const OpenedBox({
    required this.kind,
    required this.senderInstall,
    required this.senderKey,
    required this.letterId,
    required this.createdAt,
    required this.body,
  });

  final SealedKind kind;
  final String senderInstall;
  final Uint8List senderKey;
  final String letterId;
  final DateTime createdAt;
  final Uint8List body;
}

/// Seals to a pinned key and opens what was sealed to this install.
class SealedBoxCodec {
  SealedBoxCodec(this._identity, {Random? random})
    : _random = random ?? Random.secure();

  final AppIdentity _identity;
  final Random _random;
  final X25519 _x25519 = X25519();
  final Cipher _aead = Chacha20.poly1305Aead();
  final Sha256 _sha256 = Sha256();

  static final List<int> _sigDomain = utf8.encode('vck-sealed-sig-v1\n');
  static final List<int> _keyDomain = utf8.encode('vck-sealed-box-v1\n');
  static final List<int> _zeroNonce = List<int>.filled(12, 0);

  /// Sixteen fresh random bytes, as hex: a letter's id.
  String newLetterId() =>
      _hex([for (var i = 0; i < 16; i++) _random.nextInt(256)]);

  /// Locks [body] to [recipientKey] (the recipient's pinned Ed25519 key)
  /// for the mailbox of [recipientInstall]. Throws [ArgumentError] for a
  /// body over [sealedMaxBody] or ids/keys of the wrong shape.
  Future<Uint8List> seal({
    required String recipientInstall,
    required Uint8List recipientKey,
    required SealedKind kind,
    required String letterId,
    required DateTime createdAt,
    required Uint8List body,
  }) async {
    if (body.length > sealedMaxBody) {
      throw ArgumentError.value(body.length, 'body', 'over $sealedMaxBody');
    }
    final recipientId = _unhex(recipientInstall, _installBytes, 'recipient');
    final id = _unhex(letterId, 16, 'letterId');
    final recipientX = ed25519PublicKeyToX25519(recipientKey);
    final ownInstall = await _identity.installId();
    final ownKey = (await _identity.store.localIdentity()).publicKey;

    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(recipientX, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(
      await shared.extractBytes(),
      ephemeralPublic: ephemeralPublic,
      recipientX: recipientX,
      recipientInstall: recipientId,
    );

    // header | body | zero padding, sized so that with the signature the
    // plaintext is a whole number of buckets.
    final unpadded = _headerBytes + body.length + _sigBytes;
    final padded =
        ((unpadded + sealedBucket - 1) ~/ sealedBucket) * sealedBucket;
    final signedPart = Uint8List(padded - _sigBytes);
    final view = ByteData.sublistView(signedPart);
    var at = 0;
    signedPart[at++] = 1; // version
    signedPart[at++] = kind.wire;
    signedPart.setAll(at, ownInstall);
    at += _installBytes;
    signedPart.setAll(at, ownKey);
    at += 32;
    signedPart.setAll(at, id);
    at += 16;
    view.setUint64(at, createdAt.toUtc().millisecondsSinceEpoch);
    at += 8;
    view.setUint32(at, body.length);
    at += 4;
    signedPart.setAll(at, body);

    final signature = await _identity.store.signSessionFingerprint(
      await _sigDigest(
        recipientInstall: recipientId,
        recipientKey: recipientKey,
        ephemeralPublic: ephemeralPublic,
        signedPart: signedPart,
      ),
    );
    final sealed = await _aead.encrypt(
      [...signedPart, ...signature],
      secretKey: key,
      nonce: _zeroNonce,
      aad: sealedMagic,
    );

    final rest = 32 + sealed.cipherText.length + _macBytes;
    final out = BytesBuilder(copy: false)
      ..add(sealedMagic)
      ..add(_u32(rest))
      ..add(ephemeralPublic)
      ..add(sealed.cipherText)
      ..add(sealed.mac.bytes);
    return out.takeBytes();
  }

  /// Opens one framed [box] that was sealed to this install. Null for
  /// anything else: a box for another mailbox, a damaged or forged one, a
  /// frame that is not a box at all. Never throws.
  Future<OpenedBox?> open(Uint8List box) async {
    try {
      if (box.length < _frameHeader + 32 + _macBytes + sealedBucket) {
        return null;
      }
      for (var i = 0; i < sealedMagic.length; i++) {
        if (box[i] != sealedMagic[i]) return null;
      }
      final rest = ByteData.sublistView(box).getUint32(5);
      if (rest != box.length - _frameHeader) return null;
      final ephemeralPublic = Uint8List.sublistView(box, 9, 41);
      final cipherText = Uint8List.sublistView(box, 41, box.length - _macBytes);
      final mac = Uint8List.sublistView(box, box.length - _macBytes);

      final ownInstall = await _identity.installId();
      final ownKey = (await _identity.store.localIdentity()).publicKey;
      final shared = await _identity.store.agreeWithLocalIdentity(
        ephemeralPublic,
      );
      final key = await _deriveKey(
        shared,
        ephemeralPublic: ephemeralPublic,
        recipientX: ed25519PublicKeyToX25519(ownKey),
        recipientInstall: ownInstall,
      );
      final List<int> plain;
      try {
        plain = await _aead.decrypt(
          SecretBox(cipherText, nonce: _zeroNonce, mac: Mac(mac)),
          secretKey: key,
          aad: sealedMagic,
        );
      } on SecretBoxAuthenticationError {
        return null;
      }
      if (plain.length < _headerBytes + _sigBytes ||
          plain.length % sealedBucket != 0) {
        return null;
      }
      final signedPart = Uint8List.fromList(
        plain.sublist(0, plain.length - _sigBytes),
      );
      final signature = Uint8List.fromList(
        plain.sublist(plain.length - _sigBytes),
      );
      final view = ByteData.sublistView(signedPart);
      var at = 0;
      if (signedPart[at++] != 1) return null;
      final kind = SealedKind.fromWire(signedPart[at++]);
      if (kind == null) return null;
      final senderInstall = signedPart.sublist(at, at += _installBytes);
      final senderKey = Uint8List.fromList(signedPart.sublist(at, at += 32));
      final letterId = signedPart.sublist(at, at += 16);
      final createdAt = view.getUint64(at);
      at += 8;
      final bodyLength = view.getUint32(at);
      at += 4;
      if (bodyLength > sealedMaxBody || at + bodyLength > signedPart.length) {
        return null;
      }
      final proven = await _identity.engine.verify(
        publicKey: senderKey,
        message: await _sigDigest(
          recipientInstall: ownInstall,
          recipientKey: ownKey,
          ephemeralPublic: ephemeralPublic,
          signedPart: signedPart,
        ),
        signature: signature,
      );
      if (!proven) return null;
      return OpenedBox(
        kind: kind,
        senderInstall: _hex(senderInstall),
        senderKey: senderKey,
        letterId: _hex(letterId),
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
        body: Uint8List.fromList(signedPart.sublist(at, at + bodyLength)),
      );
    } catch (_) {
      // A hostile frame must cost nothing but itself.
      return null;
    }
  }

  /// Cuts what a mailbox handed over into boxes. The relay concatenates
  /// frames with nothing between them, so each box carries its own length;
  /// bytes that are not a box (someone else's frame, a truncated one) are
  /// skipped up to the next magic rather than poisoning what follows.
  static List<Uint8List> split(Uint8List stream) {
    final boxes = <Uint8List>[];
    var at = 0;
    while (at + _frameHeader <= stream.length) {
      var isMagic = true;
      for (var i = 0; i < sealedMagic.length; i++) {
        if (stream[at + i] != sealedMagic[i]) {
          isMagic = false;
          break;
        }
      }
      if (!isMagic) {
        at++;
        continue;
      }
      final rest = ByteData.sublistView(stream).getUint32(at + 5);
      final end = at + _frameHeader + rest;
      if (rest > sealedMaxBody + 4 * sealedBucket || end > stream.length) {
        at++;
        continue;
      }
      boxes.add(Uint8List.fromList(stream.sublist(at, end)));
      at = end;
    }
    return boxes;
  }

  Future<SecretKey> _deriveKey(
    List<int> shared, {
    required Uint8List ephemeralPublic,
    required Uint8List recipientX,
    required Uint8List recipientInstall,
  }) => Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(shared),
    nonce: const <int>[],
    info: [
      ..._keyDomain,
      ...ephemeralPublic,
      ...recipientX,
      ...recipientInstall,
    ],
  );

  Future<Uint8List> _sigDigest({
    required Uint8List recipientInstall,
    required Uint8List recipientKey,
    required Uint8List ephemeralPublic,
    required Uint8List signedPart,
  }) async => Uint8List.fromList(
    (await _sha256.hash([
      ..._sigDomain,
      ...recipientInstall,
      ...recipientKey,
      ...ephemeralPublic,
      ...signedPart,
    ])).bytes,
  );
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String text, int length, String name) {
  if (text.length != length * 2) {
    throw ArgumentError.value(text, name, 'must be ${length * 2} hex chars');
  }
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    final byte = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw ArgumentError.value(text, name, 'must be hex');
    }
    out[i] = byte;
  }
  return out;
}
