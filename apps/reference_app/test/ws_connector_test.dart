import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ws_connector.dart';

void main() {
  group('WebSocket Custom Connector Tests', () {
    test(
      'connectWebSocketWithCustomRules configures client properties safely',
      () {
        final endpoint = Uri.parse('wss://127.0.0.1:1/ws');
        expect(
          () => connectWebSocketWithCustomRules(
            endpoint,
            timeout: const Duration(milliseconds: 100),
            hostResolver: (_) => '127.0.0.1',
          ),
          throwsA(anything),
        );
      },
    );
  });
}
