/// Withdrawing a post.
///
/// The most consequential thing a trusted voice does in a crisis is
/// correct itself, and the format had no room for it: the only option was
/// another post that a reader might never connect to the first. A
/// retraction puts the link inside the signature, so anyone holding both
/// knows the original no longer stands — and cannot be shown it as though
/// it did.
library;

import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

Uint8List _text(String value) => Uint8List.fromList(value.codeUnits);

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishingKey;
  late PublishingKeyCertificate certificate;
  late BroadcastPublisher publisher;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishingKey = await CryptographyBroadcastSigner.generate();
    certificate = await PublishingKeyCertificate.issue(
      rootSigner: root,
      publishingKey: publishingKey.publicKey,
      notBefore: t0,
      notAfter: t0.add(const Duration(days: 7)),
    );
    publisher = BroadcastPublisher(
      rootPublicKey: root.publicKey,
      publishingSigner: publishingKey,
      certificate: certificate,
    );
  });

  group('the format', () {
    test(
      'a retraction names the post it withdraws, inside the signature',
      () async {
        final wrong = await withClock(
          Clock.fixed(t0),
          () => publisher.publish(text: _text('the bridge is open')),
        );
        final correction = await withClock(
          Clock.fixed(t0),
          () => publisher.retract(
            wrong.descriptor,
            reason: _text('correction: the bridge is closed'),
          ),
        );

        expect(correction.descriptor.isRetraction, isTrue);
        expect(
          bytesEqual(correction.descriptor.retracts!, wrong.descriptor.id),
          isTrue,
        );
        // And the link survives the wire, because it is a committed slot
        // rather than something carried beside the record.
        final parsed = BroadcastDescriptor.parse(correction.descriptor.encoded);
        expect(bytesEqual(parsed!.retracts!, wrong.descriptor.id), isTrue);
      },
    );

    test('an ordinary post retracts nothing', () async {
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: _text('an ordinary post')),
      );
      expect(post.descriptor.retracts, isNull);
      expect(post.descriptor.isRetraction, isFalse);
    });

    test(
      'the retraction slot is not a layer and is never fetched as one',
      () async {
        // It commits to a post, not to content. A reader that treated it as
        // a layer would go looking for an object that does not exist.
        final wrong = await withClock(
          Clock.fixed(t0),
          () => publisher.publish(text: _text('wrong')),
        );
        final correction = await withClock(
          Clock.fixed(t0),
          () => publisher.retract(wrong.descriptor, reason: _text('right')),
        );
        expect(correction.descriptor.layers.keys, [LayerFlag.text]);
        expect(correction.descriptor.layer(LayerFlag.retraction), isNull);
      },
    );

    test(
      'an older build refuses a retraction rather than stripping it',
      () async {
        // The one thing worse than not understanding a correction is
        // showing the post while silently dropping the fact that it was
        // withdrawn. The unknown-flag rule already guarantees this; the
        // test states it, because it is the reason the slot mechanism was
        // reused rather than a trailing field added.
        final correction = await BroadcastDescriptor.sign(
          signer: publishingKey,
          authorId: authorIdFor(root.publicKey),
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: {LayerFlag.text: contentHash(_text('x'))},
          retracts: contentHash(_text('y')),
        );
        // Simulate a build that does not know the bit by masking it out of
        // the "known" set: the length no longer matches what the flags say.
        final bytes = Uint8List.fromList(correction.encoded);
        final reasons = <DescriptorRejection>[];
        bytes[1] &= ~LayerFlag.retraction;
        expect(BroadcastDescriptor.parse(bytes, onReject: reasons.add), isNull);
        expect(reasons, [DescriptorRejection.wrongLength]);
      },
    );

    test('a signature covers the retraction link', () async {
      final correction = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorIdFor(root.publicKey),
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('x'))},
        retracts: contentHash(_text('y')),
      );
      // Re-point the withdrawal at some other post: every byte of the slot
      // must be inside the signature, or an attacker chooses what gets
      // withdrawn.
      final start = correction.encoded.length - 64 - hashBytes;
      for (var i = start; i < start + hashBytes; i++) {
        final tampered = Uint8List.fromList(correction.encoded)..[i] ^= 0xFF;
        expect(
          await BroadcastDescriptor.verify(
            encoded: tampered,
            rootPublicKey: root.publicKey,
            publishingKey: publishingKey.publicKey,
            verifier: const CryptographyBroadcastVerifier(),
          ),
          isNull,
          reason: 'byte $i of the retraction link must not verify',
        );
      }
    });

    test('a wrong-sized link is refused at signing', () {
      expect(
        () => BroadcastDescriptor.sign(
          signer: publishingKey,
          authorId: authorIdFor(root.publicKey),
          seq: 0,
          publishedAt: t0,
          prev: zeroHash,
          layers: {LayerFlag.text: contentHash(_text('x'))},
          retracts: Uint8List(31),
        ),
        throwsArgumentError,
      );
    });
  });

  group('what a reader knows', () {
    test(
      'a withdrawn post is marked, and the correction is findable',
      () async {
        final relay = InMemoryBroadcastRelay();
        late BroadcastPost wrong;
        await withClock(Clock.fixed(t0), () async {
          wrong = await publisher.publish(text: _text('the bridge is open'));
          await publisher.pushTo(relay, wrong);
          await publisher.pushTo(
            relay,
            await publisher.retract(
              wrong.descriptor,
              reason: _text('correction: the bridge is closed'),
            ),
          );
        });

        final reader = BroadcastReader(
          rootPublicKey: root.publicKey,
          relays: [relay],
        );
        await withClock(
          Clock.fixed(t0),
          () => reader.adoptCertificate(certificate.encoded),
        );
        await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () async {
            expect((await reader.fetchNext()).isDelivered, isTrue);
            expect(
              reader.chain.isRetracted(wrong.descriptor),
              isFalse,
              reason: 'nothing has withdrawn it yet',
            );
            expect((await reader.fetchNext()).isDelivered, isTrue);
          },
        );

        expect(reader.chain.isRetracted(wrong.descriptor), isTrue);
        final correction = reader.chain.retractionOf(wrong.descriptor.id);
        expect(correction, isNotNull);
        expect(correction!.seq, 1);
        expect(
          String.fromCharCodes(
            (await reader.fetchLayer(correction, LayerFlag.text))!,
          ),
          'correction: the bridge is closed',
        );
        expect(reader.chain.retractions, hasLength(1));
      },
    );

    test('a post nobody withdrew is not marked', () async {
      final chain = BroadcastChain(authorId: authorIdFor(root.publicKey));
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: _text('still standing')),
      );
      chain.offer(post.descriptor);
      expect(chain.isRetracted(post.descriptor), isFalse);
      expect(chain.retractionOf(post.descriptor.id), isNull);
      expect(chain.retractions, isEmpty);
    });

    test(
      'a withdrawal of a post this reader never held still counts',
      () async {
        // Knowing that something was withdrawn is exactly as useful as
        // having it — arguably more so, since the reader may be about to be
        // shown it by someone else.
        final chain = BroadcastChain(authorId: authorIdFor(root.publicKey));
        final unseen = contentHash(_text('a post from before this reader'));
        final correction = await BroadcastDescriptor.sign(
          signer: publishingKey,
          authorId: authorIdFor(root.publicKey),
          seq: 5,
          publishedAt: t0,
          prev: contentHash(_text('prev')),
          layers: {LayerFlag.text: contentHash(_text('correction'))},
          retracts: unseen,
        );
        chain.offer(correction);
        expect(chain.retractionOf(unseen), isNotNull);
      },
    );

    test('a post cannot withdraw itself', () async {
      // A self-reference is a fixed point with no meaning, and it is the
      // shape a crafted descriptor takes to make a reader hide the very
      // thing it just verified.
      final chain = BroadcastChain(authorId: authorIdFor(root.publicKey));
      var attempt = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorIdFor(root.publicKey),
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('x'))},
        retracts: zeroHash,
      );
      // Re-sign with the link pointing at the descriptor's own id.
      attempt = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorIdFor(root.publicKey),
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('x'))},
        retracts: attempt.id,
      );
      chain.offer(attempt);
      expect(chain.isRetracted(attempt), isFalse);
    });

    test('the newest withdrawal of a post is the one that stands', () async {
      final chain = BroadcastChain(authorId: authorIdFor(root.publicKey));
      final target = contentHash(_text('target'));
      var prev = zeroHash;
      for (var seq = 0; seq < 3; seq++) {
        final post = await BroadcastDescriptor.sign(
          signer: publishingKey,
          authorId: authorIdFor(root.publicKey),
          seq: seq,
          publishedAt: t0.add(Duration(minutes: seq)),
          prev: prev,
          layers: {LayerFlag.text: contentHash(_text('correction $seq'))},
          retracts: target,
        );
        chain.offer(post);
        prev = post.id;
      }
      expect(chain.retractionOf(target)!.seq, 2);
      expect(chain.retractions, hasLength(1));
    });
  });

  group('the publisher', () {
    test('refuses a withdrawal with nothing said', () async {
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: _text('something')),
      );
      expect(
        () => publisher.retract(post.descriptor, reason: Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('refuses to withdraw another author post', () async {
      final stranger = await CryptographyBroadcastSigner.generate();
      final foreign = await BroadcastDescriptor.sign(
        signer: publishingKey,
        authorId: authorIdFor(stranger.publicKey),
        seq: 0,
        publishedAt: t0,
        prev: zeroHash,
        layers: {LayerFlag.text: contentHash(_text('theirs'))},
      );
      expect(
        () => publisher.retract(foreign, reason: _text('not mine to withdraw')),
        throwsArgumentError,
      );
    });

    test('a withdrawal takes the next sequence number like any post', () async {
      await withClock(Clock.fixed(t0), () async {
        final first = await publisher.publish(text: _text('one'));
        expect(publisher.nextSeq, 1);
        final correction = await publisher.retract(
          first.descriptor,
          reason: _text('two, withdrawing one'),
        );
        expect(correction.seq, 1);
        expect(publisher.nextSeq, 2);
        expect(
          bytesEqual(correction.descriptor.prev, first.descriptor.id),
          isTrue,
        );
      });
    });
  });
}
