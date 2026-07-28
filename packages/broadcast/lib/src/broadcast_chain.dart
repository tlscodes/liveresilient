/// One author's chain of descriptors, and the fork detector on top of it.
///
/// The chain is the only place where a post becomes *this author's* post
/// rather than merely a validly signed record. It holds one contiguous
/// window and grows at either end: forward as new posts arrive, backward
/// as a late reader walks the `prev` links to recover history from any
/// relay that still has it.
///
/// The property worth the code: a publishing key used in two places
/// cannot stay quiet. Two different descriptors at one sequence number,
/// both correctly signed, are a self-contained proof of compromise that
/// any reader detects locally and can hand to anyone else.
library;

import 'dart:typed_data';

import 'broadcast_descriptor.dart';
import 'broadcast_ids.dart';

/// What happened when a descriptor was offered to a chain.
enum ChainOutcome {
  /// Linked into the window, at either end.
  accepted,

  /// Byte-identical to one already held. Expected: readers pull the same
  /// post from several relays on purpose.
  duplicate,

  /// A different descriptor at a sequence number already held. The chain
  /// is now known-compromised; see [ChainResult.fork].
  fork,

  /// Valid in isolation but not adjacent to the window, so it cannot be
  /// linked yet. The reader should fetch the descriptors in between.
  notAdjacent,

  /// Adjacent by sequence number but its hash link does not match.
  brokenLink,

  /// Adjacent and linked, but dated before the post it follows.
  timeWentBackwards,

  /// Belongs to a different author.
  wrongAuthor,
}

/// Two conflicting descriptors at one sequence number.
///
/// Self-contained: anyone holding the author's root key and the
/// publishing certificate can check this without trusting whoever passed
/// it along.
class ForkEvidence {
  const ForkEvidence({required this.held, required this.offered});

  /// The descriptor the chain already had.
  final BroadcastDescriptor held;

  /// The conflicting one that arrived later.
  final BroadcastDescriptor offered;

  int get seq => held.seq;

  Uint8List get authorId => held.authorId;
}

/// The result of offering one descriptor.
class ChainResult {
  const ChainResult(this.outcome, {this.fork});

  final ChainOutcome outcome;

  /// Present exactly when [outcome] is [ChainOutcome.fork].
  final ForkEvidence? fork;

  bool get isAccepted => outcome == ChainOutcome.accepted;
}

/// A contiguous, link-verified window of one author's posts.
class BroadcastChain {
  BroadcastChain({required Uint8List authorId, this.maxRetained = 4096})
    : authorId = Uint8List.fromList(authorId) {
    if (authorId.length != authorIdBytes) {
      throw ArgumentError.value(
        authorId.length,
        'authorId.length',
        'must be $authorIdBytes bytes',
      );
    }
    if (maxRetained < 2) {
      throw ArgumentError.value(
        maxRetained,
        'maxRetained',
        'a window needs room for at least two posts to link them',
      );
    }
  }

  /// How many posts the window keeps before dropping its oldest.
  ///
  /// A chain is unbounded by design; a reader's memory is not. Anyone able
  /// to sign as this author can otherwise make a polling reader retain
  /// every post it is handed. Dropping from the old end is the right end
  /// to drop from: the newest post is the one a reader is following, and
  /// history can always be walked again from a relay that still has it.
  final int maxRetained;

  /// The author this chain tracks.
  final Uint8List authorId;

  final Map<int, BroadcastDescriptor> _bySeq = {};

  /// Proof of compromise, once seen. Sticky: a chain that has forked
  /// stays forked, because the damage is not undone by later good posts.
  ForkEvidence? _fork;

  /// The fork proof, if this chain has ever seen one.
  ForkEvidence? get fork => _fork;

  bool get hasForked => _fork != null;

  bool get isEmpty => _bySeq.isEmpty;

  int get length => _bySeq.length;

  int? _lowest;
  int? _highest;

  /// Lowest sequence number held, or null when empty.
  int? get lowestSeq => _lowest;

  /// Highest sequence number held, or null when empty.
  int? get highestSeq => _highest;

  /// The newest post held.
  BroadcastDescriptor? get head => _highest == null ? null : _bySeq[_highest!];

  /// The post at [seq], if held.
  BroadcastDescriptor? at(int seq) => _bySeq[seq];

  /// Every post held, oldest first.
  List<BroadcastDescriptor> get posts {
    final keys = _bySeq.keys.toList()..sort();
    return List.unmodifiable([for (final k in keys) _bySeq[k]!]);
  }

  /// Offer a descriptor whose signature has already been verified.
  ///
  /// This deliberately does no crypto. Signature and certificate
  /// checking belong to the reader; the chain's job is the structural
  /// argument — position, linkage, ordering, and conflict — which is
  /// exactly what a signature cannot tell you.
  ChainResult offer(BroadcastDescriptor descriptor) {
    if (!bytesEqual(descriptor.authorId, authorId)) {
      return const ChainResult(ChainOutcome.wrongAuthor);
    }

    final existing = _bySeq[descriptor.seq];
    if (existing != null) {
      if (bytesEqual(existing.id, descriptor.id)) {
        return const ChainResult(ChainOutcome.duplicate);
      }
      final evidence = ForkEvidence(held: existing, offered: descriptor);
      _fork ??= evidence;
      return ChainResult(ChainOutcome.fork, fork: evidence);
    }

    if (_bySeq.isEmpty) {
      _bySeq[descriptor.seq] = descriptor;
      _lowest = descriptor.seq;
      _highest = descriptor.seq;
      return const ChainResult(ChainOutcome.accepted);
    }

    final low = _lowest!;
    final high = _highest!;

    if (descriptor.seq == high + 1) {
      final tip = _bySeq[high]!;
      if (!bytesEqual(descriptor.prev, tip.id)) {
        return const ChainResult(ChainOutcome.brokenLink);
      }
      if (descriptor.publishedAt.isBefore(tip.publishedAt)) {
        return const ChainResult(ChainOutcome.timeWentBackwards);
      }
      _bySeq[descriptor.seq] = descriptor;
      _highest = descriptor.seq;
      _trimOldest();
      return const ChainResult(ChainOutcome.accepted);
    }

    if (descriptor.seq == low - 1) {
      final oldest = _bySeq[low]!;
      if (!bytesEqual(oldest.prev, descriptor.id)) {
        return const ChainResult(ChainOutcome.brokenLink);
      }
      if (oldest.publishedAt.isBefore(descriptor.publishedAt)) {
        return const ChainResult(ChainOutcome.timeWentBackwards);
      }
      _bySeq[descriptor.seq] = descriptor;
      _lowest = descriptor.seq;
      // Deliberately no trim here: a reader walking backwards is asking
      // for exactly these posts, and dropping them as they arrive would
      // make the walk never finish. A backfill past the ceiling instead
      // grows the window, which is the caller's own doing and bounded by
      // how far it chooses to walk.
      return const ChainResult(ChainOutcome.accepted);
    }

    return const ChainResult(ChainOutcome.notAdjacent);
  }

  /// Drops from the old end until the window fits [maxRetained].
  void _trimOldest() {
    while (_bySeq.length > maxRetained) {
      final oldest = _lowest!;
      _bySeq.remove(oldest);
      _lowest = oldest + 1;
    }
  }
}
