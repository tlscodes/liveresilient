/// Regressions for the defects an adversarial review of this package
/// found on 2026-07-28. Each test names the attack it closes.
library;

import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

Uint8List _text(String value) => Uint8List.fromList(value.codeUnits);

/// A relay that answers every descriptor address with one fixed post.
class _SubstitutingRelay implements BroadcastRelay {
  _SubstitutingRelay(this._answer);

  final Uint8List _answer;

  @override
  String get name => 'substituting';

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) async =>
      _answer;

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) async => null;

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async {}

  @override
  Future<void> putObject(Uint8List bytes) async {}
}

/// A relay that answers with far more bytes than any descriptor can be.
class _FloodingRelay implements BroadcastRelay {
  @override
  String get name => 'flooding';

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) async =>
      Uint8List(4 * 1024 * 1024);

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) async => null;

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async {}

  @override
  Future<void> putObject(Uint8List bytes) async {}
}

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

  Future<BroadcastReader> readerOver(
    List<BroadcastRelay> relays, {
    Duration? maxHeadAge,
    int? maxRetainedPosts,
  }) async {
    final reader = BroadcastReader(
      rootPublicKey: root.publicKey,
      relays: relays,
      maxHeadAge: maxHeadAge ?? const Duration(days: 30),
      maxRetainedPosts: maxRetainedPosts ?? 4096,
    );
    await withClock(
      Clock.fixed(t0),
      () => reader.adoptCertificate(certificate.encoded),
    );
    return reader;
  }

  group('a relay may not answer one address with another post', () {
    test(
      'a substituted descriptor is refused, however well it is signed',
      () async {
        // The attack: every signature check passes, because the post is
        // genuinely the author's — it is simply not the one requested.
        final relay = InMemoryBroadcastRelay();
        late BroadcastPost fifth;
        await withClock(Clock.fixed(t0), () async {
          for (var i = 0; i < 6; i++) {
            final post = await publisher.publish(text: _text('post $i'));
            if (i == 5) fifth = post;
            await publisher.pushTo(relay, post);
          }
        });

        final reader = await readerOver([
          _SubstitutingRelay(fifth.descriptor.encoded),
        ]);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => reader.fetchSeq(0),
        );
        expect(result.outcome, ReadOutcome.rejected);
        expect(result.rejection, ReadRejection.wrongSequence);
        expect(reader.chain.isEmpty, isTrue);
      },
    );

    test(
      'an honest relay alongside a substituting one still delivers',
      () async {
        final honest = InMemoryBroadcastRelay(name: 'honest');
        late BroadcastPost second;
        await withClock(Clock.fixed(t0), () async {
          for (var i = 0; i < 3; i++) {
            final post = await publisher.publish(text: _text('post $i'));
            if (i == 1) second = post;
            await publisher.pushTo(honest, post);
          }
        });
        final reader = await readerOver([
          _SubstitutingRelay(second.descriptor.encoded),
          honest,
        ]);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => reader.fetchSeq(0),
        );
        expect(result.isDelivered, isTrue);
        expect(result.descriptor!.seq, 0);
        expect(result.relayName, 'honest');
      },
    );

    test('a backfill walk cannot be made to loop forever', () async {
      // Before the sequence check, a relay could answer every
      // fetchPrevious with a post the chain already held, so the window
      // never moved and the loop never ended.
      final relay = InMemoryBroadcastRelay();
      late BroadcastPost third;
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 4; i++) {
          final post = await publisher.publish(text: _text('post $i'));
          if (i == 3) third = post;
          await publisher.pushTo(relay, post);
        }
      });

      final reader = await readerOver([relay]);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await reader.fetchSeq(3)).isDelivered, isTrue);
        },
      );

      // Now every answer is the post already held at seq 3.
      final stuck = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [_SubstitutingRelay(third.descriptor.encoded)],
      );
      await withClock(
        Clock.fixed(t0),
        () => stuck.adoptCertificate(certificate.encoded),
      );
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await stuck.fetchSeq(3)).isDelivered, isTrue);
          final again = await stuck.fetchPrevious();
          expect(again.isDelivered, isFalse);
          expect(again.rejection, ReadRejection.wrongSequence);
        },
      );
    });
  });

  group('an expired delegation may verify history but not extend it', () {
    test('a stolen key cannot keep appending by backdating', () async {
      // The whole point of a short-lived publishing key. Certificates are
      // checked against the time a post declares so that rotation does not
      // erase history — which, without a staleness bound on a new head,
      // would let a dead key speak forever.
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(text: _text('the last real post')),
        );
      });

      final reader = await readerOver([relay]);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await reader.fetchNext()).isDelivered, isTrue);
        },
      );

      // Months later, with the certificate long expired, the thief signs
      // a post dated inside the dead window.
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(
            text: _text('the forged continuation'),
            at: t0.add(const Duration(hours: 1)),
          ),
        );
      });
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(days: 200))),
        () => reader.fetchNext(),
      );
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.staleHeadExtension);
    });

    test('history stays readable however old it is', () async {
      // The property the staleness bound must not break: an old post is
      // fine, as long as it is not being offered as the newest one.
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 3; i++) {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text('old post $i')),
          );
        }
      });
      final reader = await readerOver([relay]);
      await withClock(Clock.fixed(t0.add(const Duration(days: 200))), () async {
        // Anchoring anywhere is allowed...
        expect((await reader.fetchSeq(2)).isDelivered, isTrue);
        // ...and so is walking backwards through it.
        expect((await reader.fetchPrevious()).isDelivered, isTrue);
        expect((await reader.fetchPrevious()).isDelivered, isTrue);
      });
      expect(reader.chain.length, 3);
    });

    test('a fresh head inside the window is still accepted', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(text: _text('first')),
        );
      });
      final reader = await readerOver([relay]);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await reader.fetchNext()).isDelivered, isTrue);
        },
      );
      await withClock(Clock.fixed(t0.add(const Duration(days: 2))), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(
            text: _text('second'),
            at: t0.add(const Duration(days: 2)),
          ),
        );
        expect((await reader.fetchNext()).isDelivered, isTrue);
      });
      expect(reader.chain.highestSeq, 1);
    });
  });

  group('bounded work on hostile input', () {
    test('an oversize answer is refused before it is parsed', () async {
      final reader = await readerOver([_FloodingRelay()]);
      final result = await withClock(Clock.fixed(t0), () => reader.fetchSeq(0));
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.oversizeDescriptor);
    });

    test('the retained window has a ceiling', () async {
      // Anyone who can sign as the author could otherwise make a polling
      // reader hold every post it is fed.
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 12; i++) {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text('post $i')),
          );
        }
      });
      final reader = await readerOver([relay], maxRetainedPosts: 4);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          for (var i = 0; i < 12; i++) {
            expect((await reader.fetchNext()).isDelivered, isTrue);
          }
        },
      );
      expect(reader.chain.length, 4);
      expect(reader.chain.highestSeq, 11);
      expect(reader.chain.lowestSeq, 8);
      expect(reader.chain.at(0), isNull, reason: 'the oldest were dropped');
    });

    test('a backfill is not trimmed away as it arrives', () async {
      // Dropping what a backward walk just fetched would make the walk
      // never finish.
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 6; i++) {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text('post $i')),
          );
        }
      });
      final reader = await readerOver([relay], maxRetainedPosts: 2);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await reader.fetchSeq(5)).isDelivered, isTrue);
          for (var i = 0; i < 5; i++) {
            expect(
              (await reader.fetchPrevious()).isDelivered,
              isTrue,
              reason: 'backfill step $i',
            );
          }
        },
      );
      expect(reader.chain.lowestSeq, 0);
      expect(reader.chain.length, 6);
    });

    test('a chain window smaller than two posts is refused', () {
      expect(
        () => BroadcastChain(authorId: Uint8List(8), maxRetained: 1),
        throwsArgumentError,
      );
    });
  });

  test('the top of the sequence space is exhaustion, not a crash', () async {
    final reader = await readerOver([InMemoryBroadcastRelay()]);
    final top = await BroadcastDescriptor.sign(
      signer: publishingKey,
      authorId: authorIdFor(root.publicKey),
      seq: maxSeq,
      publishedAt: t0,
      prev: contentHash(Uint8List.fromList([1])),
      layers: {LayerFlag.text: contentHash(_text('top'))},
    );
    reader.chain.offer(top);
    expect(reader.chain.highestSeq, maxSeq);
    final result = await withClock(Clock.fixed(t0), () => reader.fetchNext());
    expect(result.outcome, ReadOutcome.notAvailable);
  });
}
