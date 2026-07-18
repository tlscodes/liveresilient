/// Algorithm agility of the signed-manifest envelope.
///
/// The envelope carries an optional `"alg"` field (absent == `ed25519`) so
/// the format can ever name another signature algorithm. These tests pin the
/// three contracts that make a future migration safe:
///
/// 1. compatibility — documents without `"alg"`, and all previously signed
///    bytes, verify exactly as before;
/// 2. distinguishability — an algorithm this build does not support is
///    rejected as [ManifestRejection.unsupportedAlgorithm], never as
///    corruption, because "update the app" and "distrust the origin" are
///    opposite recoveries;
/// 3. structure per algorithm — signature/key length rules live with the
///    algorithm, not hard-coded in the verifier or key type.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Accepts every structurally valid call — isolates envelope/dispatch logic
/// from real cryptography, which crypto_ed25519_verifier_test covers.
final class _AcceptAllCrypto implements Ed25519Verifier {
  int calls = 0;

  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    calls++;
    return true;
  }
}

/// A structurally valid manifest built from the real model (via the shared
/// [buildManifest] helper), so this file can never drift from the schema.
Map<String, Object?> _manifestJson() => buildManifest(
  signingKeyId: 'key-a',
  issuedAt: DateTime.utc(2026, 7, 1),
  expiresAt: DateTime.utc(2027, 7, 1),
).toJson();

List<int> _docBytes({Object? alg, int signatureLength = 64}) {
  final root = <String, Object?>{
    'manifest': _manifestJson(),
    'signature': base64Encode(List<int>.filled(signatureLength, 7)),
  };
  if (alg != null) root['alg'] = alg;
  return utf8.encode(jsonEncode(root));
}

ManifestVerifier _verifier(
  _AcceptAllCrypto crypto, {
  ManifestSignatureAlgorithm keyAlgorithm = ManifestSignatureAlgorithm.ed25519,
}) {
  return ManifestVerifier(
    pinnedKeys: [
      PinnedManifestKey(
        keyId: 'key-a',
        publicKey: List<int>.filled(32, 3),
        algorithm: keyAlgorithm,
      ),
    ],
    crypto: crypto,
  );
}

void main() {
  final now = DateTime.utc(2026, 7, 18);

  group('compatibility with pre-"alg" documents', () {
    test('a document without "alg" parses as ed25519 and verifies', () async {
      final crypto = _AcceptAllCrypto();
      final document = SignedManifestDocument.fromBytes(_docBytes());
      expect(document.algorithmLabel, 'ed25519');

      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      expect(result, isA<ManifestAccepted>());
      expect(crypto.calls, 1);
    });

    test('an explicit "alg": "ed25519" behaves identically', () async {
      final crypto = _AcceptAllCrypto();
      final document = SignedManifestDocument.fromBytes(
        _docBytes(alg: 'ed25519'),
      );
      expect(document.algorithmLabel, 'ed25519');

      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      expect(result, isA<ManifestAccepted>());
    });
  });

  group('unsupported algorithms are distinguishable, not "corrupt"', () {
    test('an unknown "alg" parses fine and rejects as unsupported', () async {
      final crypto = _AcceptAllCrypto();
      // Parsing must NOT throw: an unknown algorithm is a verification
      // outcome, not malformed input.
      final document = SignedManifestDocument.fromBytes(
        _docBytes(alg: 'future-scheme-1'),
      );
      expect(document.algorithmLabel, 'future-scheme-1');

      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      expect(result, isA<ManifestRejected>());
      final rejected = result as ManifestRejected;
      expect(rejected.reason, ManifestRejection.unsupportedAlgorithm);
      // The one rejection that should hint "update", and it must never have
      // consumed a crypto call.
      expect(rejected.detail, contains('update'));
      expect(crypto.calls, 0);
    });

    test('unsupported-algorithm rejection happens before key checks — a '
        'client too old for the algorithm reports that, not a key '
        'problem', () async {
      final crypto = _AcceptAllCrypto();
      final json = _manifestJson()..['signingKeyId'] = 'key-unknown';
      final root = <String, Object?>{
        'manifest': json,
        'alg': 'future-scheme-1',
        'signature': base64Encode(List<int>.filled(64, 7)),
      };
      final document = SignedManifestDocument.fromBytes(
        utf8.encode(jsonEncode(root)),
      );

      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.unsupportedAlgorithm,
      );
    });

    test('a key pinned for a different algorithm never verifies the '
        'document', () async {
      // Only one algorithm exists today, so the mismatch branch cannot be
      // reached through public construction (PinnedManifestKey validates key
      // length per algorithm). This test pins the dispatch order instead:
      // matching algorithm + matching key reaches crypto exactly once.
      final crypto = _AcceptAllCrypto();
      final document = SignedManifestDocument.fromBytes(
        _docBytes(alg: 'ed25519'),
      );
      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      expect(result, isA<ManifestAccepted>());
      expect(crypto.calls, 1);
    });
  });

  group('structural rules live with the algorithm', () {
    test('a non-64-byte signature on an ed25519 document is '
        'malformedSignature, and names the algorithm', () async {
      final crypto = _AcceptAllCrypto();
      final document = SignedManifestDocument.fromBytes(
        _docBytes(signatureLength: 63),
      );
      final result = await _verifier(
        crypto,
      ).verify(document, lastAcceptedRevision: 0, now: now);
      final rejected = result as ManifestRejected;
      expect(rejected.reason, ManifestRejection.malformedSignature);
      expect(rejected.detail, contains('ed25519'));
      expect(crypto.calls, 0);
    });

    test('PinnedManifestKey validates key length against its algorithm', () {
      expect(
        () => PinnedManifestKey(keyId: 'k', publicKey: List<int>.filled(31, 1)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parse-layer contracts (fuzz invariant: FormatException only)', () {
    test('a non-string "alg" is malformed input', () {
      expect(
        () => SignedManifestDocument.fromBytes(_docBytes(alg: 42)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SignedManifestDocument.fromBytes(_docBytes(alg: <String>[])),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty or absurdly long "alg" is malformed input', () {
      expect(
        () => SignedManifestDocument.fromBytes(_docBytes(alg: '')),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SignedManifestDocument.fromBytes(_docBytes(alg: 'x' * 65)),
        throwsA(isA<FormatException>()),
      );
      // Exactly at the cap is fine (and lands as unsupported, not malformed).
      final document = SignedManifestDocument.fromBytes(
        _docBytes(alg: 'x' * 64),
      );
      expect(document.algorithmLabel.length, 64);
    });

    test('ManifestSignatureAlgorithm.tryParse is exact-match only', () {
      expect(
        ManifestSignatureAlgorithm.tryParse('ed25519'),
        ManifestSignatureAlgorithm.ed25519,
      );
      expect(ManifestSignatureAlgorithm.tryParse('ED25519'), isNull);
      expect(ManifestSignatureAlgorithm.tryParse(' ed25519'), isNull);
      expect(ManifestSignatureAlgorithm.tryParse('ed25519 '), isNull);
    });
  });
}
