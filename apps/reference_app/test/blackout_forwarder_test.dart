/// The blackout v2 forwarder against a fake hub: plan parsing, chunk
/// splitting, and resume-from-the-first-missing-chunk.
library;

import 'dart:convert';
import 'dart:math';

import 'package:device_link/device_link.dart' show LinkMessagePriority;
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/blackout_forwarder.dart';

/// A hub that remembers what it holds and can be told to fail one chunk.
class _FakeHub implements BlackoutTransport {
  _FakeHub({List<int> held = const [], this.failAtIdx, this.haveFails = false})
    : held = held.toSet();

  final Set<int> held;
  final int? failAtIdx;
  final bool haveFails;
  final List<int> postedIdx = <int>[];
  final List<List<int>> wholePosts = <List<int>>[];
  int? seenN;
  String? seenSha;

  @override
  Future<bool> postWhole(String id, List<int> envelope) async {
    wholePosts.add(envelope);
    return true;
  }

  @override
  Future<List<int>?> have(String id) async => haveFails ? null : held.toList();

  @override
  Future<ChunkReply> postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  }) async {
    if (idx == failAtIdx) return ChunkReply.failed;
    seenN = n;
    seenSha = sha256;
    postedIdx.add(idx);
    held.add(idx);
    final complete = held.where((i) => i >= 0 && i < n).length == n;
    return complete ? ChunkReply.complete : ChunkReply.stored;
  }
}

void main() {
  final job = <String, Object?>{
    'v': 2,
    'plan': [
      {'kind': 'text', 'bytes': 200, 'n': 8},
      {'kind': 'voice', 'bytes': 5000, 'n': 6},
      {'kind': 'photo', 'bytes': 45000, 'n': 4},
      {'kind': 'video', 'bytes': 100000, 'n': 2},
    ],
    'probe_s': 2,
    'lifetime_s': 21600,
    'chunk_bytes': 8192,
  };

  group('BlackoutPlan.parse', () {
    test('expands the job plan into 20 bundles with the right priorities', () {
      final plan = BlackoutPlan.parse(job)!;
      expect(plan.items.length, 20);
      expect(plan.bytesTotal, 8 * 200 + 6 * 5000 + 4 * 45000 + 2 * 100000);
      expect(plan.probeS, 2);
      expect(plan.lifetimeS, 21600);
      expect(plan.chunkBytes, 8192);
      expect(
        plan.items.where((i) => i.kind == 'text').map((i) => i.priority),
        everyElement(LinkMessagePriority.presence),
      );
      expect(
        plan.items.where((i) => i.kind != 'text').map((i) => i.priority),
        everyElement(LinkMessagePriority.bulk),
      );
      expect(plan.items.first.seq, 0);
      expect(plan.items[7].seq, 7);
      expect(plan.items[8].seq, 0);
    });

    test('a v1 block is not a plan', () {
      expect(BlackoutPlan.parse({'bytes': 1024, 'probe_s': 20}), isNull);
      expect(BlackoutPlan.parse({'v': 1, 'plan': []}), isNull);
    });

    test('bad entries are skipped and missing knobs take defaults', () {
      final plan = BlackoutPlan.parse({
        'v': 2,
        'plan': [
          {'kind': 'text', 'bytes': 0, 'n': 3},
          {'kind': '', 'bytes': 10},
          'junk',
          {'kind': 'voice', 'bytes': 10},
        ],
      })!;
      expect(plan.items.map((i) => i.toString()), ['voice#0(10B)']);
      expect(plan.probeS, 2);
      expect(plan.lifetimeS, 21600);
      expect(plan.chunkBytes, 8192);
    });
  });

  group('payload and envelope', () {
    test('the payload is exactly the planned size with a JSON header', () {
      const item = BlackoutPlanItem(kind: 'photo', bytes: 300, seq: 2);
      final payload = blackoutPayload(
        run: 'r1',
        item: item,
        createdMs: 5,
        random: Random(1),
      );
      expect(payload.length, 300);
      final headerEnd = payload.indexOf('}'.codeUnitAt(0)) + 1;
      final header =
          jsonDecode(utf8.decode(payload.sublist(0, headerEnd)))
              as Map<String, Object?>;
      expect(header, {
        'run': 'r1',
        'kind': 'photo',
        'seq': 2,
        'created_ms': 5,
        'bytes': 300,
      });
    });

    test('a payload smaller than its header is truncated to size', () {
      const item = BlackoutPlanItem(kind: 'text', bytes: 8, seq: 0);
      expect(
        blackoutPayload(
          run: 'r1',
          item: item,
          createdMs: 5,
          random: Random(1),
        ).length,
        8,
      );
    });

    test('the envelope is the v1 JSON shape', () {
      final envelope = buildBlackoutEnvelope(
        run: 'r1',
        id: 'abc',
        createdMs: 7,
        payload: [1, 2, 3],
        signature: [9, 9],
        pubkeyB64: 'PK',
      );
      final decoded = jsonDecode(utf8.decode(envelope)) as Map<String, Object?>;
      expect(decoded, {
        'run': 'r1',
        'id': 'abc',
        'created_ms': 7,
        'payload': base64Encode([1, 2, 3]),
        'sig': base64Encode([9, 9]),
        'pubkey': 'PK',
      });
    });
  });

  group('splitChunks', () {
    test('cuts into full chunks plus a remainder', () {
      final chunks = splitChunks(List<int>.generate(25, (i) => i), 10);
      expect(chunks.map((c) => c.length), [10, 10, 5]);
      expect(chunks[2], [20, 21, 22, 23, 24]);
    });

    test('an exact multiple has no empty tail; empty input has no chunks', () {
      expect(splitChunks(List<int>.filled(20, 0), 10).length, 2);
      expect(splitChunks(const [], 10), isEmpty);
    });

    test('rejects a non-positive chunk size', () {
      expect(() => splitChunks([1], 0), throwsArgumentError);
    });
  });

  group('BlackoutForwarder.forward', () {
    final envelope = List<int>.generate(45, (i) => i);

    test('a small envelope goes as one whole POST', () async {
      final hub = _FakeHub();
      final forwarder = BlackoutForwarder(hub, chunkBytes: 100);
      expect(
        await forwarder.forward(id: 'a', envelope: envelope, sha256: 's'),
        isTrue,
      );
      expect(hub.wholePosts, [envelope]);
      expect(hub.postedIdx, isEmpty);
      expect(forwarder.lastChunksPosted, 0);
    });

    test(
      'posts only the missing chunks, in index order, until complete',
      () async {
        final hub = _FakeHub(held: [0, 2]);
        final forwarder = BlackoutForwarder(hub, chunkBytes: 10);
        expect(
          await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
          isTrue,
        );
        expect(hub.postedIdx, [1, 3, 4]);
        expect(hub.seenN, 5);
        expect(hub.seenSha, 'sha');
        expect(hub.wholePosts, isEmpty);
        expect(forwarder.lastChunksPosted, 3);
      },
    );

    test(
      'a failure mid-transfer returns false and keeps the progress',
      () async {
        final hub = _FakeHub(failAtIdx: 3);
        final forwarder = BlackoutForwarder(hub, chunkBytes: 10);
        expect(
          await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
          isFalse,
        );
        expect(hub.postedIdx, [0, 1, 2]);
        expect(forwarder.lastChunksPosted, 3);
        expect(hub.held, {0, 1, 2});
      },
    );

    test('the next window resumes from the first missing chunk', () async {
      final first = _FakeHub(failAtIdx: 3);
      await BlackoutForwarder(
        first,
        chunkBytes: 10,
      ).forward(id: 'a', envelope: envelope, sha256: 'sha');
      // Same hub state, the link is back: only 3 and 4 travel.
      final second = _FakeHub(held: first.held.toList());
      final forwarder = BlackoutForwarder(second, chunkBytes: 10);
      expect(
        await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
        isTrue,
      );
      expect(second.postedIdx, [3, 4]);
    });

    test('an unreachable /have returns false without posting', () async {
      final hub = _FakeHub(haveFails: true);
      final forwarder = BlackoutForwarder(hub, chunkBytes: 10);
      expect(
        await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
        isFalse,
      );
      expect(hub.postedIdx, isEmpty);
    });

    test('a hub that already holds everything is asked once more for the '
        'completion reply', () async {
      final hub = _FakeHub(held: [0, 1, 2, 3, 4]);
      final forwarder = BlackoutForwarder(hub, chunkBytes: 10);
      expect(
        await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
        isTrue,
      );
      expect(hub.postedIdx, [4]);
    });

    test('indexes outside [0, n) in /have are ignored', () async {
      final hub = _FakeHub(held: [-1, 7, 99]);
      final forwarder = BlackoutForwarder(hub, chunkBytes: 10);
      expect(
        await forwarder.forward(id: 'a', envelope: envelope, sha256: 'sha'),
        isTrue,
      );
      expect(hub.postedIdx, [0, 1, 2, 3, 4]);
    });

    test('rejects a non-positive chunk size', () {
      expect(
        () => BlackoutForwarder(_FakeHub(), chunkBytes: 0),
        throwsArgumentError,
      );
    });
  });
}
