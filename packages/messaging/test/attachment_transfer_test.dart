import 'dart:async';
import 'dart:convert';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

Attachment att(String id, int size, {MediaKind kind = MediaKind.image}) =>
    Attachment(
      id: id,
      kind: kind,
      contentType: 'image/jpeg',
      bytes: List<int>.generate(size, (i) => i % 256),
    );

/// Loopback data channel for the end-to-end send/receive test.
class MemPort implements DataChannelPort {
  final _in = StreamController<List<int>>.broadcast();
  MemPort? peer;
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  Future<void> send(List<int> frame) async => peer?._in.add(frame);
  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

void main() {
  group('chunk + reassemble', () {
    test('splits by size and reassembles to the original bytes', () {
      final a = att('a1', 30000); // 30000 / 12288 = 3 chunks
      final chunks = AttachmentChunker.split(a, maxChunkBytes: 12288);
      expect(chunks.length, 3);
      expect(chunks.every((c) => c.total == 3), isTrue);

      final asm = AttachmentReassembler();
      Attachment? done;
      for (final c in chunks) {
        done = asm.accept(c) ?? done;
      }
      expect(done, isNotNull);
      expect(done!.bytes, a.bytes);
      expect(done.contentType, 'image/jpeg');
      expect(done.kind, MediaKind.image);
    });

    test('reassembles out-of-order and ignores duplicate chunks', () {
      final a = att('a2', 25000);
      final chunks = AttachmentChunker.split(a, maxChunkBytes: 10000);
      final asm = AttachmentReassembler();

      // feed reversed, with a duplicate first chunk in the middle
      final order = [...chunks.reversed, chunks.first];
      Attachment? done;
      for (final c in order) {
        done = asm.accept(c) ?? done;
      }
      expect(done, isNotNull);
      expect(done!.bytes, a.bytes);
    });

    test('empty attachment yields one chunk and reassembles empty', () {
      final a = att('a3', 0);
      final chunks = AttachmentChunker.split(a);
      expect(chunks.length, 1);
      final done = AttachmentReassembler().accept(chunks.single);
      expect(done, isNotNull);
      expect(done!.bytes, isEmpty);
    });

    test(
      'chunk encode -> tryDecode round-trips; plain text is not a chunk',
      () {
        final c = AttachmentChunker.split(att('a4', 5)).single;
        final back = AttachmentChunk.tryDecode(c.encode())!;
        expect(back.attachmentId, 'a4');
        expect(back.data, c.data);
        expect(AttachmentChunk.tryDecode('hello there'), isNull);
      },
    );

    test('a chunk declaring an oversized total is rejected', () {
      final huge = jsonEncode({
        't': 'attach',
        'aid': 'a5',
        'kind': 'file',
        'ct': 'application/octet-stream',
        'i': 0,
        'n': AttachmentChunk.maxChunks + 1,
        'd': base64Encode([1, 2, 3]),
      });
      expect(AttachmentChunk.tryDecode(huge), isNull);
    });

    test('a chunk whose decoded data exceeds the byte cap is rejected', () {
      final oversizedData = List<int>.filled(
        AttachmentChunker.maxAllowedChunkBytes + 1,
        7,
      );
      final frame = jsonEncode({
        't': 'attach',
        'aid': 'a6',
        'kind': 'file',
        'ct': 'application/octet-stream',
        'i': 0,
        'n': 1,
        'd': base64Encode(oversizedData),
      });
      expect(AttachmentChunk.tryDecode(frame), isNull);
    });

    test('AttachmentChunker.split rejects maxChunkBytes above the cap', () {
      expect(
        () => AttachmentChunker.split(
          att('a7', 10),
          maxChunkBytes: AttachmentChunker.maxAllowedChunkBytes + 1,
        ),
        throwsArgumentError,
      );
    });

    test('a chunk with a conflicting total for a known id is dropped; the '
        'original partial still completes correctly', () {
      final a = att('a8', 20000);
      final chunks = AttachmentChunker.split(a, maxChunkBytes: 10000);
      expect(chunks.length, 2);
      final asm = AttachmentReassembler();

      // Feed the first legitimate chunk.
      expect(asm.accept(chunks[0]), isNull);

      // A conflicting chunk (same id, different total) must be dropped,
      // not corrupt the in-flight partial.
      final conflicting = AttachmentChunk(
        attachmentId: 'a8',
        kind: MediaKind.image,
        contentType: 'image/jpeg',
        index: 0,
        total: 99,
        data: [1, 2, 3],
      );
      expect(asm.accept(conflicting), isNull);
      expect(asm.pendingCount, 1);

      // The original partial still completes correctly.
      final done = asm.accept(chunks[1]);
      expect(done, isNotNull);
      expect(done!.bytes, a.bytes);
    });

    test('pending-attachment cap: the 17th distinct incomplete id evicts the '
        'oldest', () {
      final asm = AttachmentReassembler(); // default cap 16
      // Open 16 distinct incomplete attachments (send only the first of 2
      // chunks for each, so none complete).
      for (var i = 0; i < 16; i++) {
        final chunks = AttachmentChunker.split(
          att('id$i', 20000),
          maxChunkBytes: 10000,
        );
        asm.accept(chunks[0]);
      }
      expect(asm.pendingCount, 16);

      // The 17th distinct id evicts the oldest (id0).
      final chunks17 = AttachmentChunker.split(
        att('id16', 20000),
        maxChunkBytes: 10000,
      );
      asm.accept(chunks17[0]);
      expect(asm.pendingCount, 16);

      // id0's partial was evicted: finishing it now starts a fresh
      // partial rather than completing the original one.
      final id0Chunks = AttachmentChunker.split(
        att('id0', 20000),
        maxChunkBytes: 10000,
      );
      expect(asm.accept(id0Chunks[1]), isNull); // second half alone: no-op
    });
  });

  test(
    'end-to-end: photo sent over ReliableMessenger, received whole',
    () async {
      final a = MemPort();
      final b = MemPort();
      a.peer = b;
      b.peer = a;
      final alice = ReliableMessenger(a, peerId: 'alice');
      final bob = ReliableMessenger(b, peerId: 'bob');

      final receiver = AttachmentReceiver();
      final chats = <String>[];
      final photos = <Attachment>[];
      receiver.completed.listen(photos.add);
      bob.incoming.listen((m) {
        if (!receiver.offer(m.text)) chats.add(m.text); // route chunk vs chat
      });

      await alice.send('here is a photo:'); // plain chat
      await sendAttachment(alice, att('photo-1', 40000), maxChunkBytes: 8000);
      await pumpEventQueue();

      expect(chats, ['here is a photo:']);
      expect(photos, hasLength(1));
      expect(photos.single.id, 'photo-1');
      expect(photos.single.sizeBytes, 40000);

      await receiver.close();
      await alice.close();
      await bob.close();
    },
  );

  group('startAttachmentSend progress', () {
    test('emits 0 -> 100% in per-chunk steps and completes done', () async {
      final a = MemPort();
      final b = MemPort();
      a.peer = b;
      b.peer = a;
      final alice = ReliableMessenger(a, peerId: 'alice');

      final handle = startAttachmentSend(
        alice,
        att('p', 30000),
        maxChunkBytes: 12288,
      );
      expect(handle.totalBytes, 30000);
      final snapshots = <AttachmentSendProgress>[];
      handle.progress.listen(snapshots.add);

      await handle.done;
      await pumpEventQueue();

      expect(snapshots.map((s) => s.bytesSent).toList(), [
        0,
        12288,
        24576,
        30000,
      ]);
      expect(snapshots.every((s) => s.totalBytes == 30000), isTrue);
      expect(snapshots.first.fraction, 0.0);
      expect(snapshots.last.fraction, 1.0);
      expect(handle.bytesSent, 30000);

      await alice.close();
    });

    test('empty attachment reports complete (fraction 1.0) immediately', () {
      final progress = AttachmentSendProgress(0, 0);
      expect(progress.fraction, 1.0);
    });

    test(
      'sendAttachment still delivers whole (delegates to the handle)',
      () async {
        final a = MemPort();
        final b = MemPort();
        a.peer = b;
        b.peer = a;
        final alice = ReliableMessenger(a, peerId: 'alice');
        final bob = ReliableMessenger(b, peerId: 'bob');
        final receiver = AttachmentReceiver();
        final photos = <Attachment>[];
        receiver.completed.listen(photos.add);
        bob.incoming.listen((m) => receiver.offer(m.text));

        await sendAttachment(alice, att('p2', 5000), maxChunkBytes: 2048);
        await pumpEventQueue();

        expect(photos, hasLength(1));
        expect(photos.single.sizeBytes, 5000);

        await receiver.close();
        await alice.close();
        await bob.close();
      },
    );
  });
}
