import 'dart:typed_data';

import 'package:security/src/crypto_identity_engine.dart';
import 'package:security/src/identity_store.dart';
import 'package:security/src/key_store.dart';
import 'package:test/test.dart';

/// A minimal in-memory [SecureKeyValueStore] for tests: production callers
/// use a real platform secure-storage adapter, but [IdentityStore] only
/// depends on the interface, so an in-memory map is a faithful test double
/// for its logic.
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

IdentityStore _newStore() => IdentityStore(
  engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
  store: InMemorySecureKeyValueStore(),
);

void main() {
  group('IdentityStore + CryptographyIdentityKeyEngine (real keys)', () {
    test(
      'localIdentity generates a 32-byte key and a hex fingerprint',
      () async {
        final identityStore = _newStore();
        final identity = await identityStore.localIdentity();

        expect(identity.publicKey.length, 32);
        final fingerprintNoSpaces = identity.fingerprint.replaceAll(' ', '');
        expect(fingerprintNoSpaces, matches(RegExp(r'^[0-9A-F]+$')));
        expect(fingerprintNoSpaces.contains(':'), isFalse);
      },
    );

    test('localIdentity is cached and stable across calls', () async {
      final identityStore = _newStore();
      final first = await identityStore.localIdentity();
      final second = await identityStore.localIdentity();
      expect(second.publicKey, equals(first.publicKey));
      expect(second.fingerprint, equals(first.fingerprint));
    });

    test('localKeyId is 16 hex characters with no colons', () async {
      final identityStore = _newStore();
      final keyId = await identityStore.localKeyId();
      expect(keyId.length, 16);
      expect(keyId, matches(RegExp(r'^[0-9A-F]+$')));
      expect(keyId.contains(':'), isFalse);
    });

    test('signSessionFingerprint + verifySessionFingerprint round-trips once '
        'the peer key is pinned', () async {
      final localStore = _newStore();
      final digest = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final signature = await localStore.signSessionFingerprint(digest);
      final localIdentity = await localStore.localIdentity();

      // The remote side pins the local device's presented key first.
      final remoteStore = _newStore();
      await remoteStore.checkRemoteIdentity(
        peerId: 'local-device',
        presentedPublicKey: localIdentity.publicKey,
      );

      final ok = await remoteStore.verifySessionFingerprint(
        peerId: 'local-device',
        sessionDigest: digest,
        signature: signature,
      );
      expect(ok, isTrue);
    });

    test('verifySessionFingerprint fails for an unpinned peer', () async {
      final identityStore = _newStore();
      final digest = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final signature = await identityStore.signSessionFingerprint(digest);

      final ok = await identityStore.verifySessionFingerprint(
        peerId: 'never-seen-before',
        sessionDigest: digest,
        signature: signature,
      );
      expect(ok, isFalse);
    });

    test('verifySessionFingerprint fails when the signature was made by a '
        'different device', () async {
      final storeA = _newStore();
      final storeB = _newStore();
      final digest = Uint8List.fromList(List<int>.generate(32, (i) => i));

      final identityA = await storeA.localIdentity();
      final signatureFromB = await storeB.signSessionFingerprint(digest);

      final verifier = _newStore();
      await verifier.checkRemoteIdentity(
        peerId: 'device-a',
        presentedPublicKey: identityA.publicKey,
      );

      final ok = await verifier.verifySessionFingerprint(
        peerId: 'device-a',
        sessionDigest: digest,
        signature: signatureFromB,
      );
      expect(ok, isFalse);
    });

    group('TOFU pin/accept/changed flows', () {
      test('first contact pins the presented key', () async {
        final identityStore = _newStore();
        final peerIdentity = await _newStore().localIdentity();

        final result = await identityStore.checkRemoteIdentity(
          peerId: 'peer-1',
          presentedPublicKey: peerIdentity.publicKey,
        );
        expect(result, RemoteIdentityCheck.pinnedFirstUse);
      });

      test('same key on later contact matches', () async {
        final identityStore = _newStore();
        final peerIdentity = await _newStore().localIdentity();

        await identityStore.checkRemoteIdentity(
          peerId: 'peer-2',
          presentedPublicKey: peerIdentity.publicKey,
        );
        final result = await identityStore.checkRemoteIdentity(
          peerId: 'peer-2',
          presentedPublicKey: peerIdentity.publicKey,
        );
        expect(result, RemoteIdentityCheck.match);
      });

      test('a different key on later contact is reported as changed', () async {
        final identityStore = _newStore();
        final firstIdentity = await _newStore().localIdentity();
        final secondIdentity = await _newStore().localIdentity();
        expect(
          secondIdentity.publicKey,
          isNot(equals(firstIdentity.publicKey)),
        );

        await identityStore.checkRemoteIdentity(
          peerId: 'peer-3',
          presentedPublicKey: firstIdentity.publicKey,
        );
        final result = await identityStore.checkRemoteIdentity(
          peerId: 'peer-3',
          presentedPublicKey: secondIdentity.publicKey,
        );
        expect(result, RemoteIdentityCheck.changed);
      });

      test(
        'acceptChangedIdentity re-pins so the new key now matches',
        () async {
          final identityStore = _newStore();
          final firstIdentity = await _newStore().localIdentity();
          final secondIdentity = await _newStore().localIdentity();

          await identityStore.checkRemoteIdentity(
            peerId: 'peer-4',
            presentedPublicKey: firstIdentity.publicKey,
          );
          await identityStore.checkRemoteIdentity(
            peerId: 'peer-4',
            presentedPublicKey: secondIdentity.publicKey,
          ); // changed, not yet accepted

          await identityStore.acceptChangedIdentity(
            peerId: 'peer-4',
            newPublicKey: secondIdentity.publicKey,
          );

          final result = await identityStore.checkRemoteIdentity(
            peerId: 'peer-4',
            presentedPublicKey: secondIdentity.publicKey,
          );
          expect(result, RemoteIdentityCheck.match);
        },
      );
    });

    test('acceptChangedIdentity + checkRemoteIdentity round-trips to a '
        'match for the newly-pinned key', () async {
      final identityStore = _newStore();
      final firstIdentity = await _newStore().localIdentity();
      final secondIdentity = await _newStore().localIdentity();

      await identityStore.checkRemoteIdentity(
        peerId: 'peer-5',
        presentedPublicKey: firstIdentity.publicKey,
      );
      await identityStore.acceptChangedIdentity(
        peerId: 'peer-5',
        newPublicKey: secondIdentity.publicKey,
      );

      final result = await identityStore.checkRemoteIdentity(
        peerId: 'peer-5',
        presentedPublicKey: secondIdentity.publicKey,
      );
      expect(result, RemoteIdentityCheck.match);
    });

    group('safetyNumber symmetry with real keys', () {
      test('is identical regardless of which side computes it', () async {
        final aliceStore = _newStore();
        final bobStore = _newStore();
        final alice = await aliceStore.localIdentity();
        final bob = await bobStore.localIdentity();

        final fromAlice = await aliceStore.safetyNumber(
          localPublicKey: alice.publicKey,
          remotePublicKey: bob.publicKey,
        );
        final fromBob = await bobStore.safetyNumber(
          localPublicKey: bob.publicKey,
          remotePublicKey: alice.publicKey,
        );

        expect(fromBob, equals(fromAlice));
      });

      test('differs for a different peer pairing', () async {
        final aliceStore = _newStore();
        final alice = await aliceStore.localIdentity();
        final bob = await _newStore().localIdentity();
        final carol = await _newStore().localIdentity();

        final withBob = await aliceStore.safetyNumber(
          localPublicKey: alice.publicKey,
          remotePublicKey: bob.publicKey,
        );
        final withCarol = await aliceStore.safetyNumber(
          localPublicKey: alice.publicKey,
          remotePublicKey: carol.publicKey,
        );

        expect(withBob, isNot(equals(withCarol)));
      });

      test('self-pairing (local == remote) is stable across repeated '
          'calls', () async {
        final store = _newStore();
        final identity = await store.localIdentity();

        final first = await store.safetyNumber(
          localPublicKey: identity.publicKey,
          remotePublicKey: identity.publicKey,
        );
        final second = await store.safetyNumber(
          localPublicKey: identity.publicKey,
          remotePublicKey: identity.publicKey,
        );

        expect(first, equals(second));
      });
    });
  });
}
