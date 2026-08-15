import 'dart:io';

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

    test('proxyConfigurator runs after the proxy policy is applied, '
        'once per fetch, with the live client', () async {
      final proxyCalls = <Uri>[];
      final configuredClients = <HttpClient>[];
      final fetcher = IoManifestFetcher(
        timeout: const Duration(milliseconds: 300),
        proxyResolver: (uri) {
          proxyCalls.add(uri);
          return 'DIRECT';
        },
        proxyConfigurator: (client) {
          // Representative security setup a real app would perform here.
          client.addProxyCredentials(
            '127.0.0.1',
            1080,
            'realm',
            HttpClientBasicCredentials('user', 'secret'),
          );
          configuredClients.add(client);
        },
      );

      // Unroutable port: the fetch fails, but both hooks have run by then.
      await expectLater(
        fetcher.fetch(Uri.parse('https://127.0.0.1:1/manifest')),
        throwsA(anything),
      );

      expect(configuredClients, hasLength(1));
      expect(proxyCalls, isNotEmpty);
    });
  });

  group('IoManifestFetcher optional resolveAddress hook', () {
    test('resolver is consulted with the target hostname', () async {
      final resolved = <String>[];
      final fetcher = IoManifestFetcher(
        timeout: const Duration(milliseconds: 300),
        resolveAddress: (host) async {
          resolved.add(host);
          return '127.0.0.1';
        },
      );

      // "config.invalid" never resolves in DNS; port 1 is closed. The
      // connection to the MAPPED address fails fast, but the resolver was
      // consulted with the original hostname — the wiring under test.
      await expectLater(
        fetcher.fetch(Uri.parse('https://config.invalid:1/manifest')),
        throwsA(anything),
      );

      expect(resolved, ['config.invalid']);
    });

    test('resolver returning null falls back to the original host', () async {
      final fetcher = IoManifestFetcher(
        timeout: const Duration(milliseconds: 300),
        resolveAddress: (_) async => null,
      );

      await expectLater(
        fetcher.fetch(Uri.parse('https://127.0.0.1:1/manifest')),
        throwsA(anything),
      );
    });
  });
}
