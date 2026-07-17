import 'dart:async';

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
}
