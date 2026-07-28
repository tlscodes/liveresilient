/// Properties, not examples.
///
/// The hand-written tests in this package each check a case someone thought
/// of. These check laws that must hold for every input, over thousands of
/// randomly generated ones, plus every truncation and every single-bit flip
/// of a well-formed record.
///
/// Two laws, and both matter for a format that parses hostile bytes:
///
///  * **Round trip.** `decode(encode(x))` is `x`. A format that loses or
///    changes a field under its own codec will lose it on the wire.
///  * **Total parsing.** No input, however malformed, makes a decoder
///    throw. Every decoder here returns null or a value, because the caller
///    is always holding bytes from someone untrusted and a crash is a
///    denial of service with extra steps.
///
/// Seeded, so a failure names a reproducible input rather than a mood.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

/// Every decoder in the package, as a uniform "bytes in, something or
/// nothing out" function that must never throw.
final Map<String, Object? Function(Uint8List)> _decoders = {
  'descriptor': BroadcastDescriptor.parse,
  'hashList': LayerHashList.parse,
  'bootstrapCode': BootstrapCode.decodeBytes,
  'certificateWindow': PublishingKeyCertificate.parseWindowStart,
};

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

void main() {
  group('no decoder throws, whatever it is handed', () {
    test('on uniformly random bytes', () {
      final random = Random(20260728);
      for (var trial = 0; trial < 4000; trial++) {
        final bytes = _randomBytes(random, random.nextInt(300));
        for (final entry in _decoders.entries) {
          expect(
            () => entry.value(bytes),
            returnsNormally,
            reason: '${entry.key} threw on ${bytes.length} random bytes',
          );
        }
      }
    });

    test('on bytes that start out plausible', () {
      // Pure noise rarely gets past a version byte, so this seeds the first
      // bytes with values the decoders accept and lets the rest be random —
      // where the interesting failures live.
      final random = Random(4093);
      for (var trial = 0; trial < 4000; trial++) {
        final bytes = _randomBytes(random, 6 + random.nextInt(280));
        bytes[0] = 1;
        for (final entry in _decoders.entries) {
          expect(
            () => entry.value(bytes),
            returnsNormally,
            reason: '${entry.key} threw on a plausible-looking input',
          );
        }
      }
    });

    test('on every prefix of a well-formed record', () async {
      // Truncation is what a half-delivered fetch actually looks like.
      final root = await CryptographyBroadcastSigner.generate();
      final publishing = await CryptographyBroadcastSigner.generate();
      final descriptor = await BroadcastDescriptor.sign(
        signer: publishing,
        authorId: authorIdFor(root.publicKey),
        seq: 7,
        publishedAt: DateTime.utc(2026, 7, 28),
        prev: contentHash(Uint8List.fromList([1])),
        layers: {
          LayerFlag.text: contentHash(Uint8List.fromList([2])),
          LayerFlag.mediaList: contentHash(Uint8List.fromList([3])),
        },
      );
      final samples = <Uint8List>[
        descriptor.encoded,
        LayerHashList.build(_randomBytes(Random(1), 200 * 1024)).encoded,
        BootstrapCode(
          host: 'relay.example',
          rootPublicKey: root.publicKey,
        ).encodeBytes(),
      ];
      for (final sample in samples) {
        for (var length = 0; length <= sample.length; length++) {
          final prefix = Uint8List.sublistView(sample, 0, length);
          for (final entry in _decoders.entries) {
            expect(
              () => entry.value(Uint8List.fromList(prefix)),
              returnsNormally,
              reason: '${entry.key} threw on a $length-byte prefix',
            );
          }
        }
      }
    });

    test('on every single-bit flip of a well-formed record', () async {
      // One flipped bit is what damage looks like when it survives a
      // length check, and it is the input most likely to walk a parser
      // into a branch its author never pictured.
      final code = BootstrapCode(
        host: 'relay.example',
        rootPublicKey: Uint8List.fromList(List.filled(32, 5)),
      ).encodeBytes();
      for (var index = 0; index < code.length; index++) {
        for (var bit = 0; bit < 8; bit++) {
          final flipped = Uint8List.fromList(code)..[index] ^= 1 << bit;
          for (final entry in _decoders.entries) {
            expect(
              () => entry.value(flipped),
              returnsNormally,
              reason: '${entry.key} threw on bit $bit of byte $index',
            );
          }
        }
      }
    });
  });

  group('round trips hold for every generated value', () {
    test('descriptor, over random layer sets, sequences and times', () async {
      final random = Random(11);
      final root = await CryptographyBroadcastSigner.generate();
      final publishing = await CryptographyBroadcastSigner.generate();
      final authorId = authorIdFor(root.publicKey);

      for (var trial = 0; trial < 200; trial++) {
        final flags = 1 + random.nextInt(15);
        final layers = <int, Uint8List>{
          for (final flag in LayerFlag.ordered)
            if ((flags & flag) != 0)
              flag: contentHash(_randomBytes(random, 1 + random.nextInt(40))),
        };
        final seq = random.nextInt(0xFFFFFF);
        final seconds = 1600000000 + random.nextInt(200000000);
        final signed = await BroadcastDescriptor.sign(
          signer: publishing,
          authorId: authorId,
          seq: seq,
          publishedAt: DateTime.fromMillisecondsSinceEpoch(
            seconds * 1000,
            isUtc: true,
          ),
          prev: seq == 0 ? zeroHash : contentHash(_randomBytes(random, 8)),
          layers: layers,
        );

        final parsed = BroadcastDescriptor.parse(signed.encoded);
        expect(parsed, isNotNull, reason: 'trial $trial');
        expect(parsed!.seq, seq);
        expect(parsed.flags, flags);
        expect(parsed.publishedAt.millisecondsSinceEpoch ~/ 1000, seconds);
        expect(bytesEqual(parsed.id, signed.id), isTrue);
        for (final entry in layers.entries) {
          expect(bytesEqual(parsed.layer(entry.key)!, entry.value), isTrue);
        }
        // Re-encoding what was parsed reproduces the exact bytes: the
        // codec has no hidden state and no lossy field.
        expect(parsed.encoded, signed.encoded);
      }
    });

    test('hash list, over random sizes and chunkings', () {
      final random = Random(13);
      for (var trial = 0; trial < 120; trial++) {
        final chunkSize =
            minChunkSize + random.nextInt(maxChunkSize - minChunkSize);
        final length = 1 + random.nextInt(chunkSize * 3);
        final data = _randomBytes(random, length);
        final built = LayerHashList.build(data, chunkSize: chunkSize);
        final parsed = LayerHashList.parse(built.encoded);

        expect(parsed, isNotNull, reason: 'trial $trial');
        expect(parsed!.encoded, built.encoded);
        expect(parsed.totalLength, length);
        expect(parsed.chunkSize, chunkSize);
        expect(parsed.chunkCount, built.chunkCount);
        // Every chunk verifies, and the lengths sum back to the whole.
        var total = 0;
        for (var i = 0; i < parsed.chunkCount; i++) {
          final chunk = built.chunkOf(data, i);
          expect(parsed.verifyChunk(i, chunk), isTrue, reason: 'chunk $i');
          total += chunk.length;
        }
        expect(total, length);
      }
    });

    test('bootstrap code, over random hosts and keys', () {
      final random = Random(17);
      const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789-.';
      for (var trial = 0; trial < 500; trial++) {
        final host = String.fromCharCodes([
          // A leading letter, so the generated host is always a plausible
          // one rather than something the constructor would refuse.
          alphabet.codeUnitAt(random.nextInt(26)),
          for (var i = 0; i < random.nextInt(30); i++)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]);
        final code = BootstrapCode(
          host: host,
          rootPublicKey: _randomBytes(random, 32),
        );
        expect(
          BootstrapCode.parse(code.encode()),
          code,
          reason: 'trial $trial',
        );
        expect(BootstrapCode.decodeBytes(code.encodeBytes()), code);
        expect(
          BootstrapCode.parse(code.encode(grouped: false)),
          code,
          reason: 'grouping must not be load-bearing',
        );
      }
    });

    test('relay directory, over random origin lists', () async {
      final random = Random(19);
      final root = await CryptographyBroadcastSigner.generate();
      const verifier = CryptographyBroadcastVerifier();
      final now = DateTime.utc(2026, 7, 28);

      for (var trial = 0; trial < 60; trial++) {
        final count = 1 + random.nextInt(maxDirectoryRelays);
        final origins = [
          for (var i = 0; i < count; i++)
            Uri.parse(
              random.nextBool()
                  ? 'https://r$i-$trial.example'
                  : 'http://r$i-$trial.example:${1024 + random.nextInt(60000)}',
            ),
        ];
        final directory = await RelayDirectory.issue(
          rootSigner: root,
          origins: origins,
          seq: trial + 1,
          notAfter: now.add(Duration(days: 1 + random.nextInt(300))),
        );
        final parsed = await RelayDirectory.verify(
          encoded: directory.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: now,
        );
        expect(parsed, isNotNull, reason: 'trial $trial');
        expect(parsed!.encoded, directory.encoded);
        expect(parsed.seq, trial + 1);
        expect(
          parsed.origins.map((u) => u.toString()),
          directory.origins.map((u) => u.toString()),
        );
      }
    });

    test('publishing certificate, over random windows', () async {
      final random = Random(23);
      final root = await CryptographyBroadcastSigner.generate();
      const verifier = CryptographyBroadcastVerifier();

      for (var trial = 0; trial < 60; trial++) {
        final start = DateTime.fromMillisecondsSinceEpoch(
          (1700000000 + random.nextInt(100000000)) * 1000,
          isUtc: true,
        );
        final window = Duration(minutes: 1 + random.nextInt(44640));
        final publishing = await CryptographyBroadcastSigner.generate();
        final issued = await PublishingKeyCertificate.issue(
          rootSigner: root,
          publishingKey: publishing.publicKey,
          notBefore: start,
          notAfter: start.add(window),
        );
        final parsed = await PublishingKeyCertificate.verify(
          encoded: issued.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: start,
        );
        expect(parsed, isNotNull, reason: 'trial $trial');
        expect(parsed!.encoded, issued.encoded);
        expect(parsed.notBefore, start);
        expect(parsed.publishingKey, publishing.publicKey);
        expect(
          PublishingKeyCertificate.parseWindowStart(issued.encoded),
          start,
        );
      }
    });

    test('addresses, over the whole sequence space', () {
      final random = Random(29);
      for (var trial = 0; trial < 2000; trial++) {
        final authorId = _randomBytes(random, authorIdBytes);
        final seq = trial < 3
            ? [0, 1, maxSeq][trial]
            : random.nextInt(0xFFFFFFF);
        final address = DescriptorAddress(authorId: authorId, seq: seq);
        expect(DescriptorAddress.tryParse(address.path), address);

        final object = ObjectAddress(contentHash(_randomBytes(random, 16)));
        expect(ObjectAddress.tryParse(object.path), object);
      }
    });
  });

  group('a signature covers everything a record claims', () {
    test('no single-bit flip of a descriptor body verifies', () async {
      // Exhaustive rather than sampled: every bit of the signed region.
      final root = await CryptographyBroadcastSigner.generate();
      final publishing = await CryptographyBroadcastSigner.generate();
      const verifier = CryptographyBroadcastVerifier();
      final signed = await BroadcastDescriptor.sign(
        signer: publishing,
        authorId: authorIdFor(root.publicKey),
        seq: 3,
        publishedAt: DateTime.utc(2026, 7, 28),
        prev: contentHash(Uint8List.fromList([9])),
        layers: {
          LayerFlag.text: contentHash(Uint8List.fromList([8])),
        },
      );

      final bodyLength = signed.encoded.length - 64;
      for (var index = 0; index < bodyLength; index++) {
        for (var bit = 0; bit < 8; bit++) {
          final flipped = Uint8List.fromList(signed.encoded)
            ..[index] ^= 1 << bit;
          expect(
            await BroadcastDescriptor.verify(
              encoded: flipped,
              rootPublicKey: root.publicKey,
              publishingKey: publishing.publicKey,
              verifier: verifier,
            ),
            isNull,
            reason: 'bit $bit of byte $index must not verify',
          );
        }
      }
    });
  });
}
