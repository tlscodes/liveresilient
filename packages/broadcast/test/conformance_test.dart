/// The Dart side of the shared wire vectors.
///
/// Two implementations parse this format — this client and the JavaScript
/// relay — and until these vectors existed each knew the layout only from
/// its own code. That is exactly how two implementations drift: nothing
/// fails until a deployment mixes an old reader with a new writer, in the
/// one situation where nobody can debug it.
///
/// The file is the format written down. If a change here fails, either the
/// wire format changed on purpose — regenerate and commit, and expect the
/// relay's own conformance test to fail until it is taught the same thing —
/// or it changed by accident, which is the case this exists for.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

Uint8List _bytes(String hex) => hexDecode(hex);

void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    final file = File('test/conformance/wire_vectors.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run: dart run tool/emit_conformance_vectors.dart',
    );
    vectors = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('the vectors are for a format version this build speaks', () {
    expect(vectors['version'], 1);
  });

  test('the fixed seeds still produce the recorded keys', () async {
    // If this fails, the key derivation changed and every recorded byte
    // below is meaningless — so it is checked first.
    final keys = vectors['keys'] as Map<String, dynamic>;
    final root = await CryptographyBroadcastSigner.fromSeed(
      _bytes(keys['rootSeedHex'] as String),
    );
    expect(hexEncode(root.publicKey), keys['rootPublicKeyHex']);
    expect(hexEncode(authorIdFor(root.publicKey)), keys['authorIdHex']);

    final publishing = await CryptographyBroadcastSigner.fromSeed(
      _bytes(keys['publishingSeedHex'] as String),
    );
    expect(hexEncode(publishing.publicKey), keys['publishingPublicKeyHex']);
  });

  test('the recorded certificate parses and verifies', () async {
    final keys = vectors['keys'] as Map<String, dynamic>;
    final record = vectors['certificate'] as Map<String, dynamic>;
    final encoded = _bytes(record['encodedHex'] as String);

    expect(encoded.length, record['byteLength']);
    expect(encoded.length, certificateBytes);

    final parsed = await PublishingKeyCertificate.verify(
      encoded: encoded,
      rootPublicKey: _bytes(keys['rootPublicKeyHex'] as String),
      verifier: const CryptographyBroadcastVerifier(),
      now: DateTime.fromMillisecondsSinceEpoch(
        (record['notBeforeSeconds'] as int) * 1000,
        isUtc: true,
      ),
    );
    expect(parsed, isNotNull);
    expect(hexEncode(parsed!.publishingKey), keys['publishingPublicKeyHex']);
    expect(
      parsed.notAfter.millisecondsSinceEpoch ~/ 1000,
      record['notAfterSeconds'],
    );
  });

  test(
    'every recorded descriptor parses to exactly what was recorded',
    () async {
      final keys = vectors['keys'] as Map<String, dynamic>;
      final rootKey = _bytes(keys['rootPublicKeyHex'] as String);
      final publishingKey = _bytes(keys['publishingPublicKeyHex'] as String);

      for (final entry in vectors['descriptors'] as List<dynamic>) {
        final record = entry as Map<String, dynamic>;
        final encoded = _bytes(record['encodedHex'] as String);
        final name = record['name'];

        expect(encoded.length, record['byteLength'], reason: '$name length');

        final verified = await BroadcastDescriptor.verify(
          encoded: encoded,
          rootPublicKey: rootKey,
          publishingKey: publishingKey,
          verifier: const CryptographyBroadcastVerifier(),
        );
        expect(verified, isNotNull, reason: '$name must verify');
        expect(verified!.seq, record['seq'], reason: '$name seq');
        expect(verified.flags, record['flags'], reason: '$name flags');
        expect(
          verified.publishedAt.millisecondsSinceEpoch ~/ 1000,
          record['publishedAtSeconds'],
          reason: '$name time',
        );
        expect(hexEncode(verified.id), record['idHex'], reason: '$name id');
        if (record.containsKey('prevHex')) {
          expect(hexEncode(verified.prev), record['prevHex']);
        }
        if (record.containsKey('retractsHex')) {
          expect(
            verified.isRetraction,
            isTrue,
            reason: '$name is a retraction',
          );
          expect(hexEncode(verified.retracts!), record['retractsHex']);
        } else {
          expect(verified.retracts, isNull, reason: '$name withdraws nothing');
        }
      }
    },
  );

  test(
    'the recorded relay directory verifies with its origins intact',
    () async {
      final keys = vectors['keys'] as Map<String, dynamic>;
      final record = vectors['relayDirectory'] as Map<String, dynamic>;
      final parsed = await RelayDirectory.verify(
        encoded: _bytes(record['encodedHex'] as String),
        rootPublicKey: _bytes(keys['rootPublicKeyHex'] as String),
        verifier: const CryptographyBroadcastVerifier(),
        now: DateTime.utc(2026, 2, 1),
      );
      expect(parsed, isNotNull);
      expect(parsed!.seq, record['seq']);
      expect(
        parsed.origins.map((u) => u.toString()).toList(),
        record['origins'],
      );
    },
  );

  test('the recorded bootstrap code parses from text and from bytes', () {
    final record = vectors['bootstrapCode'] as Map<String, dynamic>;
    final fromText = BootstrapCode.parse(record['text'] as String);
    final fromBytes = BootstrapCode.decodeBytes(
      _bytes(record['encodedHex'] as String),
    );
    expect(fromText, isNotNull);
    expect(fromText, fromBytes);
    expect(fromText!.host, record['host']);
    expect(
      hexEncode(fromText.rootPublicKey),
      (vectors['keys'] as Map<String, dynamic>)['rootPublicKeyHex'],
    );
  });

  test('the recorded addresses are the ones this build builds', () {
    final keys = vectors['keys'] as Map<String, dynamic>;
    final record = vectors['addresses'] as Map<String, dynamic>;
    final authorId = _bytes(keys['authorIdHex'] as String);

    expect(
      DescriptorAddress(authorId: authorId, seq: 41).path,
      record['descriptorPath'],
    );
    expect(
      ObjectAddress(contentHash(Uint8List.fromList([1, 2, 3]))).path,
      record['objectPath'],
    );
    expect(immutableCacheControl, record['immutableCacheControl']);
    // And they parse back, which is the property a relay depends on.
    expect(
      DescriptorAddress.tryParse(record['descriptorPath'] as String),
      isNotNull,
    );
    expect(ObjectAddress.tryParse(record['objectPath'] as String), isNotNull);
  });

  test('the recorded auth header is what this build sends', () async {
    final keys = vectors['keys'] as Map<String, dynamic>;
    final record = vectors['authHeader'] as Map<String, dynamic>;
    expect(broadcastAuthHeader, record['name']);

    final credentials = BroadcastCredentials(
      rootPublicKey: _bytes(keys['rootPublicKeyHex'] as String),
      certificate: _bytes(
        (vectors['certificate'] as Map<String, dynamic>)['encodedHex']
            as String,
      ),
    );
    expect(credentials.headerValue, record['value']);
  });

  test('regenerating the vectors would produce the same bytes', () async {
    // The generator is deterministic, so a run that changed the file would
    // mean the format moved. Checked here rather than trusted, because a
    // vector file that quietly drifts is worse than none.
    final keys = vectors['keys'] as Map<String, dynamic>;
    final publishing = await CryptographyBroadcastSigner.fromSeed(
      _bytes(keys['publishingSeedHex'] as String),
    );
    final rebuilt = await BroadcastDescriptor.sign(
      signer: publishing,
      authorId: _bytes(keys['authorIdHex'] as String),
      seq: 0,
      publishedAt: DateTime.utc(2026, 1, 1, 12),
      prev: zeroHash,
      layers: {
        LayerFlag.text: contentHash(Uint8List.fromList([1, 2, 3])),
      },
    );
    final recorded =
        (vectors['descriptors'] as List<dynamic>).first as Map<String, dynamic>;
    expect(hexEncode(rebuilt.encoded), recorded['encodedHex']);
  });
}
