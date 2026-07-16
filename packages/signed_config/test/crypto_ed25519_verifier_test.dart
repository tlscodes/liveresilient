/// Golden-path tests for [CryptographyEd25519Verifier], exercised through
/// the real [ManifestVerifier] (never a standalone `verify()` call), so the
/// same tests double as an integration proof that the real crypto plugs
/// into the (frozen, 100%-tested) verifier logic exactly as the fake does
/// in `manifest_verifier_test.dart`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// A real Ed25519 keypair generated for one test.
class _TestKey {
  final SimpleKeyPair keyPair;
  final Uint8List publicKeyBytes;
  _TestKey(this.keyPair, this.publicKeyBytes);
}

Future<_TestKey> _generateKey(Ed25519 algorithm) async {
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  return _TestKey(keyPair, Uint8List.fromList(publicKey.bytes));
}

Future<Uint8List> _sign(
  Ed25519 algorithm,
  SimpleKeyPair keyPair,
  Uint8List message,
) async {
  final signature = await algorithm.sign(message, keyPair: keyPair);
  return Uint8List.fromList(signature.bytes);
}

void main() {
  final algorithm = Ed25519();
  final crypto = CryptographyEd25519Verifier();

  group('CryptographyEd25519Verifier via ManifestVerifier', () {
    test('accepts a manifest signed by its pinned key', () async {
      final key = await _generateKey(algorithm);
      final manifest = buildManifest(signingKeyId: 'key-1');
      final message = Uint8List.fromList(manifest.canonicalBytes());
      final signature = await _sign(algorithm, key.keyPair, message);

      final verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
        ],
        crypto: crypto,
      );
      final document = SignedManifestDocument(
        manifestJson: manifest.toJson(),
        signature: signature,
      );

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1, 0, 30),
      );

      expect(result, isA<ManifestAccepted>());
      expect((result as ManifestAccepted).manifest.signingKeyId, 'key-1');
    });

    test('rejects when the manifest body is tampered after signing', () async {
      final key = await _generateKey(algorithm);
      final manifest = buildManifest(signingKeyId: 'key-1', revision: 1);
      final message = Uint8List.fromList(manifest.canonicalBytes());
      final signature = await _sign(algorithm, key.keyPair, message);

      // Body tamper: bump the revision after signing. Still a well-formed
      // manifest, but its canonical bytes no longer match the signature.
      final tamperedJson = {
        ...manifest.toJson(),
        'revision': manifest.revision + 1,
      };

      final verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
        ],
        crypto: crypto,
      );
      final document = SignedManifestDocument(
        manifestJson: tamperedJson,
        signature: signature,
      );

      final result = await verifier.verify(document, lastAcceptedRevision: 0);

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.badSignature,
      );
    });

    test('rejects when a single bit of the signature is flipped', () async {
      final key = await _generateKey(algorithm);
      final manifest = buildManifest(signingKeyId: 'key-1');
      final message = Uint8List.fromList(manifest.canonicalBytes());
      final signature = await _sign(algorithm, key.keyPair, message);
      final tamperedSignature = Uint8List.fromList(signature)
        ..[0] = signature[0] ^ 0x01;

      final verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
        ],
        crypto: crypto,
      );
      final document = SignedManifestDocument(
        manifestJson: manifest.toJson(),
        signature: tamperedSignature,
      );

      final result = await verifier.verify(document, lastAcceptedRevision: 0);

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.badSignature,
      );
    });

    test('rejects when pinned under the wrong key', () async {
      final signingKey = await _generateKey(algorithm);
      final wrongKey = await _generateKey(algorithm);
      final manifest = buildManifest(signingKeyId: 'key-1');
      final message = Uint8List.fromList(manifest.canonicalBytes());
      final signature = await _sign(algorithm, signingKey.keyPair, message);

      // The pinned key for 'key-1' is NOT the key that produced the
      // signature — simulates a misconfigured/mismatched pin.
      final verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(keyId: 'key-1', publicKey: wrongKey.publicKeyBytes),
        ],
        crypto: crypto,
      );
      final document = SignedManifestDocument(
        manifestJson: manifest.toJson(),
        signature: signature,
      );

      final result = await verifier.verify(document, lastAcceptedRevision: 0);

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.badSignature,
      );
    });

    group('time-window behavior with real signatures', () {
      test('accepted inside the validity window', () async {
        final key = await _generateKey(algorithm);
        final issued = DateTime.utc(2026, 1, 1, 12);
        final manifest = buildManifest(
          signingKeyId: 'key-1',
          issuedAt: issued,
          expiresAt: issued.add(const Duration(hours: 1)),
        );
        final message = Uint8List.fromList(manifest.canonicalBytes());
        final signature = await _sign(algorithm, key.keyPair, message);
        final verifier = ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
          ],
          crypto: crypto,
        );
        final document = SignedManifestDocument(
          manifestJson: manifest.toJson(),
          signature: signature,
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: issued.add(const Duration(minutes: 30)),
        );

        expect(result, isA<ManifestAccepted>());
      });

      test('rejected as notYetValid when now is before issuedAt', () async {
        final key = await _generateKey(algorithm);
        final issued = DateTime.utc(2026, 1, 1, 12);
        final manifest = buildManifest(
          signingKeyId: 'key-1',
          issuedAt: issued,
          expiresAt: issued.add(const Duration(hours: 1)),
        );
        final message = Uint8List.fromList(manifest.canonicalBytes());
        final signature = await _sign(algorithm, key.keyPair, message);
        final verifier = ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
          ],
          crypto: crypto,
        );
        final document = SignedManifestDocument(
          manifestJson: manifest.toJson(),
          signature: signature,
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: issued.subtract(const Duration(minutes: 1)),
        );

        expect(result, isA<ManifestRejected>());
        expect(
          (result as ManifestRejected).reason,
          ManifestRejection.notYetValid,
        );
      });

      test('rejected as expired once past expiresAt', () async {
        final key = await _generateKey(algorithm);
        final issued = DateTime.utc(2026, 1, 1, 12);
        final manifest = buildManifest(
          signingKeyId: 'key-1',
          issuedAt: issued,
          expiresAt: issued.add(const Duration(hours: 1)),
        );
        final message = Uint8List.fromList(manifest.canonicalBytes());
        final signature = await _sign(algorithm, key.keyPair, message);
        final verifier = ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-1', publicKey: key.publicKeyBytes),
          ],
          crypto: crypto,
        );
        final document = SignedManifestDocument(
          manifestJson: manifest.toJson(),
          signature: signature,
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: issued.add(const Duration(hours: 2)),
        );

        expect(result, isA<ManifestRejected>());
        expect((result as ManifestRejected).reason, ManifestRejection.expired);
      });
    });

    group('key rotation', () {
      test('manifest signed by the newly-rotated-in key is accepted while '
          'both keys are pinned and unrevoked', () async {
        final key1 = await _generateKey(algorithm);
        final key2 = await _generateKey(algorithm);
        final manifest = buildManifest(signingKeyId: 'key-2');
        final message = Uint8List.fromList(manifest.canonicalBytes());
        final signature = await _sign(algorithm, key2.keyPair, message);

        final verifier = ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-1', publicKey: key1.publicKeyBytes),
            PinnedManifestKey(keyId: 'key-2', publicKey: key2.publicKeyBytes),
          ],
          crypto: crypto,
        );
        final document = SignedManifestDocument(
          manifestJson: manifest.toJson(),
          signature: signature,
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestAccepted>());
      });

      test(
        'the same manifest+signature is rejected once its key is revoked',
        () async {
          final key1 = await _generateKey(algorithm);
          final key2 = await _generateKey(algorithm);
          final manifest = buildManifest(signingKeyId: 'key-2');
          final message = Uint8List.fromList(manifest.canonicalBytes());
          final signature = await _sign(algorithm, key2.keyPair, message);
          final document = SignedManifestDocument(
            manifestJson: manifest.toJson(),
            signature: signature,
          );

          // A fresh verifier instance models the app re-pinning its key
          // set after rotation: key-2 is now revoked.
          final verifierAfterRevocation = ManifestVerifier(
            pinnedKeys: [
              PinnedManifestKey(keyId: 'key-1', publicKey: key1.publicKeyBytes),
              PinnedManifestKey(
                keyId: 'key-2',
                publicKey: key2.publicKeyBytes,
                revoked: true,
              ),
            ],
            crypto: crypto,
          );

          final result = await verifierAfterRevocation.verify(
            document,
            lastAcceptedRevision: 0,
          );

          expect(result, isA<ManifestRejected>());
          expect(
            (result as ManifestRejected).reason,
            ManifestRejection.revokedSigningKey,
          );
        },
      );
    });
  });

  group('CryptographyEd25519Verifier.verify (direct)', () {
    test('rejects malformed-length public keys and signatures', () async {
      final key = await _generateKey(algorithm);
      final message = Uint8List.fromList([1, 2, 3]);
      final signature = await _sign(algorithm, key.keyPair, message);

      expect(
        await crypto.verify(
          message: message,
          signature: signature,
          publicKey: Uint8List(16),
        ),
        isFalse,
      );
      expect(
        await crypto.verify(
          message: message,
          signature: Uint8List(10),
          publicKey: key.publicKeyBytes,
        ),
        isFalse,
      );
    });
  });
}
