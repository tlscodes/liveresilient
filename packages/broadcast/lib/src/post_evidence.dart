/// One post, packaged so that someone without the app can check it.
///
/// A signature only means something to whoever can check it, and until now
/// that was this app and nothing else. But a message spreads by
/// screenshot, and a screenshot carries no signature — so the thing people
/// actually pass around is precisely the thing that cannot be verified.
///
/// This closes that. An evidence bundle is a single self-contained blob:
/// the author's root key, the certificate, the descriptor, and the text
/// the descriptor commits to. Anyone can check it — with the offline
/// verifier page in `tools/web_verifier`, or with any implementation of
/// this format — and nothing has to be fetched, trusted, or online.
///
/// What it proves and what it does not, stated plainly because a verifier
/// that overclaims is worse than none: it proves this text was signed by
/// the holder of that root key, at that sequence number, at that declared
/// time. It says nothing about *whose* key it is. Binding a key to a
/// person is what the bootstrap code, and ultimately a human, are for.
library;

import 'dart:typed_data';

import 'broadcast_descriptor.dart';
import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'publishing_key_certificate.dart';
import 'wire.dart';

/// The only evidence version this build understands.
const int postEvidenceVersion = 1;

/// Largest text layer an evidence bundle may carry.
///
/// Evidence is meant to be pasted into a page, so it stays small enough
/// to move as text. A longer post is still verifiable through the app;
/// this format is for the part people quote.
const int maxEvidenceTextBytes = 64 * 1024;

/// Why an evidence bundle was refused.
enum EvidenceRejection {
  malformed,
  unsupportedVersion,
  textTooLong,
  badCertificate,
  unverifiedDescriptor,
  noTextLayer,
  textDoesNotMatch,
}

/// A checked post, with everything that made it checkable.
class PostEvidence {
  const PostEvidence._({
    required this.rootPublicKey,
    required this.certificate,
    required this.descriptor,
    required this.text,
    required this.encoded,
  });

  final Uint8List rootPublicKey;
  final PublishingKeyCertificate certificate;
  final BroadcastDescriptor descriptor;

  /// The text layer, exactly as the descriptor committed to it.
  final Uint8List text;

  final Uint8List encoded;

  Uint8List get authorId => descriptor.authorId;

  int get seq => descriptor.seq;

  DateTime get publishedAt => descriptor.publishedAt;

  /// Package a post as evidence.
  ///
  /// [text] must be the exact bytes of the post's text layer; the caller
  /// has them, because it fetched and hash-checked them to display the
  /// post in the first place.
  static Uint8List build({
    required Uint8List rootPublicKey,
    required PublishingKeyCertificate certificate,
    required BroadcastDescriptor descriptor,
    required Uint8List text,
  }) {
    if (rootPublicKey.length != 32) {
      throw ArgumentError.value(
        rootPublicKey.length,
        'rootPublicKey.length',
        'an Ed25519 public key is 32 bytes',
      );
    }
    final committed = descriptor.layer(LayerFlag.text);
    if (committed == null) {
      throw ArgumentError.value(
        descriptor,
        'descriptor',
        'evidence needs a post with a text layer',
      );
    }
    if (!bytesEqual(contentHash(text), committed)) {
      throw ArgumentError.value(
        text,
        'text',
        'these bytes are not what the descriptor commits to',
      );
    }
    if (text.length > maxEvidenceTextBytes) {
      throw ArgumentError.value(
        text.length,
        'text.length',
        'at most $maxEvidenceTextBytes bytes',
      );
    }
    final out = WireWriter()
      ..u8(postEvidenceVersion)
      ..bytes(rootPublicKey)
      ..bytes(certificate.encoded)
      ..u16(descriptor.encoded.length)
      ..bytes(descriptor.encoded)
      ..u32(text.length)
      ..bytes(text);
    return out.take();
  }

  /// Parse and fully verify an evidence bundle.
  ///
  /// Self-contained by construction: the root key it verifies against is
  /// the one inside the bundle. That is not circular, because the claim
  /// being checked is "this text was signed by the holder of this key" —
  /// which is exactly what a reader can then compare against a key they
  /// obtained some other way.
  static Future<PostEvidence?> verify({
    required Uint8List encoded,
    required BroadcastVerifier verifier,
    void Function(EvidenceRejection reason)? onReject,
  }) async {
    void reject(EvidenceRejection reason) => onReject?.call(reason);

    final reader = WireReader(encoded);
    final Uint8List rootPublicKey;
    final Uint8List certificateBody;
    final Uint8List descriptorBytes;
    final Uint8List text;
    try {
      if (reader.u8() != postEvidenceVersion) {
        reject(EvidenceRejection.unsupportedVersion);
        return null;
      }
      rootPublicKey = reader.bytes(32);
      certificateBody = reader.bytes(certificateBytes);
      descriptorBytes = reader.bytes(reader.u16());
      final textLength = reader.u32();
      if (textLength > maxEvidenceTextBytes) {
        reject(EvidenceRejection.textTooLong);
        return null;
      }
      text = reader.bytes(textLength);
      if (reader.remaining != 0) {
        reject(EvidenceRejection.malformed);
        return null;
      }
    } on FormatException {
      reject(EvidenceRejection.malformed);
      return null;
    }

    // The certificate's validity dates are checked at its own start
    // instant, not at now: evidence is about the past, and a proof that
    // stopped working when the window closed would be useless for the
    // thing it exists for — showing that something was said.
    final windowStart = PublishingKeyCertificate.parseWindowStart(
      certificateBody,
    );
    if (windowStart == null) {
      reject(EvidenceRejection.badCertificate);
      return null;
    }
    final certificate = await PublishingKeyCertificate.verify(
      encoded: certificateBody,
      rootPublicKey: rootPublicKey,
      verifier: verifier,
      now: windowStart,
    );
    if (certificate == null) {
      reject(EvidenceRejection.badCertificate);
      return null;
    }

    final descriptor = await BroadcastDescriptor.verify(
      encoded: descriptorBytes,
      rootPublicKey: rootPublicKey,
      publishingKey: certificate.publishingKey,
      verifier: verifier,
    );
    if (descriptor == null) {
      reject(EvidenceRejection.unverifiedDescriptor);
      return null;
    }

    final committed = descriptor.layer(LayerFlag.text);
    if (committed == null) {
      reject(EvidenceRejection.noTextLayer);
      return null;
    }
    if (!bytesEqual(contentHash(text), committed)) {
      reject(EvidenceRejection.textDoesNotMatch);
      return null;
    }

    return PostEvidence._(
      rootPublicKey: rootPublicKey,
      certificate: certificate,
      descriptor: descriptor,
      text: text,
      encoded: Uint8List.fromList(encoded),
    );
  }
}
