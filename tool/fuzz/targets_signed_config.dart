/// Fuzz targets for `package:signed_config` parsers.
///
/// Targets:
///  - `signed_manifest_document` → [SignedManifestDocument.fromBytes]
///    (wire bytes: `{"manifest": {...}, "signature": "<base64>"}`).
///  - `endpoint_manifest`        → [EndpointManifest.fromJson] (schema v2
///    JSON tree, fed directly as a `Map` — no bytes/encoding step, since
///    the API itself takes a decoded tree).
library;

import 'dart:convert';

import 'package:signed_config/signed_config.dart';

import 'fuzz_engine.dart';

/// A randomized *valid* schema-v2 manifest tree (accept-path corpus).
Map<String, Object?> buildValidManifestTree(FuzzRng rng) {
  final issuedAt = DateTime.utc(
    2024,
    1,
    1,
  ).add(Duration(days: rng.intIn(0, 900), minutes: rng.intIn(0, 1440)));
  final expiresAt = issuedAt.add(Duration(minutes: rng.intIn(1, 43200)));
  return <String, Object?>{
    'schemaVersion': manifestSchemaVersion,
    'revision': rng.intIn(1, 1000000),
    'signingKeyId': rng.token(rng.intIn(1, 32)),
    'issuedAt': issuedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'signalingEndpoints': [
      for (var i = 0; i < rng.intIn(1, 3); i++)
        'wss://relay-${rng.token(6)}-$i.example.com/${rng.token(4)}',
    ],
    'iceServers': [
      for (var i = 0; i < rng.intIn(0, 3); i++)
        if (rng.chance(0.5))
          <String, Object?>{
            'urls': ['stun:stun-${rng.token(4)}-$i.example.com:3478'],
          }
        else
          <String, Object?>{
            'urls': ['turn:turn-${rng.token(4)}-$i.example.com:3478'],
            'username': rng.token(rng.intIn(1, 8)),
            'credential': rng.token(rng.intIn(1, 16)),
          },
    ],
    'configServiceUris': [
      for (var i = 0; i < rng.intIn(1, 2); i++)
        'https://config-${rng.token(6)}-$i.example.com',
    ],
    'relayRegions': [for (var i = 0; i < rng.intIn(0, 4); i++) 'region-$i'],
    'featureFlags': {
      for (var i = 0; i < rng.intIn(0, 10); i++) 'flag_$i': rng.chance(0.5),
    },
  };
}

/// `SignedManifestDocument.fromBytes`: FormatException or a valid document.
class SignedManifestDocumentFuzzTarget extends FuzzTarget {
  @override
  String get name => 'signed_manifest_document';

  Map<String, Object?> buildValidTree(FuzzRng rng) => <String, Object?>{
    'manifest': buildValidManifestTree(rng),
    'signature': base64Encode(rng.bytes(64)),
  };

  @override
  FuzzCase generate(FuzzRng rng) {
    final valid = buildValidTree(rng);
    if (rng.chance(0.05)) {
      return FuzzCase.ofBytes(utf8.encode(jsonEncode(valid)));
    }
    // Mutate either the wrapper (manifest/signature) or dig into the
    // nested manifest tree so both layers get structural coverage.
    final tree = rng.chance(0.5)
        ? mutateTree(valid, rng)
        : <String, Object?>{
            ...valid,
            'manifest': mutateTree(
              valid['manifest']! as Map<String, Object?>,
              rng,
            ),
          };
    final String encoded;
    try {
      encoded = jsonEncode(tree);
    } on Object {
      return FuzzCase.ofBytes(rng.bytes(rng.nextInt(128)));
    }
    if (rng.chance(0.35)) {
      return FuzzCase.ofBytes(mutateEncodedBytes(encoded, tree, rng));
    }
    return FuzzCase.ofBytes(utf8.encode(encoded));
  }

  @override
  FuzzOutcome execute(Object? input) {
    SignedManifestDocument.fromBytes(input! as List<int>);
    return FuzzOutcome.accept;
  }
}

/// `EndpointManifest.fromJson`: FormatException or a valid manifest. Fed
/// the mutated tree directly (the API takes a decoded `Map`, not bytes).
class EndpointManifestFuzzTarget extends FuzzTarget {
  @override
  String get name => 'endpoint_manifest';

  @override
  FuzzCase generate(FuzzRng rng) {
    final valid = buildValidManifestTree(rng);
    final tree = rng.chance(0.05) ? valid : mutateTree(valid, rng);
    return FuzzCase.ofJsonTree(tree);
  }

  @override
  FuzzOutcome execute(Object? input) {
    EndpointManifest.fromJson(input! as Map<String, Object?>);
    return FuzzOutcome.accept;
  }
}

/// All signed_config fuzz targets.
List<FuzzTarget> signedConfigFuzzTargets() => [
  SignedManifestDocumentFuzzTarget(),
  EndpointManifestFuzzTarget(),
];
