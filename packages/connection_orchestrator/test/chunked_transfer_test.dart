import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _FlakyChannel implements TransportChannel {
  _FlakyChannel(this.name);

  @override
  final String name;

  bool up = true;
  int failAfterSends = 1 << 30;
  int sends = 0;
  final delivered = <String, List<int>>{};
  List<int>? lastPayload;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async => up;

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    if (!up || sends > failAfterSends) {
      return const SendResult(SendStatus.transient);
    }
    lastPayload = payload;
    return const SendResult(SendStatus.ok, rttMs: 20);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('ChunkId', () {
    test('round-trips through encode/decode', () {
      final id = ChunkId.decode(const ChunkId('photo-1', 3, 10).encode());
      expect((id!.transferId, id.index, id.total), ('photo-1', 3, 10));
    });

    test('rejects malformed and out-of-range ids', () {
      expect(ChunkId.decode('plain-bundle'), isNull);
      expect(ChunkId.decode('t#5/5'), isNull); // index == total
      expect(ChunkId.decode('t#0/0'), isNull);
    });
  });

  group('ResumableTransfer', () {
    test('splits, tracks progress, resumes only the remainder', () {
      final payload = List.generate(10 * 1024, (i) => i % 251);
      final t = ResumableTransfer(
        transferId: 'file',
        payload: payload,
        chunkSize: 3 * 1024,
      );
      expect(t.totalChunks, 4);
      t.markDelivered(0);
      t.markDelivered(2);
      final remaining = t.remainingChunks();
      expect(remaining.map((c) => c.id.index), [1, 3]);
      expect(t.progress, 0.5);
      expect(t.complete, isFalse);
      t.markDelivered(1);
      t.markDelivered(3);
      expect(t.complete, isTrue);
    });

    test('progress survives serialize/restore', () {
      final t = ResumableTransfer(
        transferId: 'file',
        payload: List.filled(100, 1),
        chunkSize: 10,
      )..markDelivered(4);
      final reborn = ResumableTransfer(
        transferId: 'file',
        payload: List.filled(100, 1),
        chunkSize: 10,
      )..restore(t.toJson());
      expect(
        reborn.remainingChunks().map((c) => c.id.index),
        isNot(contains(4)),
      );
    });
  });

  group('ChunkReassembler', () {
    test('reassembles out-of-order chunks exactly once', () {
      final r = ChunkReassembler();
      expect(r.accept('t#1/3', [4, 5]), isNull);
      expect(r.accept('t#0/3', [1, 2, 3]), isNull);
      expect(r.accept('t#1/3', [4, 5]), isNull); // duplicate is idempotent
      expect(r.accept('t#2/3', [6]), [1, 2, 3, 4, 5, 6]);
    });

    test('ignores plain bundle ids', () {
      expect(ChunkReassembler().accept('hello', [1]), isNull);
    });
  });

  group('ConnectionFabric.deliverChunked', () {
    test('mid-transfer lane death queues only the remainder, then resumes '
        'without re-sending delivered bytes', () async {
      var clockMs = 0;
      final queue = DtnBundleQueue();
      final fabric = ConnectionFabric(
        fallbackQueue: queue,
        nowMs: () => clockMs,
      );
      final lane = _FlakyChannel('net');
      fabric.registerLane(
        lane,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      lane.failAfterSends = 2; // chunks 0,1 make it, the rest fail

      final payload = List.generate(5 * 1024, (i) => i % 256);
      final transfer = await fabric.deliverChunked(
        payload,
        transferId: 'photo',
        chunkSize: 1024,
      );

      expect(transfer.totalChunks, 5);
      expect(transfer.deliveredChunks, 2);
      expect(
        queue.pendingCount,
        3 + transfer.totalParityChunks,
        reason: 'missing data chunks + parity chunks queued, nothing more',
      );

      // Lane recovers; resuming re-sends exactly the remainder.
      lane.failAfterSends = 1 << 30;
      final resumed = await fabric.deliverChunked(
        payload,
        transferId: 'photo',
        chunkSize: 1024,
        resume: transfer,
      );
      expect(resumed.complete, isTrue);
      await fabric.dispose();
    });

    test('a chunk lost in transit is healed from parity — no retransmit', () {
      final payload = List.generate(4096, (i) => (i * 31 + 5) % 256);
      final transfer = ResumableTransfer(
        transferId: 'healed',
        payload: payload,
        chunkSize: 1000, // 5 chunks: 4 full + short tail (96 bytes)
      );
      final r = ChunkReassembler();
      List<int>? whole;
      // Drop the LAST (short) data chunk — the hardest healing case —
      // and feed everything else plus parity.
      for (final c in transfer.remainingChunks()) {
        if (c.id.index == 4) continue;
        whole = r.accept(c.id.encode(), c.payload) ?? whole;
      }
      for (final p in transfer.remainingParityChunks()) {
        whole = r.accept(p.id.encode(), p.payload) ?? whole;
      }
      expect(whole, payload, reason: 'tail chunk rebuilt to exact length');
    });

    test('chunk size adapts to link quality', () {
      expect(adaptiveChunkSize(linkScore: 0), 2 * 1024);
      expect(adaptiveChunkSize(linkScore: 1), 64 * 1024);
      expect(
        adaptiveChunkSize(linkScore: 0.5),
        inInclusiveRange(2 * 1024, 64 * 1024),
      );
    });

    test('refresh self-resumes an in-flight transfer to completion', () async {
      var clockMs = 0;
      final queue = DtnBundleQueue();
      final fabric = ConnectionFabric(
        fallbackQueue: queue,
        nowMs: () => clockMs,
      );
      final lane = _FlakyChannel('net');
      fabric.registerLane(
        lane,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      lane.failAfterSends = 1;

      final payload = List.generate(3 * 1024, (i) => i % 256);
      final transfer = await fabric.deliverChunked(
        payload,
        transferId: 'auto',
        chunkSize: 1024,
      );
      expect(transfer.complete, isFalse);

      lane.failAfterSends = 1 << 30; // link recovers
      await fabric.refresh(); // NO caller re-drive — refresh resumes it
      expect(transfer.complete, isTrue, reason: 'self-resumed on recovery');
      await fabric.dispose();
    });

    test('receiver reassembles a chunked delivery end-to-end', () async {
      var clockMs = 0;
      final fabric = ConnectionFabric(
        fallbackQueue: DtnBundleQueue(),
        nowMs: () => clockMs,
      );
      final lane = _FlakyChannel('net');
      fabric.registerLane(
        lane,
        const LaneProfile(id: 'net', kind: LaneKind.internet),
      );
      final reassembler = ChunkReassembler();
      final payload = List.generate(2500, (i) => i % 256);

      List<int>? whole;
      final transfer = ResumableTransfer(
        transferId: 'note',
        payload: payload,
        chunkSize: 1000,
      );
      for (final chunk in transfer.remainingChunks()) {
        await fabric.deliver(chunk.payload, bundleId: chunk.id.encode());
        whole =
            reassembler.accept(chunk.id.encode(), lane.lastPayload!) ?? whole;
      }
      expect(whole, payload);
      await fabric.dispose();
    });
  });
}
