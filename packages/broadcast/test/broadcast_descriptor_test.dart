import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

Uint8List _hash(int fill) => Uint8List.fromList(List.filled(hashBytes, fill));

void main() {
  const verifier = CryptographyBroadcastVerifier();
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishing;
  late Uint8List authorId;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishing = await CryptographyBroadcastSigner.generate();
    authorId = authorIdFor(root.publicKey);
  });

  Future<BroadcastDescriptor> signGenesis({
    Map<int, Uint8List>? layers,
    DateTime? at,
  }) => BroadcastDescriptor.sign(
    signer: publishing,
    authorId: authorId,
    seq: 0,
    publishedAt: at ?? t0,
    prev: zeroHash,
    layers: layers ?? {LayerFlag.text: _hash(1)},
  );

  group('byte budget', () {
    test('a text-only descriptor is 147 bytes', () async {
      final d = await signGenesis();
      expect(d.encoded.length, 147);
      expect(descriptorSizeFor(LayerFlag.text), 147);
    });

    test('a descriptor with every layer is 243 bytes', () async {
      final d = await signGenesis(
        layers: {
          LayerFlag.text: _hash(1),
          LayerFlag.still: _hash(2),
          LayerFlag.voice: _hash(3),
          LayerFlag.mediaList: _hash(4),
        },
      );
      expect(d.encoded.length, 243);
      expect(
        descriptorSizeFor(
          LayerFlag.text |
              LayerFlag.still |
              LayerFlag.voice |
              LayerFlag.mediaList,
        ),
        243,
      );
      // The retraction slot is a fifth commitment, so the largest possible
      // descriptor is one hash wider than the largest possible post.
      expect(descriptorSizeFor(LayerFlag.known), 243 + hashBytes);
      expect(descriptorSizeFor(LayerFlag.known), 275);
    });

    test('a retraction costs one hash on top of what it says', () async {
      final plain = await signGenesis();
      final withdrawal = await BroadcastDescriptor.sign(
        signer: publishing,
        authorId: authorId,
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: _hash(1)},
        retracts: _hash(9),
      );
      expect(withdrawal.encoded.length, plain.encoded.length + hashBytes);
      expect(withdrawal.encoded.length, 179);
    });

    test('size grows by exactly one hash per added layer', () {
      expect(
        descriptorSizeFor(LayerFlag.text | LayerFlag.voice) -
            descriptorSizeFor(LayerFlag.text),
        hashBytes,
      );
    });
  });

  group('round trip', () {
    test('parse recovers every field', () async {
      final signed = await signGenesis(
        layers: {LayerFlag.text: _hash(9), LayerFlag.voice: _hash(11)},
      );
      final parsed = BroadcastDescriptor.parse(signed.encoded);
      expect(parsed, isNotNull);
      expect(parsed!.authorId, authorId);
      expect(parsed.seq, 0);
      expect(parsed.publishedAt, t0);
      expect(parsed.prev, zeroHash);
      expect(parsed.layer(LayerFlag.text), _hash(9));
      expect(parsed.layer(LayerFlag.voice), _hash(11));
      expect(parsed.layer(LayerFlag.still), isNull);
      expect(parsed.flags, LayerFlag.text | LayerFlag.voice);
      expect(parsed.isGenesis, isTrue);
      expect(bytesEqual(parsed.id, signed.id), isTrue);
    });

    test('the id is the content hash of the encoded bytes', () async {
      final signed = await signGenesis();
      expect(signed.id, contentHash(signed.encoded));
    });

    test('layer hashes keep their declared wire order', () async {
      // still before voice, whatever order the map was built in.
      final signed = await signGenesis(
        layers: {LayerFlag.voice: _hash(3), LayerFlag.still: _hash(2)},
      );
      final body = signed.encoded;
      final firstHashStart = 1 + 1 + authorIdBytes + 4 + 5 + hashBytes;
      expect(body[firstHashStart], 2, reason: 'still comes first');
    });

    test('sub-second precision is dropped, not rounded up', () async {
      final signed = await signGenesis(
        at: t0.add(const Duration(milliseconds: 999)),
      );
      expect(BroadcastDescriptor.parse(signed.encoded)!.publishedAt, t0);
    });
  });

  group('verify', () {
    test('accepts a descriptor signed by the delegated key', () async {
      final signed = await signGenesis();
      final verified = await BroadcastDescriptor.verify(
        encoded: signed.encoded,
        rootPublicKey: root.publicKey,
        publishingKey: publishing.publicKey,
        verifier: verifier,
      );
      expect(verified, isNotNull);
      expect(verified!.seq, 0);
    });

    test('refuses a descriptor re-attributed to another author', () async {
      final signed = await signGenesis();
      final other = await CryptographyBroadcastSigner.generate();
      final reasons = <DescriptorRejection>[];
      expect(
        await BroadcastDescriptor.verify(
          encoded: signed.encoded,
          rootPublicKey: other.publicKey,
          publishingKey: publishing.publicKey,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [DescriptorRejection.authorMismatch]);
    });

    test(
      'refuses a signature from a key the author did not delegate to',
      () async {
        final signed = await signGenesis();
        final impostor = await CryptographyBroadcastSigner.generate();
        final reasons = <DescriptorRejection>[];
        expect(
          await BroadcastDescriptor.verify(
            encoded: signed.encoded,
            rootPublicKey: root.publicKey,
            publishingKey: impostor.publicKey,
            verifier: verifier,
            onReject: reasons.add,
          ),
          isNull,
        );
        expect(reasons, [DescriptorRejection.badSignature]);
      },
    );

    test('every body byte is covered by the signature', () async {
      final signed = await signGenesis(
        layers: {LayerFlag.text: _hash(1), LayerFlag.mediaList: _hash(2)},
      );
      final bodyLength = signed.encoded.length - 64;
      for (var i = 0; i < bodyLength; i++) {
        final tampered = Uint8List.fromList(signed.encoded);
        // Flipping the flags byte changes the expected length, which the
        // length check catches first; either refusal is correct, and both
        // are refusals.
        tampered[i] ^= 0x01;
        final result = await BroadcastDescriptor.verify(
          encoded: tampered,
          rootPublicKey: root.publicKey,
          publishingKey: publishing.publicKey,
          verifier: verifier,
        );
        expect(result, isNull, reason: 'byte $i must not verify');
      }
    });

    test('a swapped layer hash does not verify', () async {
      // The concrete attack the descriptor exists to stop: pairing one
      // post's voice with another post's text.
      final signed = await signGenesis(
        layers: {LayerFlag.text: _hash(1), LayerFlag.voice: _hash(2)},
      );
      final swapped = Uint8List.fromList(signed.encoded);
      final start = 1 + 1 + authorIdBytes + 4 + 5 + hashBytes;
      for (var i = 0; i < hashBytes; i++) {
        final a = swapped[start + i];
        swapped[start + i] = swapped[start + hashBytes + i];
        swapped[start + hashBytes + i] = a;
      }
      expect(
        await BroadcastDescriptor.verify(
          encoded: swapped,
          rootPublicKey: root.publicKey,
          publishingKey: publishing.publicKey,
          verifier: verifier,
        ),
        isNull,
      );
    });
  });

  group('hostile and malformed input', () {
    test('too short to be a descriptor', () {
      final reasons = <DescriptorRejection>[];
      expect(
        BroadcastDescriptor.parse(Uint8List(20), onReject: reasons.add),
        isNull,
      );
      expect(reasons, [DescriptorRejection.malformed]);
    });

    test('an unknown version is refused', () async {
      final signed = await signGenesis();
      final bad = Uint8List.fromList(signed.encoded)..[0] = 2;
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.unsupportedVersion]);
    });

    test('an unknown layer flag is refused, not skipped', () async {
      // A future layer bit shifts every field after it, so parsing
      // hopefully would mis-read the whole record.
      final signed = await signGenesis();
      final bad = Uint8List.fromList(signed.encoded)..[1] |= 0x80;
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.unknownLayerFlag]);
    });

    test('a descriptor with no layers is refused', () async {
      final signed = await signGenesis();
      final bad = Uint8List.fromList(signed.encoded)..[1] = 0;
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.noLayers]);
    });

    test('trailing bytes are refused rather than ignored', () async {
      final signed = await signGenesis();
      final padded = Uint8List.fromList([...signed.encoded, 0, 0]);
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(padded, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.wrongLength]);
    });

    test('a genesis that links backward is refused', () async {
      final signed = await signGenesis();
      final bad = Uint8List.fromList(signed.encoded);
      bad[1 + 1 + authorIdBytes + 4 + 5] = 0x01;
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.genesisMustNotLink]);
    });

    test('a non-genesis with no link is refused', () async {
      final signed = await BroadcastDescriptor.sign(
        signer: publishing,
        authorId: authorId,
        seq: 4,
        publishedAt: t0,
        prev: _hash(7),
        layers: {LayerFlag.text: _hash(1)},
      );
      final bad = Uint8List.fromList(signed.encoded);
      final prevStart = 1 + 1 + authorIdBytes + 4 + 5;
      for (var i = 0; i < hashBytes; i++) {
        bad[prevStart + i] = 0;
      }
      final reasons = <DescriptorRejection>[];
      expect(BroadcastDescriptor.parse(bad, onReject: reasons.add), isNull);
      expect(reasons, [DescriptorRejection.nonGenesisMustLink]);
    });
  });

  group('signing argument checks', () {
    test('refuses an empty layer set', () {
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: const {},
        ),
        throwsArgumentError,
      );
    });

    test('refuses an unknown flag, a short hash, and a short author id', () {
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: {0x80: _hash(1)},
        ),
        throwsArgumentError,
      );
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: {LayerFlag.text: Uint8List(31)},
        ),
        throwsArgumentError,
      );
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: Uint8List(7),
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: {LayerFlag.text: _hash(1)},
        ),
        throwsArgumentError,
      );
    });

    test('refuses an inconsistent genesis link in either direction', () {
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 0,
          publishedAt: t0,
          prev: _hash(5),
          layers: {LayerFlag.text: _hash(1)},
        ),
        throwsArgumentError,
      );
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 1,
          publishedAt: t0,
          prev: zeroHash,
          layers: {LayerFlag.text: _hash(1)},
        ),
        throwsArgumentError,
      );
    });

    test('refuses a time that does not fit five bytes', () {
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: 0,
          publishedAt: DateTime.utc(1960),
          prev: zeroHash,
          layers: {LayerFlag.text: _hash(1)},
        ),
        throwsArgumentError,
      );
    });
  });
}
