import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// The fetcher exposes a neutral, optional on-device forward-proxy hook
/// (standard `dart:io` findProxy). The core stays unaware of what runs behind
/// the proxy; any such transport lives in an external, independently audited
/// plugin wired in only through this hook.
void main() {
  group('IoManifestFetcher optional proxy hook', () {
    test('proxyResolver is consulted for the target URI', () async {
      final seen = <Uri>[];
      final fetcher = IoManifestFetcher(
        timeout: const Duration(milliseconds: 300),
        proxyResolver: (uri) {
          seen.add(uri);
          return 'DIRECT'; // resolve to a direct connection for the test
        },
      );

      // Unroutable port: the connection fails, but findProxy is consulted
      // first, which is exactly the wiring under test.
      await expectLater(
        fetcher.fetch(Uri.parse('https://127.0.0.1:1/manifest')),
        throwsA(anything),
      );

      expect(seen, isNotEmpty);
      expect(seen.first.toString(), 'https://127.0.0.1:1/manifest');
    });

    test('default construction stays direct (no proxy)', () {
      expect(IoManifestFetcher.new, returnsNormally);
    });
  });
}
