/// End-to-end test of the `manifest_keygen` + `sign_manifest` dev/ops CLIs:
/// runs both as real subprocesses (`dart run bin/...`), then feeds their
/// output into the real [ManifestVerifier] + [CryptographyEd25519Verifier]
/// exactly as the app would consume a fetched signed manifest.
library;

import 'dart:convert';
import 'dart:io';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// The `signed_config` package root — tests run with cwd set to it by
/// `dart test`, and the CLIs are invoked relative to that root exactly as
/// documented in their usage strings.
final String _packageRoot = Directory.current.path;

Future<ProcessResult> _run(List<String> args) {
  return Process.run('dart', ['run', ...args], workingDirectory: _packageRoot);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sign_manifest_cli_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'keygen -> sign -> ManifestVerifier accepts the resulting document',
    () async {
      final keyPath = '${tempDir.path}/private-key.json';
      final manifestPath = '${tempDir.path}/manifest.json';
      final signedPath = '${tempDir.path}/signed-manifest.json';

      final keygenResult = await _run([
        'bin/manifest_keygen.dart',
        '--out',
        keyPath,
        '--key-id',
        'key-e2e-1',
      ]);
      expect(
        keygenResult.exitCode,
        0,
        reason: 'keygen stderr: ${keygenResult.stderr}',
      );
      expect(keygenResult.stdout, contains('keyId: key-e2e-1'));

      final keyFile = File(keyPath);
      expect(keyFile.existsSync(), isTrue);
      final keyJson = jsonDecode(keyFile.readAsStringSync()) as Map;
      final publicKeyB64 = keyJson['publicKey'] as String;

      File(manifestPath).writeAsStringSync(
        jsonEncode({
          'schemaVersion': manifestSchemaVersion,
          'revision': 1,
          // Deliberately wrong: sign_manifest must overwrite this with the
          // signing key's own id, not trust the input file.
          'signingKeyId': 'ignored-placeholder',
          'issuedAt': '2026-07-16T00:00:00Z',
          'expiresAt': '2026-07-17T00:00:00Z',
          'signalingEndpoints': ['wss://signal.example.com/v1'],
          'iceServers': <Object?>[],
          'configServiceUris': [
            'https://config.example.com/manifest',
            'https://config-alt.example.net/manifest',
          ],
          'relayRegions': ['eu-central', 'us-east'],
          'featureFlags': {'relay_failover': true, 'ipv6_candidates': false},
        }),
      );

      final signResult = await _run([
        'bin/sign_manifest.dart',
        '--manifest',
        manifestPath,
        '--key',
        keyPath,
        '--out',
        signedPath,
      ]);
      expect(
        signResult.exitCode,
        0,
        reason: 'sign stderr: ${signResult.stderr}',
      );

      final signedFile = File(signedPath);
      expect(signedFile.existsSync(), isTrue);
      final signedJson =
          jsonDecode(signedFile.readAsStringSync()) as Map<String, Object?>;
      expect((signedJson['manifest'] as Map)['signingKeyId'], 'key-e2e-1');

      final document = SignedManifestDocument.fromBytes(
        utf8.encode(jsonEncode(signedJson)),
      );

      final verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(
            keyId: 'key-e2e-1',
            publicKey: base64Decode(publicKeyB64),
          ),
        ],
        crypto: CryptographyEd25519Verifier(),
      );

      final result = await verifier.verify(document, lastAcceptedRevision: 0);

      expect(result, isA<ManifestAccepted>());
      final manifest = (result as ManifestAccepted).manifest;
      expect(manifest.revision, 1);
      expect(manifest.configServiceUris.map((u) => u.toString()).toList(), [
        'https://config.example.com/manifest',
        'https://config-alt.example.net/manifest',
      ]);
      expect(manifest.relayRegions, ['eu-central', 'us-east']);
      expect(manifest.featureFlags, {
        'relay_failover': true,
        'ipv6_candidates': false,
      });
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'sign_manifest rejects a manifest file missing required fields',
    () async {
      final keyPath = '${tempDir.path}/private-key.json';
      final manifestPath = '${tempDir.path}/manifest.json';

      final keygenResult = await _run([
        'bin/manifest_keygen.dart',
        '--out',
        keyPath,
      ]);
      expect(keygenResult.exitCode, 0);

      // Missing signalingEndpoints/configServiceUris.
      File(manifestPath).writeAsStringSync(jsonEncode({'revision': 1}));

      final signResult = await _run([
        'bin/sign_manifest.dart',
        '--manifest',
        manifestPath,
        '--key',
        keyPath,
      ]);

      expect(signResult.exitCode, isNot(0));
      expect(signResult.stderr, contains('Invalid manifest'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
