/// Real [MediaFrameAuthenticator] built from the [EnvelopeSigner] /
/// [EnvelopeVerifier] ports, matching the Ed25519 trust model used for local
/// link envelopes: a signature authenticates *who is currently vouching for
/// this transmission*.
///
/// ## Interface-semantics note (documented delta)
/// [MediaFrame] carries a single `signature` field, not one signature per
/// hop. `MediaFrameAuthenticator`'s doc comment says the implementation
/// "must verify the origin signature and every relay transition" — with one
/// signature slot, a forwarder cannot both re-sign the transition (proving
/// *it* relayed this hop) and preserve the origin's original signature
/// bytes untouched. The faithful reading implemented here, consistent with
/// `authenticated_envelope.dart`'s "authenticates who relayed the bytes on
/// this hop" model: `signature` always authenticates the *current* relay
/// (`currentRelayKeyId`) over the frame's canonical bytes. `originKeyId` and
/// `ciphertext` are preserved verbatim across every forwarding transition —
/// the origin claim survives as plain (unsigned-by-itself) metadata, and
/// each hop's signature is freshly produced by the forwarder over that
/// unchanged origin/ciphertext plus the new hop count and relay id. This
/// matches the locked design directive: "origin key stays, forwarder signs
/// the transition."
library;

import 'dart:convert';
import 'dart:typed_data';

import 'authenticated_envelope.dart' show EnvelopeSigner, EnvelopeVerifier;
import 'media_frame.dart';

/// Canonical, length-prefixed bytes covered by [MediaFrame.signature].
/// Exposed (not private) so callers can construct origin-signed frames
/// without duplicating the canonicalization.
Uint8List mediaFrameSignedBytes(MediaFrame frame) {
  final builder = BytesBuilder(copy: false);
  void addField(List<int> bytes) {
    final length = ByteData(4)..setUint32(0, bytes.length);
    builder.add(length.buffer.asUint8List());
    builder.add(bytes);
  }

  addField(utf8.encode('mf-v${frame.version}'));
  addField(utf8.encode(frame.messageId));
  addField(utf8.encode(frame.originKeyId));
  addField(utf8.encode(frame.currentRelayKeyId));
  addField(utf8.encode(frame.createdAtMs.toString()));
  addField(utf8.encode(frame.expiresAtMs.toString()));
  addField(utf8.encode(frame.maxHops.toString()));
  addField(utf8.encode(frame.hopCount.toString()));
  addField(frame.ciphertext);
  return builder.toBytes();
}

/// Real Ed25519-backed [MediaFrameAuthenticator].
///
/// [signer] is this device's own identity, used to sign the transition when
/// forwarding. [verifier] resolves the trusted public key for whichever
/// device claims `currentRelayKeyId` on an inbound frame.
class CryptoMediaFrameAuthenticator implements MediaFrameAuthenticator {
  final EnvelopeSigner signer;
  final EnvelopeVerifier verifier;

  CryptoMediaFrameAuthenticator({required this.signer, required this.verifier});

  @override
  Future<bool> verify(MediaFrame envelope) {
    return verifier.verify(
      keyId: envelope.currentRelayKeyId,
      message: mediaFrameSignedBytes(envelope),
      signature: envelope.signature,
    );
  }

  @override
  Future<MediaFrame> createForwardedEnvelope(MediaFrame envelope) async {
    final unsigned = MediaFrame(
      version: envelope.version,
      messageId: envelope.messageId,
      originKeyId: envelope.originKeyId,
      currentRelayKeyId: signer.keyId,
      createdAtMs: envelope.createdAtMs,
      expiresAtMs: envelope.expiresAtMs,
      maxHops: envelope.maxHops,
      hopCount: envelope.hopCount + 1,
      ciphertext: envelope.ciphertext,
      signature: const [],
    );
    final signature = await signer.sign(mediaFrameSignedBytes(unsigned));
    return MediaFrame(
      version: unsigned.version,
      messageId: unsigned.messageId,
      originKeyId: unsigned.originKeyId,
      currentRelayKeyId: unsigned.currentRelayKeyId,
      createdAtMs: unsigned.createdAtMs,
      expiresAtMs: unsigned.expiresAtMs,
      maxHops: unsigned.maxHops,
      hopCount: unsigned.hopCount,
      ciphertext: unsigned.ciphertext,
      signature: signature,
    );
  }

  /// Creates and signs the initial (hop 0) frame from the origin device,
  /// where `originKeyId == currentRelayKeyId == signer.keyId`.
  static Future<MediaFrame> createOriginFrame({
    required EnvelopeSigner signer,
    required String messageId,
    required List<int> ciphertext,
    required int createdAtMs,
    required int expiresAtMs,
    required int maxHops,
    int version = 1,
  }) async {
    final unsigned = MediaFrame(
      version: version,
      messageId: messageId,
      originKeyId: signer.keyId,
      currentRelayKeyId: signer.keyId,
      createdAtMs: createdAtMs,
      expiresAtMs: expiresAtMs,
      maxHops: maxHops,
      hopCount: 0,
      ciphertext: ciphertext,
      signature: const [],
    );
    final signature = await signer.sign(mediaFrameSignedBytes(unsigned));
    return MediaFrame(
      version: unsigned.version,
      messageId: unsigned.messageId,
      originKeyId: unsigned.originKeyId,
      currentRelayKeyId: unsigned.currentRelayKeyId,
      createdAtMs: unsigned.createdAtMs,
      expiresAtMs: unsigned.expiresAtMs,
      maxHops: unsigned.maxHops,
      hopCount: unsigned.hopCount,
      ciphertext: unsigned.ciphertext,
      signature: signature,
    );
  }
}
