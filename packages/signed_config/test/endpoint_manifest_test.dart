/// Schema-v2 [EndpointManifest] model tests: round-trip symmetry for the
/// Phase 7 fields (`configServiceUris`, `relayRegions`, `featureFlags`),
/// canonical-bytes sensitivity (the signature input), and strict `fromJson`
/// rejection of malformed v2 documents.
library;

import 'dart:convert';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('round-trip', () {
    test('regions + flags + multi-origin URIs survive fromJson/toJson', () {
      final original = buildManifest(
        configServiceUris: [
          Uri.parse('https://config.example.com/manifest'),
          Uri.parse('https://config-alt.example.net/manifest'),
        ],
        relayRegions: const ['eu-central', 'us-east', 'ap-south-1'],
        featureFlags: const {'relay_failover': true, 'ipv6_candidates': false},
      );

      final decoded = EndpointManifest.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );

      expect(decoded.schemaVersion, manifestSchemaVersion);
      expect(decoded.configServiceUris, original.configServiceUris);
      expect(decoded.relayRegions, original.relayRegions);
      expect(decoded.featureFlags, original.featureFlags);
      expect(decoded.toJson(), original.toJson());
      expect(decoded.canonicalBytes(), original.canonicalBytes());
    });

    test('empty relayRegions and featureFlags survive round-trip', () {
      final original = buildManifest(
        relayRegions: const [],
        featureFlags: const {},
      );

      final json = original.toJson();
      // Emitted even when empty, so canonical signed bytes are stable.
      expect(json['relayRegions'], isEmpty);
      expect(json['featureFlags'], isEmpty);

      final decoded = EndpointManifest.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(decoded.relayRegions, isEmpty);
      expect(decoded.featureFlags, isEmpty);
      expect(decoded.toJson(), original.toJson());
      expect(decoded.canonicalBytes(), original.canonicalBytes());
    });
  });

  group('canonicalBytes sensitivity (signature input)', () {
    test('flipping one featureFlag changes the canonical bytes', () {
      final a = buildManifest(
        featureFlags: const {'relay_failover': true, 'ipv6_candidates': false},
      );
      final b = buildManifest(
        featureFlags: const {'relay_failover': true, 'ipv6_candidates': true},
      );
      expect(a.canonicalBytes(), isNot(equals(b.canonicalBytes())));
    });

    test('changing a relay region changes the canonical bytes', () {
      final a = buildManifest(relayRegions: const ['eu-central']);
      final b = buildManifest(relayRegions: const ['eu-west']);
      expect(a.canonicalBytes(), isNot(equals(b.canonicalBytes())));
    });

    test('featureFlags insertion order does not affect canonical bytes', () {
      final a = buildManifest(
        featureFlags: const {'a_flag': true, 'b_flag': false},
      );
      final b = buildManifest(
        featureFlags: const {'b_flag': false, 'a_flag': true},
      );
      expect(a.canonicalBytes(), b.canonicalBytes());
    });
  });

  group('fromJson rejection', () {
    Map<String, Object?> validJson() =>
        jsonDecode(jsonEncode(buildManifest().toJson()))
            as Map<String, Object?>;

    void expectRejected(Map<String, Object?> json) {
      expect(
        () => EndpointManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    }

    test('rejects schemaVersion 1 (and anything not current)', () {
      expectRejected({...validJson(), 'schemaVersion': 1});
      expectRejected({...validJson(), 'schemaVersion': 3});
    });

    test('rejects more than 32 featureFlags', () {
      final flags = {for (var i = 0; i < 33; i++) 'flag_$i': true};
      expectRejected({...validJson(), 'featureFlags': flags});
    });

    test('accepts exactly 32 featureFlags (boundary)', () {
      final flags = {for (var i = 0; i < 32; i++) 'flag_$i': true};
      final manifest = EndpointManifest.fromJson({
        ...validJson(),
        'featureFlags': flags,
      });
      expect(manifest.featureFlags.length, 32);
    });

    test('rejects non-bool featureFlag values', () {
      expectRejected({
        ...validJson(),
        'featureFlags': {'relay_failover': 'true'},
      });
      expectRejected({
        ...validJson(),
        'featureFlags': {'relay_failover': 1},
      });
      expectRejected({
        ...validJson(),
        'featureFlags': {'relay_failover': null},
      });
    });

    test('rejects invalid featureFlag keys', () {
      expectRejected({
        ...validJson(),
        'featureFlags': {'Bad-Key': true},
      });
      expectRejected({
        ...validJson(),
        'featureFlags': {'': true},
      });
      expectRejected({
        ...validJson(),
        'featureFlags': {'x' * 65: true},
      });
    });

    test('rejects bad relay region formats', () {
      expectRejected({
        ...validJson(),
        'relayRegions': ['EU-Central'],
      });
      expectRejected({
        ...validJson(),
        'relayRegions': [''],
      });
      expectRejected({
        ...validJson(),
        'relayRegions': ['under_score'],
      });
      expectRejected({
        ...validJson(),
        'relayRegions': ['a' * 33],
      });
      expectRejected({
        ...validJson(),
        'relayRegions': [42],
      });
    });

    test('rejects duplicate relay regions', () {
      expectRejected({
        ...validJson(),
        'relayRegions': ['eu-central', 'eu-central'],
      });
    });

    test('rejects duplicate configServiceUris', () {
      expectRejected({
        ...validJson(),
        'configServiceUris': [
          'https://config.example.com/manifest',
          'https://config.example.com/manifest',
        ],
      });
    });

    test('rejects non-https configServiceUris', () {
      expectRejected({
        ...validJson(),
        'configServiceUris': [
          'https://config.example.com/manifest',
          'http://insecure.example.com/manifest',
        ],
      });
    });

    test('rejects empty or missing configServiceUris', () {
      expectRejected({...validJson(), 'configServiceUris': <Object?>[]});
      final withoutUris = validJson()..remove('configServiceUris');
      expectRejected(withoutUris);
    });

    test('missing relayRegions/featureFlags default to empty', () {
      final json = validJson()
        ..remove('relayRegions')
        ..remove('featureFlags');
      final manifest = EndpointManifest.fromJson(json);
      expect(manifest.relayRegions, isEmpty);
      expect(manifest.featureFlags, isEmpty);
    });
  });
}
