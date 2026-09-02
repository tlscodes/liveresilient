/// Freezes the safety-number derivation.
///
/// A safety number is the one value in this system that can never change. Two
/// people compare theirs over a channel the server does not control; if a later
/// version derives different digits from the same pair of keys, they see a
/// mismatch and the honest reading of a mismatch is "someone is in the middle".
/// So the golden vector below is not a regression test, it is a commitment.
///
/// Changing the derivation means shipping a version 2 alongside version 1 and
/// showing which is in use — never editing these expectations.
library;

import 'dart:typed_data';

import 'package:security/src/crypto_identity_engine.dart';
import 'package:security/src/identity_store.dart';
import 'package:security/src/key_store.dart';
import 'package:test/test.dart';

/// In-memory persistence: the derivation touches no storage, but the store
/// requires one.
class _InMemoryStore implements SecureKeyValueStore {
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

Uint8List _key(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

void main() {
  late IdentityStore store;

  setUp(() {
    store = IdentityStore(
      engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
      store: _InMemoryStore(),
    );
  });

  group('safety number v1', () {
    test(
      'is order independent — both devices derive the same digits',
      () async {
        final a = _key(0x11);
        final b = _key(0x22);

        final fromA = await store.safetyNumber(
          localPublicKey: a,
          remotePublicKey: b,
        );
        final fromB = await store.safetyNumber(
          localPublicKey: b,
          remotePublicKey: a,
        );

        expect(fromA, fromB);
      },
    );

    test('is exactly sixty digits in twelve groups of five', () async {
      final n = await store.safetyNumber(
        localPublicKey: _key(0x01),
        remotePublicKey: _key(0xfe),
      );

      final groups = n.split(' ');
      expect(groups, hasLength(12));
      for (final g in groups) {
        expect(g, hasLength(5));
        expect(RegExp(r'^\d{5}$').hasMatch(g), isTrue, reason: g);
      }
      expect(n.replaceAll(' ', ''), hasLength(60));
    });

    test('a one-bit change in either key changes the number', () async {
      final base = await store.safetyNumber(
        localPublicKey: _key(0x11),
        remotePublicKey: _key(0x22),
      );

      final flipped = Uint8List.fromList(_key(0x22))..[31] ^= 0x01;
      final changed = await store.safetyNumber(
        localPublicKey: _key(0x11),
        remotePublicKey: flipped,
      );

      expect(changed, isNot(base));
    });

    test(
      'the two keys are not interchangeable with their concatenation',
      () async {
        // Guards the field boundary: two distinct pairs whose naive
        // concatenations would coincide must not collide.
        final one = await store.safetyNumber(
          localPublicKey: Uint8List.fromList([...List.filled(31, 0), 1]),
          remotePublicKey: Uint8List.fromList([2, ...List.filled(31, 0)]),
        );
        final two = await store.safetyNumber(
          localPublicKey: Uint8List.fromList([...List.filled(31, 0), 2]),
          remotePublicKey: Uint8List.fromList([1, ...List.filled(31, 0)]),
        );
        expect(one, isNot(two));
      },
    );

    test('uses every digit — the old byte-wise derivation could not', () async {
      // The previous version took digits as (b % 10) and (b ~/ 10 % 10), so
      // 6-9 appeared roughly half as often as 0-5 in the second position. Over
      // a sample this size the full alphabet should appear.
      final seen = <String>{};
      for (var i = 0; i < 40; i++) {
        final n = await store.safetyNumber(
          localPublicKey: _key(i),
          remotePublicKey: _key(0xff - i),
        );
        seen.addAll(n.replaceAll(' ', '').split(''));
      }
      expect(
        seen,
        hasLength(10),
        reason: 'digits seen: ${seen.toList()..sort()}',
      );
    });

    test('GOLDEN VECTOR — frozen, do not edit to make a change pass', () async {
      // sha256("vck-safety-number-v1" || 0x11*32 || 0x22*32), read as a
      // big-endian integer, modulo 10^60, padded to sixty digits.
      final n = await store.safetyNumber(
        localPublicKey: _key(0x11),
        remotePublicKey: _key(0x22),
      );
      expect(n, _goldenElevenTwentyTwo);
    });
  });
}

/// Filled in from the implementation on the day version 1 was frozen.
/// If this test fails, the derivation changed — that is the alarm, not a
/// stale expectation.
const String _goldenElevenTwentyTwo =
    '78243 25278 96118 32310 58385 11155 77209 47234 27409 30140 05543 41159';
