/// The bootstrap circularity, tested from both ends: a code a person can carry,
/// and the guarantee that carrying it by hand buys no extra trust.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// Accepts any signature whose first byte is 1 — enough to exercise the
/// accept/reject paths without pulling real crypto into a format test.
class _StubVerifier implements Ed25519Verifier {
  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async => signature.isNotEmpty && signature.first == 1;
}

Uint8List _sig({required bool good}) =>
    Uint8List.fromList([good ? 1 : 0, ...List.filled(63, 7)]);

Map<String, Object?> _manifestJson({int revision = 3}) {
  final now = DateTime.utc(2026, 8, 2, 12);
  return {
    // The current schema, by name: the fixture once hardcoded 1 and silently
    // went stale when the package moved to schema v2 (Phase 7 multi-origin).
    'schemaVersion': manifestSchemaVersion,
    'revision': revision,
    'signingKeyId': 'key-a',
    'issuedAt': now.subtract(const Duration(hours: 1)).toIso8601String(),
    'expiresAt': now.add(const Duration(days: 7)).toIso8601String(),
    'signalingEndpoints': ['wss://relay.example/signal'],
    'iceServers': [
      {
        'urls': ['turns:relay.example:443'],
        'username': 'u',
        'credential': 'c',
      },
      {
        'urls': ['stun:stun.example:3478'],
      },
    ],
    'configServiceUris': ['https://config.example/manifest'],
  };
}

List<int> _documentBytes({int revision = 3, bool goodSignature = true}) =>
    utf8.encode(
      jsonEncode({
        'manifest': _manifestJson(revision: revision),
        'alg': 'ed25519',
        'signature': base64Encode(_sig(good: goodSignature)),
      }),
    );

OobManifestImport _import({int lastAccepted = 0}) => OobManifestImport(
  verifier: ManifestVerifier(
    pinnedKeys: [
      PinnedManifestKey(keyId: 'key-a', publicKey: List.filled(32, 9)),
    ],
    crypto: _StubVerifier(),
  ),
  lastAcceptedRevision: () => lastAccepted,
);

final _now = DateTime.utc(2026, 8, 2, 12);

void main() {
  group('CompactManifestCode', () {
    test('round-trips arbitrary bytes', () {
      for (final length in [1, 2, 5, 31, 64, 255, 1000]) {
        final data = Uint8List.fromList(
          List.generate(length, (i) => (i * 37 + 11) & 0xFF),
        );
        final code = CompactManifestCode.encode(data);
        expect(CompactManifestCode.decode(code), data, reason: 'len $length');
      }
    });

    test('is readable: grouped, prefixed, and case-insensitive', () {
      final code = CompactManifestCode.encode(
        Uint8List.fromList(List.filled(40, 0xA5)),
      );
      expect(code.startsWith(CompactManifestCode.prefix), isTrue);
      expect(code, contains('-'));
      final data = CompactManifestCode.decode(code);
      expect(CompactManifestCode.decode(code.toLowerCase()), data);
      expect(CompactManifestCode.decode('  $code  '), data);
      expect(CompactManifestCode.decode(code.replaceAll('-', ' ')), data);
    });

    test('accepts the substitutions people actually make', () {
      // Crockford: O reads as 0, I and L read as 1. A code containing none of
      // those characters must still decode when a reader "corrects" them.
      final original = CompactManifestCode.encode(
        Uint8List.fromList([0x00, 0x11, 0x22]),
      );
      final body = original.substring(CompactManifestCode.prefix.length);
      final mangled =
          CompactManifestCode.prefix +
          body.replaceAll('0', 'O').replaceAll('1', 'I');
      expect(
        CompactManifestCode.decode(mangled),
        CompactManifestCode.decode(original),
      );
    });

    test('a single wrong symbol is caught, not silently accepted', () {
      final code = CompactManifestCode.encode(
        Uint8List.fromList(List.generate(64, (i) => i)),
      );
      final chars = code.split('');
      // Flip one alphabet character somewhere in the middle of the body.
      for (
        var i = code.length - 8;
        i > CompactManifestCode.prefix.length;
        i--
      ) {
        final c = chars[i];
        if (c == '-') continue;
        final idx = CompactManifestCode.alphabet.indexOf(c);
        chars[i] = CompactManifestCode.alphabet[(idx + 1) % 32];
        break;
      }
      expect(
        () => CompactManifestCode.decode(chars.join()),
        throwsA(
          isA<CompactDecodeException>().having(
            (e) => e.error,
            'error',
            CompactDecodeError.checksumMismatch,
          ),
        ),
      );
    });

    test(
      'rejects a missing prefix, a foreign character, and a huge payload',
      () {
        expect(
          () => CompactManifestCode.decode('ABCDE-FGHJK'),
          throwsA(
            isA<CompactDecodeException>().having(
              (e) => e.error,
              'error',
              CompactDecodeError.notACode,
            ),
          ),
        );
        expect(
          () =>
              CompactManifestCode.decode('${CompactManifestCode.prefix}AB!DE'),
          throwsA(
            isA<CompactDecodeException>().having(
              (e) => e.error,
              'error',
              CompactDecodeError.badCharacter,
            ),
          ),
        );
        expect(
          () => CompactManifestCode.encode(
            Uint8List(CompactManifestCode.maxPayloadBytes + 1),
          ),
          throwsA(
            isA<CompactDecodeException>().having(
              (e) => e.error,
              'error',
              CompactDecodeError.tooLarge,
            ),
          ),
        );
      },
    );

    test('a real signed document fits a scannable code', () {
      final bytes = _documentBytes();
      final code = CompactManifestCode.encode(bytes);
      // QR alphanumeric mode holds ~4,296 characters; staying well under it is
      // the property that matters, not the exact number.
      expect(code.length, lessThan(3000));
      expect(CompactManifestCode.decode(code), Uint8List.fromList(bytes));
    });
  });

  group('OobManifestImport', () {
    test(
      'a scanned code reaches the same verdict as the network path',
      () async {
        final code = CompactManifestCode.encode(_documentBytes());
        final result = await _import().importCode(code, now: _now);

        expect(result.accepted, isTrue);
        expect(result.manifest!.revision, 3);
        expect(result.manifest!.iceServers, hasLength(2));
        expect(result.source, OobManifestSource.scannedCode);
        expect(result.describe(), contains('accepted revision 3'));
      },
    );

    test(
      'carrying it by hand buys NO extra trust: a bad signature is rejected',
      () async {
        final code = CompactManifestCode.encode(
          _documentBytes(goodSignature: false),
        );
        final result = await _import().importCode(code, now: _now);

        expect(result.accepted, isFalse);
        expect(
          (result.verification! as ManifestRejected).reason,
          ManifestRejection.badSignature,
        );
      },
    );

    test(
      'rollback protection still applies to an out-of-band manifest',
      () async {
        // The device has already accepted revision 9; a code offering 3 is a
        // downgrade, and arriving on paper does not make it acceptable.
        final code = CompactManifestCode.encode(_documentBytes(revision: 3));
        final result = await _import(
          lastAccepted: 9,
        ).importCode(code, now: _now);

        expect(result.accepted, isFalse);
        expect(
          (result.verification! as ManifestRejected).reason,
          ManifestRejection.rollback,
        );
      },
    );

    test('the revision floor is read at import time, not captured', () async {
      var accepted = 0;
      final import = OobManifestImport(
        verifier: ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-a', publicKey: List.filled(32, 9)),
          ],
          crypto: _StubVerifier(),
        ),
        lastAcceptedRevision: () => accepted,
      );
      final code = CompactManifestCode.encode(_documentBytes(revision: 3));

      expect((await import.importCode(code, now: _now)).accepted, isTrue);

      // A network refresh lands revision 5 while the user is scanning.
      accepted = 5;
      final second = await import.importCode(code, now: _now);
      expect(second.accepted, isFalse);
      expect(
        (second.verification! as ManifestRejected).reason,
        ManifestRejection.rollback,
      );
    });

    test('a mis-scanned code is a READ failure, not a trust failure', () async {
      final code = CompactManifestCode.encode(_documentBytes());
      final broken = '${code.substring(0, code.length - 3)}ZZZ';
      final result = await _import().importCode(broken, now: _now);

      expect(result.decodeError, isNotNull);
      expect(result.verification, isNull);
      expect(result.accepted, isFalse);
      // The two failures call for opposite recoveries, so they must be
      // distinguishable: "read it again" versus "distrust the source".
      expect(result.describe(), contains('could not read'));
    });

    test('a sideloaded file imports as raw signed JSON', () async {
      final result = await _import().importBytes(
        _documentBytes(),
        source: OobManifestSource.file,
        now: _now,
      );
      expect(result.accepted, isTrue);
      expect(result.source, OobManifestSource.file);
    });

    test(
      'pasted text accepts either form without the user knowing which',
      () async {
        final import = _import();
        final asJson = await import.importText(
          utf8.decode(_documentBytes()),
          now: _now,
        );
        final asCode = await import.importText(
          CompactManifestCode.encode(_documentBytes()),
          now: _now,
        );

        expect(asJson.accepted, isTrue);
        expect(asCode.accepted, isTrue);
        expect(asJson.source, OobManifestSource.pastedText);
        expect(asCode.source, OobManifestSource.pastedText);
      },
    );

    test(
      'malformed JSON is rejected as malformed, never as a signature fault',
      () async {
        final result = await _import().importBytes(
          utf8.encode('{"manifest": "not-an-object"}'),
          now: _now,
        );
        expect(
          (result.verification! as ManifestRejected).reason,
          ManifestRejection.malformed,
        );
      },
    );
  });

  // X3 blackout drill, host-side scenarios (D2/D3/D4/D6). These prove the
  // import-path LOGIC against the real verifier; they cannot observe the
  // device UI wording, which stays a device-run responsibility.
  group('X3 blackout drill (host-side)', () {
    test(
      'D2: a tampered code surfaces as a READ failure, not a trust decision',
      () async {
        final code = CompactManifestCode.encode(_documentBytes());
        // Change ONE character in the middle of the body to a DIFFERENT
        // alphabet character, exactly as the drill prescribes.
        final chars = code.split('');
        final mid = code.length ~/ 2;
        var i = mid;
        while (chars[i] == '-') {
          i++;
        }
        final idx = CompactManifestCode.alphabet.indexOf(chars[i]);
        chars[i] = CompactManifestCode.alphabet[(idx + 1) % 32];
        final result = await _import().importCode(chars.join(), now: _now);

        expect(result.decodeError, isNotNull);
        expect(result.decodeError!.error, CompactDecodeError.checksumMismatch);
        // Never reached the verifier: no trust verdict exists, nothing stored.
        expect(result.verification, isNull);
        expect(result.accepted, isFalse);
        expect(result.describe(), contains('could not read'));
      },
    );

    test('D3: a manifest signed by a key outside the pinned set is rejected '
        'with unknownSigningKey', () async {
      final forged = _manifestJson()..['signingKeyId'] = 'key-not-pinned';
      final bytes = utf8.encode(
        jsonEncode({
          'manifest': forged,
          'alg': 'ed25519',
          'signature': base64Encode(_sig(good: true)),
        }),
      );
      final result = await _import().importCode(
        CompactManifestCode.encode(bytes),
        now: _now,
      );

      expect(result.accepted, isFalse);
      final rejected = result.verification! as ManifestRejected;
      expect(rejected.reason, ManifestRejection.unknownSigningKey);
      expect(result.describe(), contains('unknownSigningKey'));
    });

    test(
      'D4: a revision below the stored floor is rejected as rollback',
      () async {
        // Floor already at 5; the code carries revision 3.
        final code = CompactManifestCode.encode(_documentBytes(revision: 3));
        final result = await _import(
          lastAccepted: 5,
        ).importCode(code, now: _now);

        expect(result.accepted, isFalse);
        final rejected = result.verification! as ManifestRejected;
        expect(rejected.reason, ManifestRejection.rollback);
        expect(result.describe(), contains('rollback'));
      },
    );

    test('D6: rollback protection holds after an earlier accepted import '
        'advances the floor', () async {
      var floor = 0;
      final import = OobManifestImport(
        verifier: ManifestVerifier(
          pinnedKeys: [
            PinnedManifestKey(keyId: 'key-a', publicKey: List.filled(32, 9)),
          ],
          crypto: _StubVerifier(),
        ),
        lastAcceptedRevision: () => floor,
      );

      // First import: revision 5 accepted; the cache advances the floor.
      final first = await import.importCode(
        CompactManifestCode.encode(_documentBytes(revision: 5)),
        now: _now,
      );
      expect(first.accepted, isTrue);
      floor = first.manifest!.revision;

      // A later out-of-band code carrying revision 3 must now be a rollback,
      // because the floor is read at import time, not captured.
      final second = await import.importCode(
        CompactManifestCode.encode(_documentBytes(revision: 3)),
        now: _now,
      );
      expect(second.accepted, isFalse);
      final rejected = second.verification! as ManifestRejected;
      expect(rejected.reason, ManifestRejection.rollback);
    });
  });
}
