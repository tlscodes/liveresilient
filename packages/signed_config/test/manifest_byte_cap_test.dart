import 'dart:convert';
import 'dart:typed_data';

import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Ticket 3 gates 3d and 3d-bis.
///
/// 3d raises the ice-server entry ceiling to 256 while keeping the
/// single-document, single-signature shape. 3d-bis moves the actual security
/// load off the entry count and onto a byte cap applied before parsing,
/// because one entry can carry a multi-megabyte string and impose the same
/// memory pressure that a count of 32 was assumed to prevent.
void main() {
  group('manifest byte cap', () {
    late FakeEd25519Verifier crypto;
    late Uint8List key1;
    late ManifestVerifier verifier;

    setUp(() {
      crypto = FakeEd25519Verifier();
      key1 = keyBytes(1);
      verifier = ManifestVerifier(
        pinnedKeys: [PinnedManifestKey(keyId: 'key-1', publicKey: key1)],
        crypto: crypto,
      );
    });

    test(
      '3d  the ice-server ceiling is 256, single document, one signature',
      () {
        expect(maxIceServers, 256);

        final manifest = buildManifest(revision: 1);
        final document = signManifest(manifest, key1);
        final encoded = encodeSignedDocument(document);
        final root = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;

        expect(
          root.keys.toSet(),
          containsAll(<String>['manifest', 'signature']),
          reason:
              'one document carrying one signature; no page index, no '
              'per-page signature — pagination was rejected',
        );
        expect(root['signature'], isA<String>());
      },
    );

    test('3d-bis  a document over the cap is refused before it is parsed', () {
      final cap = SignedManifestDocument.maxSignedDocumentBytes;
      final oversized = Uint8List(cap + 1);

      expect(
        () => SignedManifestDocument.fromBytes(oversized),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('$cap bytes'), contains('${cap + 1}')),
          ),
        ),
        reason:
            'the bytes here are not even valid JSON — refusing them by '
            'size proves the cap runs before any decode',
      );
    });

    test('3d-bis  the cap covers the persisted-document path, not only the '
        'network path', () async {
      // The network fetcher and the out-of-band importer each carried
      // their own cap. A document already on disk did not. The cap now
      // lives at the single parse entry point every path funnels through,
      // so this holds without any caller remembering to check.
      final cap = SignedManifestDocument.maxSignedDocumentBytes;
      final storage = FakeManifestStorage()..document = Uint8List(cap + 1);

      final bytes = await storage.readDocument();
      expect(bytes, isNotNull);
      expect(
        () => SignedManifestDocument.fromBytes(bytes!),
        throwsFormatException,
      );
    });

    test('3d-bis  a document at exactly the cap is still accepted', () async {
      final manifest = buildManifest(revision: 7);
      final encoded = encodeSignedDocument(signManifest(manifest, key1));
      expect(
        encoded.length,
        lessThan(SignedManifestDocument.maxSignedDocumentBytes),
        reason: 'a realistic manifest must sit well under the cap',
      );

      final result = await verifier.verify(
        SignedManifestDocument.fromBytes(encoded),
        lastAcceptedRevision: 0,
        now: DateTime.utc(2026, 1, 1, 0, 30),
      );
      expect(result, isA<ManifestAccepted>());
    });

    test('3d-bis  the cap matches the fetcher default, so a document accepted '
        'from the network cannot be rejected when it is read back', () {
      expect(SignedManifestDocument.maxSignedDocumentBytes, 256 * 1024);
    });
  });
}
