/// Fork evidence as something you can hand to someone.
///
/// The chain already detects a duplicated publishing key: two different
/// descriptors at one sequence number, both correctly signed, are proof
/// no explanation can talk away. But detection alone helps one reader.
/// A compromised author is only useful knowledge if it travels.
///
/// This makes the proof a file. It is self-verifying — anyone holding the
/// author's root key and the certificate can check it without trusting
/// whoever passed it along — which means it can be published anywhere,
/// including on the very relays the attacker is using, and by anyone at
/// all rather than only by the author. That last part matters: the author
/// is precisely the party who may no longer be able to speak.
///
/// What it is not: a revocation. Nothing here can stop a key. It is an
/// argument, made of bytes, that any reader can check for themselves — and
/// that is the strongest thing available to a system with no authority in
/// it.
library;

import 'dart:typed_data';

import 'broadcast_chain.dart';
import 'broadcast_descriptor.dart';
import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'publishing_key_certificate.dart';
import 'wire.dart';

/// The only fork-report version this build understands.
const int forkReportVersion = 1;

/// Why a fork report was refused.
enum ForkReportRejection {
  malformed,
  unsupportedVersion,
  authorMismatch,
  sameDescriptor,
  differentSequence,
  badCertificate,
  unverifiedDescriptor,
}

/// A portable proof that one author's publishing key signed two different
/// posts at the same position.
class ForkReport {
  const ForkReport._({
    required this.certificate,
    required this.first,
    required this.second,
    required this.encoded,
  });

  /// The delegation both posts were signed under.
  ///
  /// Carried inside the report so a recipient needs nothing but the
  /// author's root key — which they already have, or they could not have
  /// been following this author in the first place.
  final PublishingKeyCertificate certificate;

  /// The two conflicting posts, ordered by their content hash so the same
  /// fork always produces byte-identical evidence.
  ///
  /// That ordering is not cosmetic: without it, two readers who saw the
  /// same fork in opposite order would publish two different files, and a
  /// relay would store both.
  final BroadcastDescriptor first;
  final BroadcastDescriptor second;

  final Uint8List encoded;

  /// Content address of the report, for storing it like any other object.
  Uint8List get id => contentHash(encoded);

  Uint8List get authorId => first.authorId;

  int get seq => first.seq;

  /// Build a report from evidence a chain produced.
  static Uint8List buildFrom({
    required ForkEvidence evidence,
    required PublishingKeyCertificate certificate,
  }) => build(certificate: certificate, a: evidence.held, b: evidence.offered);

  /// Build a report from two conflicting descriptors.
  static Uint8List build({
    required PublishingKeyCertificate certificate,
    required BroadcastDescriptor a,
    required BroadcastDescriptor b,
  }) {
    if (!bytesEqual(a.authorId, b.authorId)) {
      throw ArgumentError('the two posts are by different authors');
    }
    if (a.seq != b.seq) {
      throw ArgumentError('a fork is two posts at one sequence number');
    }
    if (bytesEqual(a.id, b.id)) {
      throw ArgumentError('the same post twice is not a fork');
    }
    // Canonical order, so one fork has one file.
    final ordered = hexEncode(a.id).compareTo(hexEncode(b.id)) < 0
        ? [a, b]
        : [b, a];
    final out = WireWriter()
      ..u8(forkReportVersion)
      ..bytes(certificate.encoded)
      ..u16(ordered[0].encoded.length)
      ..bytes(ordered[0].encoded)
      ..u16(ordered[1].encoded.length)
      ..bytes(ordered[1].encoded);
    return out.take();
  }

  /// Parse and fully verify [encoded] against [rootPublicKey].
  ///
  /// Everything is checked: the certificate is this author's and signed by
  /// this root, both posts are this author's, they sit at one sequence
  /// number, they are genuinely different, and both carry a valid
  /// signature from the delegated key. A report that survives all of that
  /// is not an accusation — it is the thing itself.
  static Future<ForkReport?> verify({
    required Uint8List encoded,
    required Uint8List rootPublicKey,
    required BroadcastVerifier verifier,
    void Function(ForkReportRejection reason)? onReject,
  }) async {
    void reject(ForkReportRejection reason) => onReject?.call(reason);

    final reader = WireReader(encoded);
    final Uint8List certificateBody;
    final Uint8List firstBytes;
    final Uint8List secondBytes;
    try {
      if (reader.u8() != forkReportVersion) {
        reject(ForkReportRejection.unsupportedVersion);
        return null;
      }
      certificateBody = reader.bytes(certificateBytes);
      firstBytes = reader.bytes(reader.u16());
      secondBytes = reader.bytes(reader.u16());
      if (reader.remaining != 0) {
        reject(ForkReportRejection.malformed);
        return null;
      }
    } on FormatException {
      reject(ForkReportRejection.malformed);
      return null;
    }

    // The certificate's own dates are deliberately not enforced: a fork is
    // evidence about the past, and refusing to look at it once the window
    // closed would make the proof expire exactly when it is most needed.
    final windowStart = PublishingKeyCertificate.parseWindowStart(
      certificateBody,
    );
    if (windowStart == null) {
      reject(ForkReportRejection.badCertificate);
      return null;
    }
    final certificate = await PublishingKeyCertificate.verify(
      encoded: certificateBody,
      rootPublicKey: rootPublicKey,
      verifier: verifier,
      now: windowStart,
    );
    if (certificate == null) {
      reject(ForkReportRejection.badCertificate);
      return null;
    }

    final first = await BroadcastDescriptor.verify(
      encoded: firstBytes,
      rootPublicKey: rootPublicKey,
      publishingKey: certificate.publishingKey,
      verifier: verifier,
    );
    final second = await BroadcastDescriptor.verify(
      encoded: secondBytes,
      rootPublicKey: rootPublicKey,
      publishingKey: certificate.publishingKey,
      verifier: verifier,
    );
    if (first == null || second == null) {
      reject(ForkReportRejection.unverifiedDescriptor);
      return null;
    }
    if (!bytesEqual(first.authorId, second.authorId)) {
      reject(ForkReportRejection.authorMismatch);
      return null;
    }
    if (first.seq != second.seq) {
      reject(ForkReportRejection.differentSequence);
      return null;
    }
    if (bytesEqual(first.id, second.id)) {
      reject(ForkReportRejection.sameDescriptor);
      return null;
    }

    return ForkReport._(
      certificate: certificate,
      first: first,
      second: second,
      encoded: Uint8List.fromList(encoded),
    );
  }
}

/// Where a fork report lives on a relay.
///
/// A well-known address per author, so anyone can look and anyone can
/// post. Neither needs permission: the report proves itself, so a relay
/// carrying a false one is carrying bytes that fail on arrival.
class ForkReportAddress {
  const ForkReportAddress(this.authorId);

  final Uint8List authorId;

  String get path => '/f/${hexEncode(authorId)}';

  static ForkReportAddress? tryParse(String path) {
    final parts = path.split('/');
    if (parts.length != 3 || parts[0].isNotEmpty || parts[1] != 'f') {
      return null;
    }
    if (parts[2].length != authorIdBytes * 2) return null;
    try {
      return ForkReportAddress(hexDecode(parts[2]));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ForkReportAddress && bytesEqual(other.authorId, authorId);

  @override
  int get hashCode => hexEncode(authorId).hashCode;

  @override
  String toString() => path;
}
