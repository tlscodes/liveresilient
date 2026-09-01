/// The rung ladder that decides which endpoints a fresh install trusts — and,
/// until now, had no test at all.
///
/// The property under test is not "does it find a manifest". It is: **when a
/// rung was configured and failed, does the result say so?** A developer who
/// typos `ENDPOINT_MANIFEST_FILE` used to be downgraded to public STUN and told
/// "discovery works, relaying does not" — a true sentence about a different
/// situation, produced by a `catch (_)` that discarded the only fact worth
/// keeping.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/startup_manifest.dart';
import 'package:signed_config/signed_config.dart';

EndpointManifest _manifest({int revision = 7}) => EndpointManifest(
  revision: revision,
  signingKeyId: 'key-a',
  issuedAt: DateTime.utc(2026, 8, 1),
  expiresAt: DateTime.utc(2026, 9, 1),
  signalingEndpoints: [Uri.parse('wss://relay.example/signal')],
  iceServers: [
    IceServerEntry(
      urls: [Uri.parse('turns:relay.example:443')],
      username: 'u',
      credential: 'c',
    ),
  ],
  configServiceUris: [Uri.parse('https://config.example/manifest')],
);

void main() {
  group('rung order', () {
    test('a verified manifest outranks everything', () async {
      final s = await loadStartupManifest(
        verifiedManifest: _manifest(),
        outOfBandManifest: _manifest(revision: 99),
        environment: const {},
      );
      expect(s.source, ManifestSource.signedConfig);
      expect(s.manifest!.revision, 7);
    });

    test('an out-of-band manifest outranks the dev file and STUN', () async {
      final s = await loadStartupManifest(
        outOfBandManifest: _manifest(revision: 12),
        environment: const {},
      );
      expect(s.source, ManifestSource.outOfBand);
      expect(s.manifest!.revision, 12);
      expect(s.describe(), contains('same verification'));
    });

    test('an empty-ICE manifest does not count as a manifest', () async {
      // A manifest with no ICE servers cannot do the one job the rung exists
      // for; silently accepting it would leave the caller believing it is
      // configured while every call is placed with nothing.
      final empty = EndpointManifest(
        revision: 3,
        signingKeyId: 'key-a',
        issuedAt: DateTime.utc(2026, 8, 1),
        expiresAt: DateTime.utc(2026, 9, 1),
        signalingEndpoints: [Uri.parse('wss://relay.example/signal')],
        iceServers: const [],
        configServiceUris: [Uri.parse('https://config.example/m')],
      );
      final s = await loadStartupManifest(
        verifiedManifest: empty,
        environment: const {},
      );
      expect(s.source, isNot(ManifestSource.signedConfig));
    });

    test(
      'nothing configured falls to public STUN, and says what that buys',
      () async {
        final s = await loadStartupManifest(environment: const {});
        expect(s.source, ManifestSource.publicStunFallback);
        expect(s.describe(), contains('relaying does not'));
        expect(
          s.failure,
          isNull,
          reason: 'nothing was tried, so nothing failed',
        );
      },
    );

    test('with the fallback disabled the honest answer is none', () async {
      final s = await loadStartupManifest(
        environment: const {},
        allowPublicStunFallback: false,
      );
      expect(s.source, ManifestSource.none);
      expect(s.hasIceServers, isFalse);
    });
  });

  group('a configured rung that fails is reported, not hidden', () {
    test('a missing file is named in the result', () async {
      final s = await loadStartupManifest(
        environment: {'ENDPOINT_MANIFEST_FILE': '/no/such/manifest.json'},
      );
      expect(s.source, ManifestSource.publicStunFallback);
      expect(s.failure, isNotNull);
      expect(s.failure, contains('/no/such/manifest.json'));
      // The distinction the whole change exists for: the description must not
      // read like a device that was never configured.
      expect(s.describe(), contains('but note'));
    });

    test(
      'a malformed file is named too, and is not silently ignored',
      () async {
        final dir = await Directory.systemTemp.createTemp('startup_manifest');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/broken.json');
        await file.writeAsString('{ this is not json');

        final s = await loadStartupManifest(
          environment: {'ENDPOINT_MANIFEST_FILE': file.path},
        );
        expect(s.failure, isNotNull);
        expect(s.describe(), contains('but note'));
      },
    );

    test(
      'valid JSON that is not a manifest is distinguished from unreadable',
      () async {
        final dir = await Directory.systemTemp.createTemp('startup_manifest');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/array.json');
        await file.writeAsString(jsonEncode([1, 2, 3]));

        final s = await loadStartupManifest(
          environment: {'ENDPOINT_MANIFEST_FILE': file.path},
        );
        expect(s.failure, contains('not a manifest object'));
      },
    );

    test('a good dev file is used, and reports no failure', () async {
      final dir = await Directory.systemTemp.createTemp('startup_manifest');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/good.json');
      await file.writeAsString(jsonEncode(_manifest(revision: 5).toJson()));

      final s = await loadStartupManifest(
        environment: {'ENDPOINT_MANIFEST_FILE': file.path},
      );
      expect(s.source, ManifestSource.localFile);
      expect(s.manifest!.revision, 5);
      expect(s.failure, isNull);
      expect(s.describe(), isNot(contains('but note')));
    });
  });
}
