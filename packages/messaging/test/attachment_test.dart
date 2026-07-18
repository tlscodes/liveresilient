import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

void main() {
  group('Attachment', () {
    test('empty id throws ArgumentError', () {
      expect(
        () => Attachment(
          id: '',
          kind: MediaKind.file,
          contentType: 'application/octet-stream',
          bytes: [1, 2, 3],
        ),
        throwsArgumentError,
      );
    });

    test('bytes list is unmodifiable', () {
      final a = Attachment(
        id: 'a1',
        kind: MediaKind.file,
        contentType: 'application/octet-stream',
        bytes: [1, 2, 3],
      );
      expect(() => a.bytes.add(4), throwsUnsupportedError);
      expect(() => a.bytes[0] = 9, throwsUnsupportedError);
    });
  });
}
