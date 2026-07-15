import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('ManifestVerifier', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late Uint8List key2Revoked;
    late ManifestVerifier verifier;

    setUp(() {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      key2Revoked = keyBytes(2);
      verifier = ManifestVerifier(
        pinnedKeys: [
          PinnedManifestKey(keyId: 'key-1', publicKey: key1),
          PinnedManifestKey(
            keyId: 'key-2',
            publicKey: key2Revoked,
            revoked: true,
          ),
        ],
        crypto: crypto,
      );
    });

    test('constructor rejects an empty pinned-key list', () {
      expect(
        () => ManifestVerifier(pinnedKeys: const [], crypto: crypto),
        throwsArgumentError,
      );
    });

    test('constructor rejects duplicate key ids', () {
      expect(
        () => ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'dup', publicKey: key1),
            PinnedManifestKey(keyId: 'dup', publicKey: key2Revoked),
          ],
          crypto: crypto,
        ),
        throwsArgumentError,
      );
    });

    test(
      'accepts a validly signed, in-window, non-rollback manifest',
      () async {
        final manifest = buildManifest(revision: 5, signingKeyId: 'key-1');
        final document = signManifest(manifest, key1);

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 4,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestAccepted>());
        final accepted = result as ManifestAccepted;
        expect(accepted.manifest.revision, 5);
        expect(crypto.callCount, 1);
      },
    );

    test(
      'accepts when revision equals lastAcceptedRevision (re-fetch of same manifest)',
      () async {
        final manifest = buildManifest(revision: 5, signingKeyId: 'key-1');
        final document = signManifest(manifest, key1);

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 5,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestAccepted>());
      },
    );

    test('rejects malformed manifest JSON before touching crypto', () async {
      final document = SignedManifestDocument(
        manifestJson: const {'schemaVersion': 1}, // missing required fields
        signature: List.filled(64, 0),
      );

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1),
      );

      expect(result, isA<ManifestRejected>());
      expect((result as ManifestRejected).reason, ManifestRejection.malformed);
      expect(crypto.callCount, 0);
    });

    test('rejects an unknown signing key id', () async {
      final manifest = buildManifest(signingKeyId: 'key-unknown');
      final document = signManifest(manifest, key1);

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1, 0, 30),
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.unknownSigningKey,
      );
      expect(crypto.callCount, 0);
    });

    test('rejects a revoked signing key', () async {
      final manifest = buildManifest(signingKeyId: 'key-2');
      final document = signManifest(manifest, key2Revoked);

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1, 0, 30),
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.revokedSigningKey,
      );
      expect(crypto.callCount, 0);
    });

    test(
      'rejects a signature of the wrong length without calling crypto',
      () async {
        final manifest = buildManifest(signingKeyId: 'key-1');
        final document = signManifest(
          manifest,
          key1,
          signatureOverride: List.filled(10, 1),
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestRejected>());
        expect(
          (result as ManifestRejected).reason,
          ManifestRejection.badSignature,
        );
        expect(crypto.callCount, 0);
      },
    );

    test(
      'rejects a tampered signature (correct length, wrong bytes)',
      () async {
        final manifest = buildManifest(signingKeyId: 'key-1');
        final document = signManifest(
          manifest,
          key1,
          signatureOverride: List.filled(64, 9),
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestRejected>());
        expect(
          (result as ManifestRejected).reason,
          ManifestRejection.badSignature,
        );
        expect(crypto.callCount, 1);
      },
    );

    test('rejects an expired manifest', () async {
      final manifest = buildManifest(
        signingKeyId: 'key-1',
        issuedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 1, 1, 1),
      );
      final document = signManifest(manifest, key1);

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1, 2), // past expiresAt
      );

      expect(result, isA<ManifestRejected>());
      expect((result as ManifestRejected).reason, ManifestRejection.expired);
    });

    test('rejects a manifest not yet valid (issuedAt in the future)', () async {
      final manifest = buildManifest(
        signingKeyId: 'key-1',
        issuedAt: DateTime.utc(2026, 6, 1),
        expiresAt: DateTime.utc(2026, 6, 1, 1),
      );
      final document = signManifest(manifest, key1);

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1), // before issuedAt
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.notYetValid,
      );
    });

    test(
      'rejects a rollback to a revision older than the last accepted one',
      () async {
        final manifest = buildManifest(revision: 3, signingKeyId: 'key-1');
        final document = signManifest(manifest, key1);

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 5,
          now: DateTime.utc(2026, 1, 1, 0, 30),
        );

        expect(result, isA<ManifestRejected>());
        expect((result as ManifestRejected).reason, ManifestRejection.rollback);
      },
    );

    test('signature-before-time order: a tampered AND expired manifest reports '
        'badSignature, never expired (anti-oracle — no timing signal leaks '
        'before authenticity is proven)', () async {
      final manifest = buildManifest(
        signingKeyId: 'key-1',
        issuedAt: DateTime.utc(2020, 1, 1),
        expiresAt: DateTime.utc(2020, 1, 1, 1),
      );
      final document = signManifest(
        manifest,
        key1,
        signatureOverride: List.filled(64, 7), // tampered
      );

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1), // also far past expiresAt
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.badSignature,
        reason: 'signature must be checked before the time window',
      );
    });

    test(
      'uses DateTime.now() when now is omitted (accepts a manifest valid today)',
      () async {
        final now = DateTime.now().toUtc();
        final manifest = buildManifest(
          signingKeyId: 'key-1',
          issuedAt: now.subtract(const Duration(minutes: 1)),
          expiresAt: now.add(const Duration(hours: 1)),
        );
        final document = signManifest(manifest, key1);

        final result = await verifier.verify(document, lastAcceptedRevision: 0);

        expect(result, isA<ManifestAccepted>());
      },
    );
  });

  group('PinnedManifestKey', () {
    test('rejects a public key that is not exactly 32 bytes', () {
      expect(
        () => PinnedManifestKey(keyId: 'k', publicKey: List.filled(31, 0)),
        throwsFormatException,
      );
    });
  });

  group('SignedManifestDocument.fromBytes', () {
    test('rejects bytes that are not valid JSON', () {
      expect(
        () => SignedManifestDocument.fromBytes(utf8.encode('not json')),
        throwsFormatException,
      );
    });

    test('rejects a signature that is not valid base64', () {
      final bytes = utf8.encode(
        jsonEncode({'manifest': <String, Object?>{}, 'signature': '***'}),
      );
      expect(
        () => SignedManifestDocument.fromBytes(bytes),
        throwsFormatException,
      );
    });
  });
}
