import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

void main() {
  group('ChatMessage', () {
    test('negative seq throws ArgumentError', () {
      expect(
        () => ChatMessage(
          id: 'x',
          senderId: 'alice',
          seq: -1,
          sentAtMs: 0,
          text: 'hi',
        ),
        throwsArgumentError,
      );
    });

    test('negative sentAtMs throws ArgumentError', () {
      expect(
        () => ChatMessage(
          id: 'x',
          senderId: 'alice',
          seq: 0,
          sentAtMs: -1,
          text: 'hi',
        ),
        throwsArgumentError,
      );
    });

    test('non-negative seq/sentAtMs construct fine', () {
      final m = ChatMessage(
        id: 'x',
        senderId: 'alice',
        seq: 0,
        sentAtMs: 0,
        text: 'hi',
      );
      expect(m.seq, 0);
      expect(m.sentAtMs, 0);
    });
  });
}
