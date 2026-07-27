import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

void main() {
  const verifier = CryptographyBroadcastVerifier();
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishing;
  late PublishingKeyCertificate cert;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishing = await CryptographyBroadcastSigner.generate();
    cert = await PublishingKeyCertificate.issue(
      rootSigner: root,
      publishingKey: publishing.publicKey,
      notBefore: t0,
      notAfter: t0.add(const Duration(days: 7)),
    );
  });

  test('encodes to the documented fixed size', () {
    expect(cert.encoded.length, certificateBytes);
    expect(certificateBytes, 115);
  });

  test('verifies against the issuing root key', () async {
    final parsed = await PublishingKeyCertificate.verify(
      encoded: cert.encoded,
      rootPublicKey: root.publicKey,
      verifier: verifier,
      now: t0.add(const Duration(days: 1)),
    );
    expect(parsed, isNotNull);
    expect(parsed!.publishingKey, publishing.publicKey);
    expect(parsed.authorId, authorIdFor(root.publicKey));
    expect(parsed.notBefore, t0);
  });

  test('the author id in the certificate names the root key', () {
    expect(cert.authorId, authorIdFor(root.publicKey));
  });

  test('is refused when presented with a different root key', () async {
    final other = await CryptographyBroadcastSigner.generate();
    final reasons = <CertificateRejection>[];
    final parsed = await PublishingKeyCertificate.verify(
      encoded: cert.encoded,
      rootPublicKey: other.publicKey,
      verifier: verifier,
      now: t0,
      onReject: reasons.add,
    );
    expect(parsed, isNull);
    expect(reasons, [CertificateRejection.authorMismatch]);
  });

  test('is refused before its window opens and after it closes', () async {
    final early = <CertificateRejection>[];
    expect(
      await PublishingKeyCertificate.verify(
        encoded: cert.encoded,
        rootPublicKey: root.publicKey,
        verifier: verifier,
        now: t0.subtract(const Duration(seconds: 1)),
        onReject: early.add,
      ),
      isNull,
    );
    expect(early, [CertificateRejection.notYetValid]);

    final late = <CertificateRejection>[];
    expect(
      await PublishingKeyCertificate.verify(
        encoded: cert.encoded,
        rootPublicKey: root.publicKey,
        verifier: verifier,
        now: t0.add(const Duration(days: 7, seconds: 1)),
        onReject: late.add,
      ),
      isNull,
    );
    expect(late, [CertificateRejection.expired]);
  });

  test('the window is inclusive at both ends', () async {
    for (final at in [t0, t0.add(const Duration(days: 7))]) {
      expect(
        await PublishingKeyCertificate.verify(
          encoded: cert.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: at,
        ),
        isNotNull,
        reason: 'boundary instant $at must verify',
      );
    }
  });

  test(
    'a reader refuses a window longer than it is willing to grant',
    () async {
      final long = await PublishingKeyCertificate.issue(
        rootSigner: root,
        publishingKey: publishing.publicKey,
        notBefore: t0,
        notAfter: t0.add(const Duration(days: 400)),
      );
      final reasons = <CertificateRejection>[];
      expect(
        await PublishingKeyCertificate.verify(
          encoded: long.encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0.add(const Duration(days: 1)),
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [CertificateRejection.windowTooLong]);
    },
  );

  test(
    'a flipped bit anywhere in the body invalidates the signature',
    () async {
      // Walk the whole body, not a sampled byte: every field is inside the
      // signature or the delegation could be edited in flight.
      for (var i = 0; i < certificateBytes - 64; i++) {
        final tampered = Uint8List.fromList(cert.encoded);
        tampered[i] ^= 0x01;
        final reasons = <CertificateRejection>[];
        final parsed = await PublishingKeyCertificate.verify(
          encoded: tampered,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0.add(const Duration(days: 1)),
          onReject: reasons.add,
        );
        expect(parsed, isNull, reason: 'byte $i must not verify');
        expect(reasons, isNotEmpty, reason: 'byte $i must report a reason');
      }
    },
  );

  test('a tampered signature is refused', () async {
    final tampered = Uint8List.fromList(cert.encoded);
    tampered[certificateBytes - 1] ^= 0xFF;
    final reasons = <CertificateRejection>[];
    expect(
      await PublishingKeyCertificate.verify(
        encoded: tampered,
        rootPublicKey: root.publicKey,
        verifier: verifier,
        now: t0.add(const Duration(days: 1)),
        onReject: reasons.add,
      ),
      isNull,
    );
    expect(reasons, [CertificateRejection.badSignature]);
  });

  test('wrong length is refused as malformed', () async {
    for (final length in [0, certificateBytes - 1, certificateBytes + 1]) {
      final reasons = <CertificateRejection>[];
      expect(
        await PublishingKeyCertificate.verify(
          encoded: Uint8List(length),
          rootPublicKey: root.publicKey,
          verifier: verifier,
          now: t0,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [CertificateRejection.malformed]);
    }
  });

  test('an unknown version is refused rather than parsed hopefully', () async {
    final future = Uint8List.fromList(cert.encoded);
    future[0] = 99;
    final reasons = <CertificateRejection>[];
    expect(
      await PublishingKeyCertificate.verify(
        encoded: future,
        rootPublicKey: root.publicKey,
        verifier: verifier,
        now: t0,
        onReject: reasons.add,
      ),
      isNull,
    );
    expect(reasons, [CertificateRejection.unsupportedVersion]);
  });

  test('issuing refuses an inverted window and a wrong-sized key', () {
    expect(
      () => PublishingKeyCertificate.issue(
        rootSigner: root,
        publishingKey: publishing.publicKey,
        notBefore: t0,
        notAfter: t0,
      ),
      throwsArgumentError,
    );
    expect(
      () => PublishingKeyCertificate.issue(
        rootSigner: root,
        publishingKey: Uint8List(31),
        notBefore: t0,
        notAfter: t0.add(const Duration(days: 1)),
      ),
      throwsArgumentError,
    );
  });

  test('isValidAt matches the verified window', () {
    expect(cert.isValidAt(t0), isTrue);
    expect(cert.isValidAt(t0.subtract(const Duration(seconds: 1))), isFalse);
    expect(cert.isValidAt(t0.add(const Duration(days: 7))), isTrue);
    expect(
      cert.isValidAt(t0.add(const Duration(days: 7, seconds: 1))),
      isFalse,
    );
  });

  group('parseWindowStart', () {
    test('reads the declared start without verifying', () {
      expect(PublishingKeyCertificate.parseWindowStart(cert.encoded), t0);
    });

    test('returns null on a wrong length or unknown version', () {
      expect(PublishingKeyCertificate.parseWindowStart(Uint8List(10)), isNull);
      final bad = Uint8List.fromList(cert.encoded);
      bad[0] = 2;
      expect(PublishingKeyCertificate.parseWindowStart(bad), isNull);
    });
  });

  test('a signer rebuilt from a seed produces the same key', () async {
    final seed = Uint8List.fromList(List.generate(32, (i) => i));
    final a = await CryptographyBroadcastSigner.fromSeed(seed);
    final b = await CryptographyBroadcastSigner.fromSeed(seed);
    expect(a.publicKey, b.publicKey);
    expect(
      () => CryptographyBroadcastSigner.fromSeed(Uint8List(31)),
      throwsArgumentError,
    );
  });

  test('the verifier rejects wrong-sized keys and signatures', () async {
    final message = Uint8List.fromList([1, 2, 3]);
    final signature = await root.sign(message);
    expect(
      await verifier.verify(
        message: message,
        signature: signature,
        publicKey: Uint8List(31),
      ),
      isFalse,
    );
    expect(
      await verifier.verify(
        message: message,
        signature: Uint8List(63),
        publicKey: root.publicKey,
      ),
      isFalse,
    );
    expect(
      await verifier.verify(
        message: message,
        signature: signature,
        publicKey: root.publicKey,
      ),
      isTrue,
    );
  });
}
