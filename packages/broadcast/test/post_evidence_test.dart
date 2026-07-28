/// Proving a post to someone who does not have the app.
///
/// A signature only means something to whoever can check it. A message
/// spreads by screenshot, and a screenshot carries no signature — so the
/// thing people actually pass around was exactly the thing nobody could
/// verify. An evidence bundle is that gap closed.
library;

import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

Uint8List _text(String value) => Uint8List.fromList(value.codeUnits);

void main() {
  const verifier = CryptographyBroadcastVerifier();
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishingKey;
  late PublishingKeyCertificate certificate;
  late Uint8List authorId;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishingKey = await CryptographyBroadcastSigner.generate();
    authorId = authorIdFor(root.publicKey);
    certificate = await PublishingKeyCertificate.issue(
      rootSigner: root,
      publishingKey: publishingKey.publicKey,
      notBefore: t0,
      notAfter: t0.add(const Duration(days: 7)),
    );
  });

  Future<BroadcastDescriptor> post(Uint8List text, {int seq = 0}) =>
      BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorId,
        seq: seq,
        publishedAt: t0,
        prev: seq == 0 ? zeroHash : contentHash(_text('prev')),
        layers: {LayerFlag.text: contentHash(text)},
      );

  group('a bundle proves what it carries', () {
    test('it verifies with nothing fetched and nobody trusted', () async {
      final text = _text('the bridge is closed');
      final encoded = PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      );

      final evidence = await PostEvidence.verify(
        encoded: encoded,
        verifier: verifier,
      );
      expect(evidence, isNotNull);
      expect(evidence!.text, text);
      expect(evidence.seq, 0);
      expect(bytesEqual(evidence.authorId, authorId), isTrue);
      expect(evidence.publishedAt, t0);
    });

    test('it is small enough to paste', () async {
      final text = _text('the bridge is closed; do not go north');
      final encoded = PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      );
      // Key, certificate, descriptor, framing, and the words themselves.
      expect(encoded.length, lessThan(400));
    });

    test('it still verifies long after the certificate expired', () async {
      // Evidence is about the past. A proof that stopped working when the
      // delegation lapsed would be useless for the thing it exists for.
      final text = _text('said at the time');
      final encoded = PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      );
      expect(
        await PostEvidence.verify(encoded: encoded, verifier: verifier),
        isNotNull,
      );
    });

    test(
      'a retraction carries through, so a withdrawal can be proved too',
      () async {
        final text = _text('correction: the bridge is closed');
        final correction = await BroadcastDescriptor.sign(
          signer: publishingKey,
          authorId: authorId,
          seq: 1,
          publishedAt: t0,
          prev: contentHash(_text('prev')),
          layers: {LayerFlag.text: contentHash(text)},
          retracts: contentHash(_text('the withdrawn post')),
        );
        final evidence = await PostEvidence.verify(
          encoded: PostEvidence.build(
            rootPublicKey: root.publicKey,
            certificate: certificate,
            descriptor: correction,
            text: text,
          ),
          verifier: verifier,
        );
        expect(evidence!.descriptor.isRetraction, isTrue);
      },
    );
  });

  group('what it refuses', () {
    Future<Uint8List> goodBundle() async {
      final text = _text('a message');
      return PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      );
    }

    test('text that is not what was signed', () async {
      // The attack the whole thing exists to stop: a screenshot says one
      // thing, the signature covers another.
      final text = _text('the bridge is closed');
      final descriptor = await post(text);
      expect(
        () => PostEvidence.build(
          rootPublicKey: root.publicKey,
          certificate: certificate,
          descriptor: descriptor,
          text: _text('the bridge is open'),
        ),
        throwsArgumentError,
      );
    });

    test('a bundle whose text was swapped after the fact', () async {
      final bundle = await goodBundle();
      // Flip a byte in the trailing text, leaving the signature intact.
      final tampered = Uint8List.fromList(bundle)..[bundle.length - 1] ^= 0x01;
      final reasons = <EvidenceRejection>[];
      expect(
        await PostEvidence.verify(
          encoded: tampered,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [EvidenceRejection.textDoesNotMatch]);
    });

    test('a certificate not signed by the key the bundle names', () async {
      final stranger = await CryptographyBroadcastSigner.generate();
      final text = _text('a message');
      final bundle = PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      );
      // Swap in someone else's root key: the certificate no longer names
      // it, so the chain breaks at its first link.
      final swapped = Uint8List.fromList(bundle)
        ..setRange(1, 33, stranger.publicKey);
      final reasons = <EvidenceRejection>[];
      expect(
        await PostEvidence.verify(
          encoded: swapped,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [EvidenceRejection.badCertificate]);
    });

    test('a post with no text has nothing to quote', () async {
      final descriptor = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorId,
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.still: contentHash(_text('a photo'))},
      );
      expect(
        () => PostEvidence.build(
          rootPublicKey: root.publicKey,
          certificate: certificate,
          descriptor: descriptor,
          text: _text('anything'),
        ),
        throwsArgumentError,
      );
    });

    test('malformed and truncated input, without throwing', () async {
      final bundle = await goodBundle();
      for (final bytes in [
        Uint8List(0),
        Uint8List(20),
        Uint8List.fromList(bundle.sublist(0, bundle.length - 3)),
        Uint8List.fromList([...bundle, 0]),
        Uint8List.fromList(List.filled(400, 0xFF)),
      ]) {
        expect(
          await PostEvidence.verify(encoded: bytes, verifier: verifier),
          isNull,
        );
      }
    });

    test('an unknown version', () async {
      final bundle = await goodBundle()
        ..[0] = 9;
      final reasons = <EvidenceRejection>[];
      expect(
        await PostEvidence.verify(
          encoded: bundle,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [EvidenceRejection.unsupportedVersion]);
    });

    test('every single-bit flip of the signed region', () async {
      final bundle = await goodBundle();
      for (var index = 0; index < bundle.length; index += 5) {
        final flipped = Uint8List.fromList(bundle)..[index] ^= 0x01;
        expect(
          await PostEvidence.verify(encoded: flipped, verifier: verifier),
          isNull,
          reason: 'byte $index must not verify',
        );
      }
    });

    test('a wrong-sized root key or an oversized text', () async {
      final text = _text('a message');
      final descriptor = await post(text);
      expect(
        () => PostEvidence.build(
          rootPublicKey: Uint8List(31),
          certificate: certificate,
          descriptor: descriptor,
          text: text,
        ),
        throwsArgumentError,
      );

      final huge = Uint8List(maxEvidenceTextBytes + 1);
      final hugePost = await post(huge);
      expect(
        () => PostEvidence.build(
          rootPublicKey: root.publicKey,
          certificate: certificate,
          descriptor: hugePost,
          text: huge,
        ),
        throwsArgumentError,
      );
    });
  });

  test('what it proves is narrow, and the bundle says only that', () async {
    // The bundle carries the author's key and nothing that claims to say
    // whose key it is. That restraint is the design: a verifier that
    // implied identity would be worse than none.
    final text = _text('a message');
    final evidence = await PostEvidence.verify(
      encoded: PostEvidence.build(
        rootPublicKey: root.publicKey,
        certificate: certificate,
        descriptor: await post(text),
        text: text,
      ),
      verifier: verifier,
    );
    expect(evidence!.rootPublicKey, root.publicKey);
    expect(bytesEqual(evidence.authorId, authorIdFor(root.publicKey)), isTrue);
  });
}
