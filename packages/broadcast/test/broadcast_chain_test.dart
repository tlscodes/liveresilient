import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

Uint8List _hash(int fill) => Uint8List.fromList(List.filled(hashBytes, fill));

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishing;
  late Uint8List authorId;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishing = await CryptographyBroadcastSigner.generate();
    authorId = authorIdFor(root.publicKey);
  });

  Future<BroadcastDescriptor> post({
    required int seq,
    required Uint8List prev,
    DateTime? at,
    int fill = 1,
    BroadcastSigner? signer,
    Uint8List? author,
  }) => BroadcastDescriptor.sign(
    signer: signer ?? publishing,
    authorId: author ?? authorId,
    seq: seq,
    publishedAt: at ?? t0.add(Duration(minutes: seq)),
    prev: prev,
    layers: {LayerFlag.text: _hash(fill)},
  );

  /// Build a linked run of [count] posts starting at genesis.
  Future<List<BroadcastDescriptor>> run(int count) async {
    final out = <BroadcastDescriptor>[];
    var prev = zeroHash;
    for (var i = 0; i < count; i++) {
      final d = await post(seq: i, prev: prev);
      out.add(d);
      prev = d.id;
    }
    return out;
  }

  group('forward growth', () {
    test('accepts a linked run in order', () async {
      final chain = BroadcastChain(authorId: authorId);
      final posts = await run(4);
      for (final d in posts) {
        expect(chain.offer(d).outcome, ChainOutcome.accepted);
      }
      expect(chain.length, 4);
      expect(chain.lowestSeq, 0);
      expect(chain.highestSeq, 3);
      expect(chain.head!.seq, 3);
      expect(chain.hasForked, isFalse);
    });

    test('a re-offered post is a duplicate, not a fork', () async {
      // Readers pull the same post from several relays deliberately, so
      // this must be the quiet path.
      final chain = BroadcastChain(authorId: authorId);
      final posts = await run(2);
      chain.offer(posts[0]);
      chain.offer(posts[1]);
      expect(chain.offer(posts[1]).outcome, ChainOutcome.duplicate);
      expect(chain.length, 2);
      expect(chain.hasForked, isFalse);
    });

    test('refuses a post whose link does not match the tip', () async {
      final chain = BroadcastChain(authorId: authorId);
      final posts = await run(1);
      chain.offer(posts[0]);
      final wrongLink = await post(seq: 1, prev: _hash(0xAB));
      expect(chain.offer(wrongLink).outcome, ChainOutcome.brokenLink);
      expect(chain.length, 1);
    });

    test('refuses a post dated before the one it follows', () async {
      final chain = BroadcastChain(authorId: authorId);
      final genesis = await post(seq: 0, prev: zeroHash, at: t0);
      chain.offer(genesis);
      final backwards = await post(
        seq: 1,
        prev: genesis.id,
        at: t0.subtract(const Duration(hours: 1)),
      );
      expect(chain.offer(backwards).outcome, ChainOutcome.timeWentBackwards);
    });

    test('allows two posts at the same second', () async {
      final chain = BroadcastChain(authorId: authorId);
      final genesis = await post(seq: 0, prev: zeroHash, at: t0);
      chain.offer(genesis);
      final same = await post(seq: 1, prev: genesis.id, at: t0);
      expect(chain.offer(same).outcome, ChainOutcome.accepted);
    });

    test('refuses a post that skips a sequence number', () async {
      final chain = BroadcastChain(authorId: authorId);
      final posts = await run(3);
      chain.offer(posts[0]);
      expect(chain.offer(posts[2]).outcome, ChainOutcome.notAdjacent);
      expect(chain.highestSeq, 0);
      // Filling the gap makes it linkable again.
      expect(chain.offer(posts[1]).outcome, ChainOutcome.accepted);
      expect(chain.offer(posts[2]).outcome, ChainOutcome.accepted);
    });
  });

  group('backward growth', () {
    test('a late reader can walk history backward from any post', () async {
      // The recovery path that lets someone who just installed the app
      // rebuild an author's history from whatever relay still has it.
      final posts = await run(5);
      final chain = BroadcastChain(authorId: authorId);
      expect(chain.offer(posts[4]).outcome, ChainOutcome.accepted);
      for (final seq in [3, 2, 1, 0]) {
        expect(
          chain.offer(posts[seq]).outcome,
          ChainOutcome.accepted,
          reason: 'backfilling seq $seq',
        );
      }
      expect(chain.lowestSeq, 0);
      expect(chain.highestSeq, 4);
      expect(chain.posts.map((d) => d.seq), [0, 1, 2, 3, 4]);
    });

    test('refuses a backfill whose hash the held post does not name', () async {
      final posts = await run(3);
      final chain = BroadcastChain(authorId: authorId);
      chain.offer(posts[2]);
      final impostor = await post(seq: 1, prev: posts[0].id, fill: 0x77);
      expect(chain.offer(impostor).outcome, ChainOutcome.brokenLink);
    });

    test('refuses a backfill dated after the post it precedes', () async {
      final genesis = await post(seq: 0, prev: zeroHash, at: t0);
      final second = await post(
        seq: 1,
        prev: genesis.id,
        at: t0.subtract(const Duration(days: 1)),
      );
      // Offer the later-sequence post first, so the check runs on the
      // backfill path rather than the forward one.
      final chain = BroadcastChain(authorId: authorId);
      expect(chain.offer(second).outcome, ChainOutcome.accepted);
      expect(chain.offer(genesis).outcome, ChainOutcome.timeWentBackwards);
    });

    test('growth from the middle works in both directions', () async {
      final posts = await run(5);
      final chain = BroadcastChain(authorId: authorId);
      chain.offer(posts[2]);
      expect(chain.offer(posts[3]).outcome, ChainOutcome.accepted);
      expect(chain.offer(posts[1]).outcome, ChainOutcome.accepted);
      expect(chain.lowestSeq, 1);
      expect(chain.highestSeq, 3);
    });
  });

  group('fork detection', () {
    test('two different posts at one sequence number produce proof', () async {
      final genesis = await post(seq: 0, prev: zeroHash);
      final chain = BroadcastChain(authorId: authorId);
      chain.offer(genesis);

      // Same key, same slot, different content: this is what a
      // duplicated publishing key looks like from the outside.
      final conflicting = await post(seq: 0, prev: zeroHash, fill: 0x42);
      final result = chain.offer(conflicting);

      expect(result.outcome, ChainOutcome.fork);
      expect(result.fork, isNotNull);
      expect(result.fork!.seq, 0);
      expect(result.fork!.authorId, authorId);
      expect(bytesEqual(result.fork!.held.id, genesis.id), isTrue);
      expect(bytesEqual(result.fork!.offered.id, conflicting.id), isTrue);
    });

    test('the fork verdict is sticky', () async {
      final posts = await run(2);
      final chain = BroadcastChain(authorId: authorId);
      chain.offer(posts[0]);
      final conflicting = await post(seq: 0, prev: zeroHash, fill: 0x42);
      chain.offer(conflicting);
      expect(chain.hasForked, isTrue);
      // Later good posts do not undo the proof.
      expect(chain.offer(posts[1]).outcome, ChainOutcome.accepted);
      expect(chain.hasForked, isTrue);
      expect(chain.fork!.seq, 0);
    });

    test('the first fork seen is the one retained', () async {
      final genesis = await post(seq: 0, prev: zeroHash);
      final chain = BroadcastChain(authorId: authorId)..offer(genesis);
      final first = await post(seq: 0, prev: zeroHash, fill: 0x42);
      final second = await post(seq: 0, prev: zeroHash, fill: 0x43);
      chain.offer(first);
      chain.offer(second);
      expect(bytesEqual(chain.fork!.offered.id, first.id), isTrue);
    });

    test('a fork does not replace the post already held', () async {
      final genesis = await post(seq: 0, prev: zeroHash);
      final chain = BroadcastChain(authorId: authorId)..offer(genesis);
      final conflicting = await post(seq: 0, prev: zeroHash, fill: 0x42);
      chain.offer(conflicting);
      expect(bytesEqual(chain.at(0)!.id, genesis.id), isTrue);
    });
  });

  group('author binding', () {
    test('refuses a post belonging to another author', () async {
      final other = await CryptographyBroadcastSigner.generate();
      final foreign = await post(
        seq: 0,
        prev: zeroHash,
        author: authorIdFor(other.publicKey),
      );
      final chain = BroadcastChain(authorId: authorId);
      expect(chain.offer(foreign).outcome, ChainOutcome.wrongAuthor);
      expect(chain.isEmpty, isTrue);
    });

    test('refuses an author id of the wrong width', () {
      expect(() => BroadcastChain(authorId: Uint8List(7)), throwsArgumentError);
    });

    test('an empty chain reports no head and no bounds', () {
      final chain = BroadcastChain(authorId: authorId);
      expect(chain.head, isNull);
      expect(chain.lowestSeq, isNull);
      expect(chain.highestSeq, isNull);
      expect(chain.posts, isEmpty);
      expect(chain.at(0), isNull);
    });

    test('a chain may start anywhere, not only at genesis', () async {
      final posts = await run(3);
      final chain = BroadcastChain(authorId: authorId);
      expect(chain.offer(posts[2]).outcome, ChainOutcome.accepted);
      expect(chain.lowestSeq, 2);
    });
  });
}
