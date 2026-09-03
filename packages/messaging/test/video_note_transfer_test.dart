import 'dart:async';
import 'dart:typed_data';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// In-process port pair: frames sent on one end arrive on the other's
/// inbound stream on the next microtask.
class _MemPort implements DataChannelPort {
  final _inbound = StreamController<List<int>>.broadcast();
  _MemPort? peer;

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async {
    peer?._inbound.add(frame);
  }

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

(_MemPort, _MemPort) _pair() {
  final a = _MemPort();
  final b = _MemPort();
  a.peer = b;
  b.peer = a;
  return (a, b);
}

Uint8List _clip(int length, int seed) {
  final out = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16 & 0xff;
  }
  return out;
}

void main() {
  group('VideoNoteAnnouncement', () {
    test('round-trips through encode/tryDecode and ignores other text', () {
      final clip = _clip(3000, 7);
      final a = VideoNoteAnnouncement.forBytes(
        clip,
        contentType: 'video/mp4',
        durationMs: 4200,
      );
      expect(a.videoId, contentAddressHex(clip));
      expect(a.sha256Hex, contentSha256Hex(clip));
      final back = VideoNoteAnnouncement.tryDecode(a.encode());
      expect(back, isNotNull);
      expect(back!.videoId, a.videoId);
      expect(back.sha256Hex, a.sha256Hex);
      expect(back.byteLength, 3000);
      expect(back.contentType, 'video/mp4');
      expect(back.durationMs, 4200);
      expect(VideoNoteAnnouncement.tryDecode('hello'), isNull);
      expect(VideoNoteAnnouncement.tryDecode('{"v":"other"}'), isNull);
      expect(
        VideoNoteAnnouncement.tryDecode('{"v":"vck-video-note","id":1}'),
        isNull,
      );
    });
  });

  group('VideoNoteSender/Receiver over a lane', () {
    test('a note is announced, then arrives and verifies against the '
        'announced sha256', () async {
      final (laneTx, laneRx) = _pair();
      final announced = <String>[];
      final receiver = VideoNoteReceiver(laneRx);
      addTearDown(receiver.close);
      final updates = <VideoNoteUpdate>[];
      receiver.updates.listen(updates.add);
      final sender = VideoNoteSender(
        laneTx,
        announce: (text) async {
          announced.add(text);
          // The messenger would carry this; hand it straight across.
          expect(receiver.offerText(text), isTrue);
        },
        retransmitAfter: const Duration(milliseconds: 200),
        chunkBytes: 1024,
      );

      final clip = _clip(20000, 11);
      final announcement = await sender
          .deliver(clip, contentType: 'video/mp4', durationMs: 3000)
          .timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);

      expect(announced, hasLength(1));
      expect(updates.map((u) => u.stage), [
        VideoNoteStage.announced,
        VideoNoteStage.verified,
      ]);
      final state = receiver.notes[announcement.videoId]!;
      expect(state.stage, VideoNoteStage.verified);
      expect(state.bytes, clip);
      expect(receiver.offerText('plain chat text'), isFalse);
    });

    test('a blob that lands before its announcement is judged when the '
        'announcement arrives', () async {
      final (laneTx, laneRx) = _pair();
      final receiver = VideoNoteReceiver(laneRx);
      addTearDown(receiver.close);
      final updates = <VideoNoteUpdate>[];
      receiver.updates.listen(updates.add);
      String? held;
      final sender = VideoNoteSender(
        laneTx,
        announce: (text) async => held = text, // withheld
        retransmitAfter: const Duration(milliseconds: 200),
        chunkBytes: 1024,
      );
      final clip = _clip(5000, 3);
      await sender
          .deliver(clip, contentType: 'video/webm', durationMs: 1000)
          .timeout(const Duration(seconds: 10));
      expect(updates, isEmpty, reason: 'nothing announced yet');

      expect(receiver.offerText(held!), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(updates.map((u) => u.stage), [
        VideoNoteStage.announced,
        VideoNoteStage.verified,
      ]);
    });

    test('an announcement whose sha256 does not match the blob fails, '
        'never verifies', () async {
      final (laneTx, laneRx) = _pair();
      final receiver = VideoNoteReceiver(laneRx);
      addTearDown(receiver.close);
      final updates = <VideoNoteUpdate>[];
      receiver.updates.listen(updates.add);
      final clip = _clip(4000, 5);
      final impostor = VideoNoteAnnouncement(
        videoId: contentAddressHex(clip),
        sha256Hex: 'f' * 64,
        byteLength: clip.length,
        contentType: 'video/mp4',
        durationMs: 10,
      );
      expect(receiver.offerText(impostor.encode()), isTrue);
      final rawSender = BinaryStreamSender(
        laneTx,
        retransmitAfter: const Duration(milliseconds: 200),
        chunkBytes: 1024,
      );
      await rawSender.send(clip).timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(updates.last.stage, VideoNoteStage.failed);
      expect(receiver.notes[impostor.videoId]!.bytes, isNull);
    });
  });
}
