/// Zero-outage signing-key rotation, proven end to end with REAL Ed25519
/// cryptography: manifests are signed in-test with `package:cryptography`'s
/// Ed25519 and verified through [ManifestVerifier] backed by
/// [CryptographyEd25519Verifier] — no fake signature scheme anywhere.
///
/// The rotation story under test (three epochs of pinned-key sets):
///
/// 1. **Epoch 1** — only keyA pinned; manifests signed by keyA verify.
/// 2. **Epoch 2 (overlap)** — keyA AND keyB pinned; manifests signed by
///    EITHER key verify in the SAME epoch, so at no moment during rotation
///    does a client lose the ability to validate config (zero outage).
/// 3. **Epoch 3 (retire)** — keyA pinned but `revoked: true`, keyB live;
///    keyB manifests keep verifying while ANY keyA signature — replayed old
///    revisions or freshly minted higher revisions from a stolen key — is
///    rejected as `revokedSigningKey` (revocation beats freshness).
library;

import 'package:cryptography/cryptography.dart';
import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart' show buildManifest;

void main() {
  final algorithm = Ed25519();

  // Inside the validity window of buildManifest's defaults
  // (issuedAt 2026-01-01T00:00Z, expiresAt +1h).
  final now = DateTime.utc(2026, 1, 1, 0, 30);

  late SimpleKeyPair keyPairA;
  late SimpleKeyPair keyPairB;
  late SimpleKeyPair keyPairC; // Never pinned: the "unknown key" attacker.
  late PinnedManifestKey pinnedA;
  late PinnedManifestKey pinnedB;
  late PinnedManifestKey pinnedARevoked;

  Future<PinnedManifestKey> pin(
    String keyId,
    SimpleKeyPair keyPair, {
    bool revoked = false,
  }) async {
    final publicKey = await keyPair.extractPublicKey();
    return PinnedManifestKey(
      keyId: keyId,
      publicKey: publicKey.bytes,
      revoked: revoked,
    );
  }

  /// Signs [manifest]'s canonical bytes with a REAL Ed25519 key, producing
  /// the same transport document shape the app fetches over HTTPS.
  Future<SignedManifestDocument> sign(
    EndpointManifest manifest,
    SimpleKeyPair keyPair,
  ) async {
    final signature = await algorithm.sign(
      manifest.canonicalBytes(),
      keyPair: keyPair,
    );
    return SignedManifestDocument(
      manifestJson: manifest.toJson(),
      signature: signature.bytes,
    );
  }

  setUpAll(() async {
    keyPairA = await algorithm.newKeyPair();
    keyPairB = await algorithm.newKeyPair();
    keyPairC = await algorithm.newKeyPair();
    pinnedA = await pin('key-a', keyPairA);
    pinnedB = await pin('key-b', keyPairB);
    pinnedARevoked = await pin('key-a', keyPairA, revoked: true);
  });

  group('zero-outage key rotation (real Ed25519)', () {
    test(
      'epoch 1: pinned=[keyA] — revision 1 signed by keyA is accepted',
      () async {
        final verifier = ManifestVerifier(
          pinnedKeys: [pinnedA],
          crypto: CryptographyEd25519Verifier(),
        );
        final document = await sign(
          buildManifest(revision: 1, signingKeyId: 'key-a'),
          keyPairA,
        );

        final result = await verifier.verify(
          document,
          lastAcceptedRevision: 0,
          now: now,
        );

        expect(result, isA<ManifestAccepted>());
        final manifest = (result as ManifestAccepted).manifest;
        expect(manifest.revision, 1);
        // Schema v2: the accepted manifest carries multiple https origins.
        expect(manifest.configServiceUris, hasLength(greaterThanOrEqualTo(2)));
        expect(
          manifest.configServiceUris.every((u) => u.scheme == 'https'),
          isTrue,
        );
      },
    );

    test('epoch 2 (overlap): pinned=[keyA, keyB] — the old keyA manifest AND '
        'the new keyB manifest both verify in the SAME epoch (no moment '
        'exists where neither key verifies)', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedA, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev1ByA = await sign(
        buildManifest(revision: 1, signingKeyId: 'key-a'),
        keyPairA,
      );
      final rev2ByB = await sign(
        buildManifest(revision: 2, signingKeyId: 'key-b'),
        keyPairB,
      );

      // Old client mid-rotation re-validates its cached rev-1 manifest.
      final oldStillValid = await verifier.verify(
        rev1ByA,
        lastAcceptedRevision: 1,
        now: now,
      );
      // Fresh fetch of the newly signed rev-2 manifest.
      final newAccepted = await verifier.verify(
        rev2ByB,
        lastAcceptedRevision: 1,
        now: now,
      );

      expect(oldStillValid, isA<ManifestAccepted>());
      expect(newAccepted, isA<ManifestAccepted>());
      expect((newAccepted as ManifestAccepted).manifest.revision, 2);
    });

    test('epoch 3 (retire): pinned=[keyA revoked, keyB] — keyB manifests keep '
        'verifying after keyA is retired', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev2ByB = await sign(
        buildManifest(revision: 2, signingKeyId: 'key-b'),
        keyPairB,
      );

      final result = await verifier.verify(
        rev2ByB,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestAccepted>());
      expect((result as ManifestAccepted).manifest.revision, 2);
    });

    test('epoch 3: a NEW revision 3 signed by the retired keyA is rejected '
        'with reason revokedSigningKey', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev3ByA = await sign(
        buildManifest(revision: 3, signingKeyId: 'key-a'),
        keyPairA,
      );

      final result = await verifier.verify(
        rev3ByA,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.revokedSigningKey,
      );
    });

    test('epoch 3: a REPLAYED revision 1 (signed by keyA in epoch 1) is '
        'rejected as revokedSigningKey — revocation is checked before the '
        'rollback check, so the reason is revocation, not rollback', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final replayedRev1 = await sign(
        buildManifest(revision: 1, signingKeyId: 'key-a'),
        keyPairA,
      );

      final result = await verifier.verify(
        replayedRev1,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.revokedSigningKey,
      );
    });

    test('epoch 3: rollback protection holds independently of revocation — a '
        'revision 1 manifest signed by the LIVE keyB is rejected as rollback '
        'once revision 2 has been accepted (lastAcceptedRevision=2)', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev1ByB = await sign(
        buildManifest(revision: 1, signingKeyId: 'key-b'),
        keyPairB,
      );

      final result = await verifier.verify(
        rev1ByB,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestRejected>());
      expect((result as ManifestRejected).reason, ManifestRejection.rollback);
    });

    test('stolen retired key cannot mint fresher config: revision 99 signed '
        'by revoked keyA is rejected revokedSigningKey (revocation beats '
        'freshness)', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev99ByA = await sign(
        buildManifest(revision: 99, signingKeyId: 'key-a'),
        keyPairA,
      );

      final result = await verifier.verify(
        rev99ByA,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.revokedSigningKey,
      );
    });

    test('a signature by an unpinned keyC is rejected unknownSigningKey — '
        'trust is anchored in the pinned key set, not in whoever can serve '
        'bytes', () async {
      final verifier = ManifestVerifier(
        pinnedKeys: [pinnedARevoked, pinnedB],
        crypto: CryptographyEd25519Verifier(),
      );
      final rev4ByC = await sign(
        buildManifest(revision: 4, signingKeyId: 'key-c'),
        keyPairC,
      );

      final result = await verifier.verify(
        rev4ByC,
        lastAcceptedRevision: 2,
        now: now,
      );

      expect(result, isA<ManifestRejected>());
      expect(
        (result as ManifestRejected).reason,
        ManifestRejection.unknownSigningKey,
      );
    });
  });
}
