/// The descriptor: the root of trust for one post.
///
/// A descriptor carries no content. It is a small fixed-layout record
/// that commits to the hash of each layer, so the layers can be fetched
/// independently, in any order, from different relays, and still be
/// bound to each other and to a sequence position by one signature.
///
/// Two consequences worth stating, because they are the reason for this
/// shape rather than signing the text layer directly:
///
///  * A post with no text is representable. A photo-only post is not a
///    special case.
///  * The root of trust has a fixed size no matter how large a layer
///    grows, so a reader can always afford to fetch and check it first.
library;

import 'dart:typed_data';

import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'wire.dart';

final Uint8List _descriptorDomain = Uint8List.fromList(
  'vck/broadcast/descriptor/v1\n'.codeUnits,
);

/// The only descriptor version this build understands.
const int descriptorVersion = 1;

/// Which optional layers a descriptor commits to.
///
/// The bits are ordered by how early a reader wants the layer, and the
/// hashes appear on the wire in this same order, so parsing never needs
/// a lookup table.
class LayerFlag {
  const LayerFlag._();

  static const int text = 0x01;
  static const int still = 0x02;
  static const int voice = 0x04;
  static const int mediaList = 0x08;

  /// Not a layer: the id of an earlier post by this author that this one
  /// withdraws. Occupies a commitment slot because it is the same shape —
  /// a 32-byte hash — and reusing the mechanism means no new parsing.
  ///
  /// See [BroadcastDescriptor.retracts].
  static const int retraction = 0x10;

  /// Every bit this version defines. Anything outside this mask is from a
  /// future build, and a descriptor carrying one is refused rather than
  /// silently mis-parsed — the unknown bit would shift every field after
  /// it. That refusal is why adding [retraction] is safe: an older reader
  /// declines a retracting post instead of showing it stripped of the
  /// very thing that made it a correction.
  static const int known = text | still | voice | mediaList | retraction;

  /// The layer bits, in wire order. [retraction] is deliberately absent:
  /// it carries no content and is not fetched.
  static const List<int> ordered = [text, still, voice, mediaList];

  /// Every commitment slot in wire order, layers first.
  static const List<int> allSlots = [text, still, voice, mediaList, retraction];
}

/// Fixed part of a descriptor: version, flags, author id, seq, time, prev.
const int _descriptorHeaderBytes = 1 + 1 + authorIdBytes + 4 + 5 + hashBytes;

/// Encoded size of a descriptor with [flags] set.
int descriptorSizeFor(int flags) {
  var count = 0;
  for (final flag in LayerFlag.allSlots) {
    if ((flags & flag) != 0) count++;
  }
  return _descriptorHeaderBytes + count * hashBytes + 64;
}

/// Why a descriptor was refused.
enum DescriptorRejection {
  malformed,
  unsupportedVersion,
  unknownLayerFlag,
  noLayers,
  wrongLength,
  authorMismatch,
  genesisMustNotLink,
  nonGenesisMustLink,
  badSignature,
}

/// One post's signed commitment to its layers.
class BroadcastDescriptor {
  BroadcastDescriptor({
    required this.authorId,
    required this.seq,
    required this.publishedAt,
    required this.prev,
    required Map<int, Uint8List> commitments,
    required this.signature,
    required this.encoded,
  }) : _commitments = Map.unmodifiable(commitments),
       id = contentHash(encoded);

  /// Truncated identifier of the author's root key.
  final Uint8List authorId;

  /// Position in this author's chain. Zero is genesis.
  final int seq;

  /// Author-declared publication time. Not trusted as a clock — it is
  /// only required to be non-decreasing along the chain.
  final DateTime publishedAt;

  /// Hash of the descriptor at `seq - 1`, or [zeroHash] at genesis.
  final Uint8List prev;

  /// Every 32-byte commitment this descriptor carries, keyed by slot.
  final Map<int, Uint8List> _commitments;

  /// Hash per present layer, keyed by [LayerFlag].
  ///
  /// Excludes the retraction slot, which commits to a post rather than to
  /// content and must never be fetched as one.
  Map<int, Uint8List> get layers => {
    for (final flag in LayerFlag.ordered)
      if (_commitments.containsKey(flag)) flag: _commitments[flag]!,
  };

  /// The id of an earlier post by this author that this one withdraws.
  ///
  /// A correction is the most consequential thing a trusted voice does in
  /// a crisis, and without a signed way to say it the only option is
  /// another post that a reader may never connect to the first. This makes
  /// the link part of what the author signed, so a reader that holds both
  /// cannot show the withdrawn one as though it still stood.
  ///
  /// Never null for a post that retracts nothing — a reader checks
  /// presence, not a sentinel.
  Uint8List? get retracts => _commitments[LayerFlag.retraction];

  bool get isRetraction => retracts != null;

  final Uint8List signature;

  /// The exact bytes this was parsed from, or produced as.
  final Uint8List encoded;

  /// Content address of this descriptor.
  final Uint8List id;

  /// Bit set of present layers.
  int get flags {
    var out = 0;
    for (final flag in LayerFlag.allSlots) {
      if (_commitments.containsKey(flag)) out |= flag;
    }
    return out;
  }

  bool get isGenesis => seq == 0;

  /// Hash of the named layer, or null when the post has no such layer.
  Uint8List? layer(int flag) =>
      LayerFlag.ordered.contains(flag) ? _commitments[flag] : null;

  /// Build and sign a descriptor.
  ///
  /// [signer] holds the *publishing* key; [authorId] names the root key
  /// that delegated to it. Keeping these separate is what lets the
  /// publishing key rotate without changing the author's address.
  static Future<BroadcastDescriptor> sign({
    required BroadcastSigner signer,
    required Uint8List authorId,
    required int seq,
    required DateTime publishedAt,
    required Uint8List prev,
    required Map<int, Uint8List> layers,
    Uint8List? retracts,
  }) async {
    if (authorId.length != authorIdBytes) {
      throw ArgumentError.value(
        authorId.length,
        'authorId.length',
        'must be $authorIdBytes bytes',
      );
    }
    if (layers.isEmpty) {
      throw ArgumentError.value(layers, 'layers', 'a post needs a layer');
    }
    if (retracts != null && retracts.length != hashBytes) {
      throw ArgumentError.value(
        retracts.length,
        'retracts.length',
        'a descriptor id is $hashBytes bytes',
      );
    }
    for (final entry in layers.entries) {
      if (!LayerFlag.ordered.contains(entry.key)) {
        throw ArgumentError.value(entry.key, 'layers', 'unknown layer flag');
      }
      if (entry.value.length != hashBytes) {
        throw ArgumentError.value(
          entry.value.length,
          'layers',
          'a layer hash is $hashBytes bytes',
        );
      }
    }
    if (prev.length != hashBytes) {
      throw ArgumentError.value(
        prev.length,
        'prev.length',
        'must be $hashBytes bytes',
      );
    }
    if (seq == 0 && !bytesEqual(prev, zeroHash)) {
      throw ArgumentError.value(prev, 'prev', 'genesis must not link back');
    }
    if (seq != 0 && bytesEqual(prev, zeroHash)) {
      throw ArgumentError.value(prev, 'prev', 'only genesis may be unlinked');
    }

    final commitments = <int, Uint8List>{
      ...layers,
      if (retracts != null) LayerFlag.retraction: retracts,
    };
    final body = _body(
      authorId: authorId,
      seq: seq,
      publishedAt: publishedAt,
      prev: prev,
      commitments: commitments,
    );
    final signature = await signer.sign(_signingInput(body));
    final out = WireWriter()
      ..bytes(body)
      ..bytes(signature);
    return BroadcastDescriptor(
      authorId: Uint8List.fromList(authorId),
      seq: seq,
      publishedAt: publishedAt.toUtc(),
      prev: Uint8List.fromList(prev),
      commitments: {
        for (final flag in LayerFlag.allSlots)
          if (commitments.containsKey(flag))
            flag: Uint8List.fromList(commitments[flag]!),
      },
      signature: signature,
      encoded: out.take(),
    );
  }

  /// Parse [encoded] without checking the signature.
  ///
  /// Exposed for relays and caches, which route and deduplicate posts
  /// they cannot verify because they do not hold author keys. An
  /// application must never display the result of this — use [verify].
  static BroadcastDescriptor? parse(
    Uint8List encoded, {
    void Function(DescriptorRejection reason)? onReject,
  }) {
    void reject(DescriptorRejection reason) => onReject?.call(reason);

    if (encoded.length < _descriptorHeaderBytes + hashBytes + 64) {
      reject(DescriptorRejection.malformed);
      return null;
    }
    final reader = WireReader(encoded);
    try {
      final version = reader.u8();
      if (version != descriptorVersion) {
        reject(DescriptorRejection.unsupportedVersion);
        return null;
      }
      final flags = reader.u8();
      if ((flags & ~LayerFlag.known) != 0) {
        reject(DescriptorRejection.unknownLayerFlag);
        return null;
      }
      if (flags == 0) {
        reject(DescriptorRejection.noLayers);
        return null;
      }
      if (encoded.length != descriptorSizeFor(flags)) {
        reject(DescriptorRejection.wrongLength);
        return null;
      }

      final authorId = reader.bytes(authorIdBytes);
      final seq = reader.u32();
      final publishedAt = DateTime.fromMillisecondsSinceEpoch(
        reader.u40() * 1000,
        isUtc: true,
      );
      final prev = reader.bytes(hashBytes);
      final commitments = <int, Uint8List>{};
      for (final flag in LayerFlag.allSlots) {
        if ((flags & flag) != 0) commitments[flag] = reader.bytes(hashBytes);
      }
      final signature = reader.bytes(64);

      if (seq == 0 && !bytesEqual(prev, zeroHash)) {
        reject(DescriptorRejection.genesisMustNotLink);
        return null;
      }
      if (seq != 0 && bytesEqual(prev, zeroHash)) {
        reject(DescriptorRejection.nonGenesisMustLink);
        return null;
      }

      return BroadcastDescriptor(
        authorId: authorId,
        seq: seq,
        publishedAt: publishedAt,
        prev: prev,
        commitments: commitments,
        signature: signature,
        encoded: Uint8List.fromList(encoded),
      );
    } on FormatException {
      reject(DescriptorRejection.malformed);
      return null;
    }
  }

  /// Parse and verify [encoded] against a publishing key.
  ///
  /// [rootPublicKey] is checked against the embedded author id, so a
  /// descriptor cannot be re-attributed to another author by swapping
  /// the key it is presented with.
  static Future<BroadcastDescriptor?> verify({
    required Uint8List encoded,
    required Uint8List rootPublicKey,
    required Uint8List publishingKey,
    required BroadcastVerifier verifier,
    void Function(DescriptorRejection reason)? onReject,
  }) async {
    final parsed = parse(encoded, onReject: onReject);
    if (parsed == null) return null;

    if (rootPublicKey.length != 32 ||
        !bytesEqual(parsed.authorId, authorIdFor(rootPublicKey))) {
      onReject?.call(DescriptorRejection.authorMismatch);
      return null;
    }

    final bodyEnd = parsed.encoded.length - 64;
    final body = Uint8List.fromList(
      Uint8List.sublistView(parsed.encoded, 0, bodyEnd),
    );
    final ok = await verifier.verify(
      message: _signingInput(body),
      signature: parsed.signature,
      publicKey: publishingKey,
    );
    if (!ok) {
      onReject?.call(DescriptorRejection.badSignature);
      return null;
    }
    return parsed;
  }

  static Uint8List _body({
    required Uint8List authorId,
    required int seq,
    required DateTime publishedAt,
    required Uint8List prev,
    required Map<int, Uint8List> commitments,
  }) {
    var flags = 0;
    for (final flag in LayerFlag.allSlots) {
      if (commitments.containsKey(flag)) flags |= flag;
    }
    final seconds = publishedAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0 || seconds > 0xFFFFFFFFFF) {
      throw ArgumentError.value(
        publishedAt,
        'publishedAt',
        'not representable in five bytes',
      );
    }
    final out = WireWriter()
      ..u8(descriptorVersion)
      ..u8(flags)
      ..bytes(authorId)
      ..u32(seq)
      ..u40(seconds)
      ..bytes(prev);
    for (final flag in LayerFlag.allSlots) {
      final hash = commitments[flag];
      if (hash != null) out.bytes(hash);
    }
    return out.take();
  }

  static Uint8List _signingInput(Uint8List body) {
    final out = WireWriter()
      ..bytes(_descriptorDomain)
      ..bytes(body);
    return out.take();
  }
}
