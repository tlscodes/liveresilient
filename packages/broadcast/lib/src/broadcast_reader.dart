/// The reading side: pull by name, verify before anything else, and
/// never hand unverified bytes upward.
///
/// The reader is deliberately pull-only. Nothing is delivered to a
/// reader who did not ask for it, which is why this design has no spam
/// problem to solve and no recipient list to leak: an author's reach is
/// the set of people who chose to follow their key.
library;

import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'broadcast_address.dart';
import 'broadcast_chain.dart';
import 'broadcast_descriptor.dart';
import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'broadcast_relay.dart';
import 'layer_hash_list.dart';
import 'publishing_key_certificate.dart';

/// Why a reader refused something it fetched.
enum ReadRejection {
  /// The bytes are not a descriptor this build can parse.
  malformedDescriptor,

  /// Longer than any descriptor can be, so refused before parsing.
  oversizeDescriptor,

  /// A correctly signed descriptor, but not the one that was asked for.
  ///
  /// A relay answering one address with another author's-own post is not
  /// a forgery, so every signature check passes; only comparing the
  /// sequence number catches it.
  wrongSequence,

  /// Offered as the next post, but dated far enough in the past that the
  /// delegation covering it has long since expired.
  ///
  /// History may be old. A new head may not, or an expired publishing key
  /// could keep speaking for the author forever by backdating.
  staleHeadExtension,

  /// Parsed, but not signed by any publishing key this author delegated
  /// to during the window the post claims.
  unverifiedSignature,

  /// No adopted certificate covers the post's declared time.
  noCertificateForTime,

  /// Dated far enough in the future to be a claim on sequence numbers
  /// rather than a publication.
  timeTooFarAhead,

  /// Structurally valid but rejected by the chain; see the outcome.
  chainRefused,
}

/// What a fetch produced.
enum ReadOutcome {
  /// Verified, linked into the chain, safe to show.
  delivered,

  /// No relay had it. For the next sequence number this is the normal
  /// answer, and means "not published yet".
  notAvailable,

  /// Something answered, and it did not survive verification.
  rejected,

  /// A conflicting post at this sequence number. The author's publishing
  /// key is compromised and this result carries the proof.
  fork,
}

/// The result of one fetch.
class ReadResult {
  const ReadResult._(
    this.outcome, {
    this.descriptor,
    this.fork,
    this.relayName,
    this.rejection,
    this.chainOutcome,
  });

  const ReadResult.delivered(BroadcastDescriptor descriptor, String relayName)
    : this._(
        ReadOutcome.delivered,
        descriptor: descriptor,
        relayName: relayName,
      );

  const ReadResult.notAvailable() : this._(ReadOutcome.notAvailable);

  const ReadResult.rejected(ReadRejection rejection, {ChainOutcome? chain})
    : this._(ReadOutcome.rejected, rejection: rejection, chainOutcome: chain);

  const ReadResult.forked(ForkEvidence fork)
    : this._(ReadOutcome.fork, fork: fork);

  final ReadOutcome outcome;
  final BroadcastDescriptor? descriptor;
  final ForkEvidence? fork;
  final String? relayName;
  final ReadRejection? rejection;
  final ChainOutcome? chainOutcome;

  bool get isDelivered => outcome == ReadOutcome.delivered;
}

/// Follows one author across any number of interchangeable relays.
class BroadcastReader {
  BroadcastReader({
    required this.rootPublicKey,
    required List<BroadcastRelay> relays,
    this.verifier = const CryptographyBroadcastVerifier(),
    this.maxClockSkew = const Duration(days: 1),
    this.maxHeadAge = const Duration(days: 30),
    this.maxLayerBytes = 8 * 1024 * 1024,
    this.maxRetainedPosts = 4096,
  }) : _relays = List.unmodifiable(relays),
       chain = BroadcastChain(
         authorId: authorIdFor(rootPublicKey),
         maxRetained: maxRetainedPosts,
       ) {
    if (relays.isEmpty) {
      throw ArgumentError.value(
        relays,
        'relays',
        'need somewhere to read from',
      );
    }
  }

  /// The author's long-lived identity key.
  final Uint8List rootPublicKey;

  final List<BroadcastRelay> _relays;
  final BroadcastVerifier verifier;

  /// How far ahead of local time a post may claim to be published.
  ///
  /// Without a bound, a compromised key could sign posts dated years out
  /// and occupy the sequence space ahead of the real author.
  final Duration maxClockSkew;

  /// How far behind local time a *new head* may be dated.
  ///
  /// This is what makes a publishing certificate's expiry mean anything.
  /// Certificates are checked against the time a post declares, so that an
  /// expired one still verifies the posts it covered — otherwise rotation
  /// would erase history. But that alone lets a stolen key keep appending
  /// forever, by dating each new post inside the long-dead window. Bounding
  /// how stale a post extending the chain may be closes that, while leaving
  /// history as walkable as it ever was: this applies only to a post
  /// offered as the next one, never to a backfill and never to the first
  /// post a reader anchors on.
  final Duration maxHeadAge;

  /// Descriptors held before the oldest are dropped.
  ///
  /// An author's chain is unbounded by design and a reader's memory is
  /// not. Without this, anyone able to sign as the author can make a
  /// polling reader retain every post it is fed.
  final int maxRetainedPosts;

  /// Ceiling on a single reassembled layer, so a hostile hash list
  /// cannot turn a reader into an allocation target.
  final int maxLayerBytes;

  /// This author's verified history.
  final BroadcastChain chain;

  final List<PublishingKeyCertificate> _certificates = [];

  /// Certificates adopted so far, oldest window first.
  List<PublishingKeyCertificate> get certificates =>
      List.unmodifiable(_certificates);

  /// Verify and adopt a publishing-key delegation.
  ///
  /// The validity window is checked here, but liveness is not: an
  /// expired certificate must keep verifying the posts it covered, or an
  /// author's history would become unreadable every time their key
  /// rotated. Liveness is enforced per post instead, against the time
  /// the post itself declares.
  Future<bool> adoptCertificate(Uint8List encoded) async {
    final now = clock.now().toUtc();
    // Verify at the certificate's own start instant so the signature and
    // window checks run while deliberately skipping the "is it live
    // now" test, which is not this method's question.
    final probe = PublishingKeyCertificate.parseWindowStart(encoded);
    if (probe == null) return false;
    final certificate = await PublishingKeyCertificate.verify(
      encoded: encoded,
      rootPublicKey: rootPublicKey,
      verifier: verifier,
      now: probe,
    );
    if (certificate == null) return false;
    if (certificate.notBefore.isAfter(now.add(maxClockSkew))) return false;
    if (_certificates.any(
      (held) => bytesEqual(held.encoded, certificate.encoded),
    )) {
      return true;
    }
    _certificates
      ..add(certificate)
      ..sort((a, b) => a.notBefore.compareTo(b.notBefore));
    return true;
  }

  /// Fetch the next post after the newest one held.
  Future<ReadResult> fetchNext() {
    final head = chain.highestSeq;
    if (head == maxSeq) {
      // The top of the sequence space is exhaustion, not an error — the
      // same answer the bottom gives in fetchPrevious.
      return Future.value(const ReadResult.notAvailable());
    }
    return fetchSeq(head == null ? 0 : head + 1);
  }

  /// Fetch the post immediately before the oldest one held, walking the
  /// chain backward to recover history.
  ///
  /// Returns [ReadOutcome.notAvailable] at genesis, since there is
  /// nothing earlier by construction.
  Future<ReadResult> fetchPrevious() {
    final low = chain.lowestSeq;
    if (low == null || low == 0)
      return Future.value(const ReadResult.notAvailable());
    return fetchSeq(low - 1);
  }

  /// Fetch one specific sequence number.
  ///
  /// Every relay is asked until one produces bytes that verify. A relay
  /// that answers with something invalid does not end the search — that
  /// is the whole point of reading from several.
  Future<ReadResult> fetchSeq(int seq) async {
    if (seq < 0 || seq > maxSeq) {
      throw RangeError.range(seq, 0, maxSeq, 'seq');
    }
    final address = DescriptorAddress(authorId: chain.authorId, seq: seq);

    ReadResult? lastRejection;
    for (final relay in _relays) {
      final Uint8List? encoded;
      try {
        encoded = await relay.fetchDescriptor(address);
      } on Object {
        // A relay that throws is a relay that is down. Try the next one.
        continue;
      }
      if (encoded == null) continue;

      final result = await _admit(encoded, relay.name, seq);
      if (result.outcome == ReadOutcome.delivered ||
          result.outcome == ReadOutcome.fork) {
        return result;
      }
      lastRejection = result;
    }
    return lastRejection ?? const ReadResult.notAvailable();
  }

  Future<ReadResult> _admit(
    Uint8List encoded,
    String relayName,
    int requestedSeq,
  ) async {
    // Bounded before parsing, and before anything is hashed or verified:
    // a descriptor's largest possible size is a compile-time constant, so
    // a relay answering with a gigabyte cannot make a reader hold it.
    if (encoded.length > descriptorSizeFor(LayerFlag.known)) {
      return const ReadResult.rejected(ReadRejection.oversizeDescriptor);
    }
    final parsed = BroadcastDescriptor.parse(encoded);
    if (parsed == null) {
      return const ReadResult.rejected(ReadRejection.malformedDescriptor);
    }
    // A relay may answer any address with any genuinely signed post by
    // this author. Every signature check would pass, so the only thing
    // that catches it is asking whether this is the post that was
    // requested.
    if (parsed.seq != requestedSeq) {
      return const ReadResult.rejected(ReadRejection.wrongSequence);
    }

    final now = clock.now().toUtc();
    if (parsed.publishedAt.isAfter(now.add(maxClockSkew))) {
      return const ReadResult.rejected(ReadRejection.timeTooFarAhead);
    }
    final head = chain.highestSeq;
    final extendsHead = head != null && parsed.seq == head + 1;
    if (extendsHead && now.difference(parsed.publishedAt) > maxHeadAge) {
      return const ReadResult.rejected(ReadRejection.staleHeadExtension);
    }

    final covering = _certificates
        .where((cert) => cert.isValidAt(parsed.publishedAt))
        .toList();
    if (covering.isEmpty) {
      return const ReadResult.rejected(ReadRejection.noCertificateForTime);
    }

    BroadcastDescriptor? verified;
    for (final cert in covering) {
      verified = await BroadcastDescriptor.verify(
        encoded: encoded,
        rootPublicKey: rootPublicKey,
        publishingKey: cert.publishingKey,
        verifier: verifier,
      );
      if (verified != null) break;
    }
    if (verified == null) {
      return const ReadResult.rejected(ReadRejection.unverifiedSignature);
    }

    final outcome = chain.offer(verified);
    switch (outcome.outcome) {
      case ChainOutcome.accepted:
      case ChainOutcome.duplicate:
        return ReadResult.delivered(verified, relayName);
      case ChainOutcome.fork:
        return ReadResult.forked(outcome.fork!);
      case ChainOutcome.notAdjacent:
      case ChainOutcome.brokenLink:
      case ChainOutcome.timeWentBackwards:
      case ChainOutcome.wrongAuthor:
        return ReadResult.rejected(
          ReadRejection.chainRefused,
          chain: outcome.outcome,
        );
    }
  }

  /// Fetch one directly-committed layer of [descriptor].
  ///
  /// Returns null when no relay has it, or when every copy offered
  /// failed its hash check. The caller cannot tell those apart on
  /// purpose: neither one produced bytes worth showing.
  Future<Uint8List?> fetchLayer(
    BroadcastDescriptor descriptor,
    int flag,
  ) async {
    final expected = descriptor.layer(flag);
    if (expected == null) return null;
    if (flag == LayerFlag.mediaList) {
      throw ArgumentError.value(
        flag,
        'flag',
        'the media layer is assembled by fetchMedia',
      );
    }
    return _fetchObject(expected);
  }

  /// Fetch and reassemble the chunked media layer of [descriptor].
  ///
  /// Every chunk is verified against the hash list before it is placed,
  /// and the list itself is verified against the descriptor, so a relay
  /// that serves one bad chunk cannot corrupt the result — it can only
  /// fail to contribute.
  Future<Uint8List?> fetchMedia(BroadcastDescriptor descriptor) async {
    final listHash = descriptor.layer(LayerFlag.mediaList);
    if (listHash == null) return null;
    final listBytes = await _fetchObject(listHash);
    if (listBytes == null) return null;
    final list = LayerHashList.parse(listBytes);
    if (list == null) return null;
    if (list.totalLength > maxLayerBytes) return null;

    final out = Uint8List(list.totalLength);
    for (var i = 0; i < list.chunkCount; i++) {
      final chunk = await _fetchObject(list.hashes[i]);
      if (chunk == null) return null;
      if (!list.verifyChunk(i, chunk)) return null;
      out.setRange(
        i * list.chunkSize,
        i * list.chunkSize + chunk.length,
        chunk,
      );
    }
    return out;
  }

  /// Ask every relay for the object named by [hash], returning the first
  /// copy whose bytes actually hash to it.
  Future<Uint8List?> _fetchObject(Uint8List hash) async {
    final address = ObjectAddress(hash);
    for (final relay in _relays) {
      final Uint8List? bytes;
      try {
        bytes = await relay.fetchObject(address);
      } on Object {
        continue;
      }
      if (bytes == null) continue;
      if (bytes.length > maxLayerBytes) continue;
      if (!bytesEqual(contentHash(bytes), hash)) continue;
      return bytes;
    }
    return null;
  }
}
