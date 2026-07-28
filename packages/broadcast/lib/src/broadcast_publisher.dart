/// The publishing side: turn content into one signed post and its
/// objects.
library;

import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'broadcast_address.dart';
import 'broadcast_descriptor.dart';
import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'broadcast_relay.dart';
import 'layer_hash_list.dart';
import 'publishing_key_certificate.dart';

/// A complete post: the descriptor, and every object it commits to.
class BroadcastPost {
  const BroadcastPost({
    required this.descriptor,
    required this.objects,
    this.mediaHashList,
  });

  final BroadcastDescriptor descriptor;

  /// Every object this post commits to, keyed by content hash — the
  /// layer payloads, the media hash list if present, and each media
  /// chunk.
  final Map<String, Uint8List> objects;

  /// The chunk index for the media layer, when the post has one.
  final LayerHashList? mediaHashList;

  int get seq => descriptor.seq;

  DescriptorAddress get address =>
      DescriptorAddress(authorId: descriptor.authorId, seq: descriptor.seq);

  /// Total bytes a reader must fetch to hold this post completely.
  int get totalBytes =>
      descriptor.encoded.length +
      objects.values.fold(0, (sum, bytes) => sum + bytes.length);
}

/// Signs posts for one author, keeping the sequence and links consistent.
class BroadcastPublisher {
  BroadcastPublisher({
    required this.rootPublicKey,
    required BroadcastSigner publishingSigner,
    required this.certificate,
    int nextSeq = 0,
    Uint8List? prev,
  }) : _publishingSigner = publishingSigner,
       _nextSeq = nextSeq,
       _prev = prev ?? zeroHash {
    if (nextSeq == 0 && !bytesEqual(_prev, zeroHash)) {
      throw ArgumentError.value(prev, 'prev', 'genesis has no predecessor');
    }
    if (nextSeq != 0 && bytesEqual(_prev, zeroHash)) {
      throw ArgumentError.value(
        prev,
        'prev',
        'resuming at $nextSeq needs the hash of $nextSeq - 1',
      );
    }
  }

  /// Create a publisher with a fresh short-lived publishing key,
  /// delegated by [rootSigner].
  ///
  /// [validity] is the compromise bound: if the publishing device is
  /// lost, an attacker can sign as this author until the certificate
  /// expires and no longer. A week is short enough to matter and long
  /// enough that renewal is not a chore.
  static Future<BroadcastPublisher> create({
    required BroadcastSigner rootSigner,
    Duration validity = const Duration(days: 7),
  }) async {
    if (validity > maxCertificateValidity) {
      throw ArgumentError.value(
        validity,
        'validity',
        'readers refuse a window longer than $maxCertificateValidity',
      );
    }
    final publishing = await CryptographyBroadcastSigner.generate();
    final now = clock.now().toUtc();
    final certificate = await PublishingKeyCertificate.issue(
      rootSigner: rootSigner,
      publishingKey: publishing.publicKey,
      notBefore: now,
      notAfter: now.add(validity),
    );
    return BroadcastPublisher(
      rootPublicKey: rootSigner.publicKey,
      publishingSigner: publishing,
      certificate: certificate,
    );
  }

  /// The author's long-lived key. This is the identity; the publishing
  /// key is an implementation detail that rotates under it.
  final Uint8List rootPublicKey;

  /// The delegation currently in force.
  final PublishingKeyCertificate certificate;

  final BroadcastSigner _publishingSigner;
  int _nextSeq;
  Uint8List _prev;

  Uint8List get authorId => authorIdFor(rootPublicKey);

  /// Sequence number the next post will take.
  int get nextSeq => _nextSeq;

  /// Build and sign the next post.
  ///
  /// At least one layer is required — a post that commits to nothing is
  /// a signature with no subject, and the format has no way to express
  /// it.
  Future<BroadcastPost> publish({
    Uint8List? text,
    Uint8List? still,
    Uint8List? voice,
    Uint8List? media,
    Uint8List? retracts,
    int mediaChunkSize = 64 * 1024,
    DateTime? at,
  }) async {
    if (text == null && still == null && voice == null && media == null) {
      throw ArgumentError('a post needs at least one layer');
    }

    final objects = <String, Uint8List>{};
    final layers = <int, Uint8List>{};

    void addDirect(int flag, Uint8List? bytes) {
      if (bytes == null) return;
      if (bytes.isEmpty) {
        throw ArgumentError.value(
          bytes,
          'layer',
          'an empty layer is not a layer',
        );
      }
      final hash = contentHash(bytes);
      layers[flag] = hash;
      objects[hexEncode(hash)] = Uint8List.fromList(bytes);
    }

    addDirect(LayerFlag.text, text);
    addDirect(LayerFlag.still, still);
    addDirect(LayerFlag.voice, voice);

    LayerHashList? hashList;
    if (media != null) {
      hashList = LayerHashList.build(media, chunkSize: mediaChunkSize);
      layers[LayerFlag.mediaList] = hashList.hash;
      objects[hexEncode(hashList.hash)] = hashList.encoded;
      for (var i = 0; i < hashList.chunkCount; i++) {
        final chunk = hashList.chunkOf(media, i);
        objects[hexEncode(hashList.hashes[i])] = chunk;
      }
    }

    final descriptor = await BroadcastDescriptor.sign(
      signer: _publishingSigner,
      authorId: authorId,
      seq: _nextSeq,
      publishedAt: at?.toUtc() ?? clock.now().toUtc(),
      prev: _prev,
      layers: layers,
      retracts: retracts,
    );

    _nextSeq += 1;
    _prev = descriptor.id;

    return BroadcastPost(
      descriptor: descriptor,
      objects: Map.unmodifiable(objects),
      mediaHashList: hashList,
    );
  }

  /// Withdraw an earlier post, saying why.
  ///
  /// A correction is the most consequential thing a trusted voice does in
  /// a crisis, and it is the one thing the format made no room for: the
  /// only alternative was another post that a reader might never connect
  /// to the first. Here the link is inside the signature, so anyone
  /// holding both knows the original no longer stands.
  ///
  /// [reason] is required and becomes the new post's text. A withdrawal
  /// with nothing said is worse than none — it removes a claim without
  /// replacing it, and leaves a reader unable to tell a correction from a
  /// deletion.
  Future<BroadcastPost> retract(
    BroadcastDescriptor post, {
    required Uint8List reason,
    DateTime? at,
  }) {
    if (reason.isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'say why it is withdrawn');
    }
    if (!bytesEqual(post.authorId, authorId)) {
      throw ArgumentError.value(
        post,
        'post',
        'an author may only withdraw their own post',
      );
    }
    return publish(text: reason, retracts: post.id, at: at);
  }

  /// Write [post] to [relay].
  ///
  /// Objects go first, then the descriptor. That order matters: the
  /// descriptor is what makes a post discoverable, so publishing it last
  /// means a reader never learns about a post whose layers are not yet
  /// there to fetch.
  Future<void> pushTo(BroadcastRelay relay, BroadcastPost post) async {
    for (final bytes in post.objects.values) {
      await relay.putObject(bytes);
    }
    await relay.putDescriptor(post.address, post.descriptor.encoded);
  }
}
