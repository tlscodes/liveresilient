/// A compromised key is only useful knowledge if it travels.
///
/// The chain detects a fork locally. These tests are about the other half:
/// turning that detection into a file anyone can check and anyone can
/// publish — including on the relays the attacker is using, and by someone
/// other than the author, who is precisely the party that may no longer be
/// able to speak.
library;

import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
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

  Future<BroadcastDescriptor> post({int seq = 0, required String body}) =>
      BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorId,
        seq: seq,
        publishedAt: t0,
        prev: seq == 0 ? zeroHash : contentHash(_text('prev')),
        layers: {LayerFlag.text: contentHash(_text(body))},
      );

  group('the proof', () {
    test('a real fork builds a report that verifies', () async {
      final a = await post(body: 'the real post');
      final b = await post(body: 'the forged post');
      final encoded = ForkReport.build(certificate: certificate, a: a, b: b);

      final report = await ForkReport.verify(
        encoded: encoded,
        rootPublicKey: root.publicKey,
        verifier: verifier,
      );
      expect(report, isNotNull);
      expect(report!.seq, 0);
      expect(bytesEqual(report.authorId, authorId), isTrue);
      expect(
        {hexEncode(report.first.id), hexEncode(report.second.id)},
        {hexEncode(a.id), hexEncode(b.id)},
      );
    });

    test('the same fork always produces the same bytes', () async {
      // Two readers who saw the fork in opposite order must publish one
      // file, not two, or a relay stores both and neither is canonical.
      final a = await post(body: 'one');
      final b = await post(body: 'two');
      expect(
        ForkReport.build(certificate: certificate, a: a, b: b),
        ForkReport.build(certificate: certificate, a: b, b: a),
      );
    });

    test('it is built straight from what a chain detected', () async {
      final chain = BroadcastChain(authorId: authorId);
      final a = await post(body: 'held');
      final b = await post(body: 'offered');
      chain.offer(a);
      final result = chain.offer(b);
      expect(result.outcome, ChainOutcome.fork);

      final encoded = ForkReport.buildFrom(
        evidence: result.fork!,
        certificate: certificate,
      );
      expect(
        await ForkReport.verify(
          encoded: encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
        ),
        isNotNull,
      );
    });

    test('it stays valid after the certificate expires', () async {
      // Evidence is about the past. A proof that stopped working when the
      // window closed would expire exactly when it is most needed — the
      // compromise is usually noticed later, not sooner.
      final a = await post(body: 'one');
      final b = await post(body: 'two');
      final encoded = ForkReport.build(certificate: certificate, a: a, b: b);
      final report = await withClock(
        Clock.fixed(t0.add(const Duration(days: 900))),
        () => ForkReport.verify(
          encoded: encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
        ),
      );
      expect(report, isNotNull);
    });

    test('it is small enough to move like any other object', () async {
      final a = await post(body: 'one');
      final b = await post(body: 'two');
      final encoded = ForkReport.build(certificate: certificate, a: a, b: b);
      // Certificate plus two descriptors plus framing.
      expect(encoded.length, lessThan(600));
    });
  });

  group('what it refuses', () {
    test('two posts at different sequence numbers are not a fork', () async {
      final a = await post(seq: 0, body: 'one');
      final b = await post(seq: 1, body: 'two');
      expect(
        () => ForkReport.build(certificate: certificate, a: a, b: b),
        throwsArgumentError,
      );
    });

    test('the same post twice is not a fork', () async {
      final a = await post(body: 'one');
      expect(
        () => ForkReport.build(certificate: certificate, a: a, b: a),
        throwsArgumentError,
      );
    });

    test('two posts by different authors are not a fork', () async {
      final stranger = await CryptographyBroadcastSigner.generate();
      final foreign = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorIdFor(stranger.publicKey),
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('theirs'))},
      );
      final mine = await post(body: 'mine');
      expect(
        () => ForkReport.build(certificate: certificate, a: mine, b: foreign),
        throwsArgumentError,
      );
    });

    test('a report against the wrong root key does not verify', () async {
      final other = await CryptographyBroadcastSigner.generate();
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'one'),
        b: await post(body: 'two'),
      );
      final reasons = <ForkReportRejection>[];
      expect(
        await ForkReport.verify(
          encoded: encoded,
          rootPublicKey: other.publicKey,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [ForkReportRejection.badCertificate]);
    });

    test('a descriptor signed by an undelegated key does not verify', () async {
      // The accusation has to be checkable, or it is just an accusation.
      final impostor = await CryptographyBroadcastSigner.generate();
      final forged = await BroadcastDescriptor.sign(
        signer: impostor,
        authorId: authorId,
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('forged'))},
      );
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'real'),
        b: forged,
      );
      final reasons = <ForkReportRejection>[];
      expect(
        await ForkReport.verify(
          encoded: encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [ForkReportRejection.unverifiedDescriptor]);
    });

    test('every single-bit flip fails to verify', () async {
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'one'),
        b: await post(body: 'two'),
      );
      for (var index = 0; index < encoded.length; index += 7) {
        final flipped = Uint8List.fromList(encoded)..[index] ^= 0x01;
        expect(
          await ForkReport.verify(
            encoded: flipped,
            rootPublicKey: root.publicKey,
            verifier: verifier,
          ),
          isNull,
          reason: 'byte $index must not verify',
        );
      }
    });

    test('malformed input is refused without throwing', () async {
      for (final bytes in [
        Uint8List(0),
        Uint8List(10),
        Uint8List(400),
        Uint8List.fromList(List.filled(300, 0xFF)),
      ]) {
        expect(
          await ForkReport.verify(
            encoded: bytes,
            rootPublicKey: root.publicKey,
            verifier: verifier,
          ),
          isNull,
        );
      }
    });

    test('trailing bytes are refused', () async {
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'one'),
        b: await post(body: 'two'),
      );
      final reasons = <ForkReportRejection>[];
      expect(
        await ForkReport.verify(
          encoded: Uint8List.fromList([...encoded, 0]),
          rootPublicKey: root.publicKey,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [ForkReportRejection.malformed]);
    });

    test('an unknown version is refused', () async {
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'one'),
        b: await post(body: 'two'),
      )..[0] = 9;
      final reasons = <ForkReportRejection>[];
      expect(
        await ForkReport.verify(
          encoded: encoded,
          rootPublicKey: root.publicKey,
          verifier: verifier,
          onReject: reasons.add,
        ),
        isNull,
      );
      expect(reasons, [ForkReportRejection.unsupportedVersion]);
    });
  });

  group('where it lives', () {
    test('one well-known address per author', () {
      final address = ForkReportAddress(authorId);
      expect(address.path, '/f/${hexEncode(authorId)}');
      expect(ForkReportAddress.tryParse(address.path), address);
    });

    test('a malformed path is refused', () {
      for (final path in [
        '',
        '/f',
        '/f/short',
        '/f/${hexEncode(authorId)}/extra',
        '/a/${hexEncode(authorId)}',
        '/f/zzzzzzzzzzzzzzzz',
      ]) {
        expect(
          ForkReportAddress.tryParse(path),
          isNull,
          reason: 'must refuse $path',
        );
      }
    });

    test('it is content addressed like any other object', () async {
      final encoded = ForkReport.build(
        certificate: certificate,
        a: await post(body: 'one'),
        b: await post(body: 'two'),
      );
      final report = await ForkReport.verify(
        encoded: encoded,
        rootPublicKey: root.publicKey,
        verifier: verifier,
      );
      expect(report!.id, contentHash(encoded));
      // Which means a relay can carry it with the storage it already has,
      // and anyone may put it there — a false one fails on arrival.
      final relay = InMemoryBroadcastRelay();
      await relay.putObject(encoded);
      expect(
        await relay.fetchObject(ObjectAddress(contentHash(encoded))),
        encoded,
      );
    });
  });

  test('anyone can publish it, not only the author', () async {
    // The point of the whole file. The author is exactly the party who may
    // have lost the ability to speak, so the proof must not need them.
    final chain = BroadcastChain(authorId: authorId);
    chain.offer(await post(body: 'the real post'));
    final result = chain.offer(await post(body: 'the forged post'));

    // A bystander holding only the author's public key and the
    // certificate — both public — reconstructs and checks the proof.
    final encoded = ForkReport.buildFrom(
      evidence: result.fork!,
      certificate: certificate,
    );
    final bystanderView = await ForkReport.verify(
      encoded: encoded,
      rootPublicKey: root.publicKey,
      verifier: verifier,
    );
    expect(bystanderView, isNotNull);
    expect(bystanderView!.seq, 0);
  });
}
