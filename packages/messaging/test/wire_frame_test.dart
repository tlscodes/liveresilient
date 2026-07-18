import 'dart:convert';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

void main() {
  group('WireCodec', () {
    test('message round-trips through encode -> tryDecode', () {
      final msg = ChatMessage(
        id: 'alice-abc123-0',
        senderId: 'alice',
        seq: 0,
        sentAtMs: 1000,
        contentType: 'text/plain',
        text: 'hello',
      );
      final frame = WireCodec.tryDecode(WireCodec.encodeMessage(msg));
      expect(frame, isA<MessageFrame>());
      final decoded = (frame as MessageFrame).message;
      expect(decoded.id, msg.id);
      expect(decoded.senderId, msg.senderId);
      expect(decoded.seq, msg.seq);
      expect(decoded.sentAtMs, msg.sentAtMs);
      expect(decoded.contentType, msg.contentType);
      expect(decoded.text, msg.text);
    });

    test('ack round-trips through encode -> tryDecode', () {
      final frame = WireCodec.tryDecode(WireCodec.encodeAck('some-id'));
      expect(frame, isA<AckFrame>());
      expect((frame as AckFrame).id, 'some-id');
    });

    test('oversized frame is rejected before parsing', () {
      // Build an oversized-but-otherwise-valid message frame.
      final huge = jsonEncode({
        'v': WireCodec.version,
        'type': 'msg',
        'id': 'x',
        'sender': 'alice',
        'seq': 0,
        'ts': 0,
        'body': 'a' * (WireCodec.maxFrameBytes + 1),
      });
      final bytes = utf8.encode(huge);
      expect(bytes.length, greaterThan(WireCodec.maxFrameBytes));
      expect(WireCodec.tryDecode(bytes), isNull);
    });

    test('a content-type longer than 255 chars is rejected', () {
      final bytes = utf8.encode(
        jsonEncode({
          'v': WireCodec.version,
          'type': 'msg',
          'id': 'x',
          'sender': 'alice',
          'seq': 0,
          'ts': 0,
          'ct': 'a' * 256,
          'body': 'hi',
        }),
      );
      expect(WireCodec.tryDecode(bytes), isNull);
    });

    test('a content-type at exactly 255 chars is accepted', () {
      final bytes = utf8.encode(
        jsonEncode({
          'v': WireCodec.version,
          'type': 'msg',
          'id': 'x',
          'sender': 'alice',
          'seq': 0,
          'ts': 0,
          'ct': 'a' * 255,
          'body': 'hi',
        }),
      );
      final frame = WireCodec.tryDecode(bytes);
      expect(frame, isA<MessageFrame>());
    });

    test('wrong-version frame is rejected', () {
      final bytes = utf8.encode(
        jsonEncode({
          'v': WireCodec.version + 1,
          'type': 'msg',
          'id': 'x',
          'sender': 'alice',
          'seq': 0,
          'ts': 0,
          'body': 'hi',
        }),
      );
      expect(WireCodec.tryDecode(bytes), isNull);
    });

    test('ack with a non-string id is rejected', () {
      final bytes = utf8.encode(
        jsonEncode({'v': WireCodec.version, 'type': 'ack', 'id': 42}),
      );
      expect(WireCodec.tryDecode(bytes), isNull);
    });

    test('a message with a negative seq (would throw in ChatMessage) is '
        'rejected, not thrown', () {
      final bytes = utf8.encode(
        jsonEncode({
          'v': WireCodec.version,
          'type': 'msg',
          'id': 'x',
          'sender': 'alice',
          'seq': -1,
          'ts': 0,
          'body': 'hi',
        }),
      );
      expect(WireCodec.tryDecode(bytes), isNull);
    });
  });
}
