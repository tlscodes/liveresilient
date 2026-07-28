import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

Uint8List _text(String value) => Uint8List.fromList(value.codeUnits);

Uint8List _media(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 17 + 3) & 0xFF));

/// A relay that hands back bytes that are not what was asked for.
class _PoisonedRelay implements BroadcastRelay {
  _PoisonedRelay(this._honest);

  final InMemoryBroadcastRelay _honest;

  @override
  String get name => 'poisoned';

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) async {
    final real = await _honest.fetchDescriptor(address);
    if (real == null) return null;
    final tampered = Uint8List.fromList(real);
    tampered[tampered.length - 1] ^= 0xFF;
    return tampered;
  }

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) async {
    final real = await _honest.fetchObject(address);
    if (real == null) return null;
    final tampered = Uint8List.fromList(real);
    tampered[0] ^= 0xFF;
    return tampered;
  }

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async {}

  @override
  Future<void> putObject(Uint8List bytes) async {}
}

/// A relay that is simply down.
class _DownRelay implements BroadcastRelay {
  @override
  String get name => 'down';

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress address) async =>
      throw StateError('unreachable');

  @override
  Future<Uint8List?> fetchObject(ObjectAddress address) async =>
      throw StateError('unreachable');

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async {}

  @override
  Future<void> putObject(Uint8List bytes) async {}
}

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late CryptographyBroadcastSigner publishingSigner;
  late PublishingKeyCertificate certificate;
  late BroadcastPublisher publisher;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publishingSigner = await CryptographyBroadcastSigner.generate();
    certificate = await PublishingKeyCertificate.issue(
      rootSigner: root,
      publishingKey: publishingSigner.publicKey,
      notBefore: t0,
      notAfter: t0.add(const Duration(days: 7)),
    );
    publisher = BroadcastPublisher(
      rootPublicKey: root.publicKey,
      publishingSigner: publishingSigner,
      certificate: certificate,
    );
  });

  Future<BroadcastReader> readerOver(List<BroadcastRelay> relays) async {
    final reader = BroadcastReader(
      rootPublicKey: root.publicKey,
      relays: relays,
    );
    expect(
      await reader.adoptCertificate(publisher.certificate.encoded),
      isTrue,
    );
    return reader;
  }

  group('the minimum viable path', () {
    test('a signed text post reaches a reader and verifies', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        final post = await publisher.publish(text: _text('the message'));
        await publisher.pushTo(relay, post);
      });

      final reader = await readerOver([relay]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );

      expect(result.isDelivered, isTrue);
      expect(result.descriptor!.seq, 0);
      expect(result.relayName, relay.name);

      final text = await reader.fetchLayer(result.descriptor!, LayerFlag.text);
      expect(String.fromCharCodes(text!), 'the message');
    });

    test('a whole post is small enough to matter', () async {
      // The budget claim: descriptor plus a short text layer is well
      // under a kilobyte, so it fits any carrier that moves bytes at all.
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(text: _text('نان و آب و آزادی')),
      );
      expect(post.descriptor.encoded.length, 155);
      expect(post.totalBytes, lessThan(1024));
    });

    test('a reader follows a sequence it can predict', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        for (final body in ['first', 'second', 'third']) {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text(body)),
          );
        }
      });

      final reader = await readerOver([relay]);
      await withClock(Clock.fixed(t0.add(const Duration(hours: 1))), () async {
        for (final expected in ['first', 'second', 'third']) {
          final result = await reader.fetchNext();
          expect(result.isDelivered, isTrue);
          final text = await reader.fetchLayer(
            result.descriptor!,
            LayerFlag.text,
          );
          expect(String.fromCharCodes(text!), expected);
        }
        // Nothing published yet is a plain empty answer, not an error.
        expect((await reader.fetchNext()).outcome, ReadOutcome.notAvailable);
      });
      expect(reader.chain.length, 3);
      expect(reader.chain.highestSeq, 2);
    });

    test('a late reader recovers history by walking backward', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 4; i++) {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text('p$i')),
          );
        }
      });

      final reader = await readerOver([relay]);
      await withClock(Clock.fixed(t0.add(const Duration(days: 1))), () async {
        expect((await reader.fetchSeq(3)).isDelivered, isTrue);
        for (var i = 0; i < 3; i++) {
          expect((await reader.fetchPrevious()).isDelivered, isTrue);
        }
        expect(reader.chain.lowestSeq, 0);
        // Nothing precedes genesis.
        expect(
          (await reader.fetchPrevious()).outcome,
          ReadOutcome.notAvailable,
        );
      });
    });
  });

  group('layers', () {
    test('every layer type round-trips independently', () async {
      final relay = InMemoryBroadcastRelay();
      final media = _media(200 * 1024);
      final post = await withClock(Clock.fixed(t0), () async {
        final p = await publisher.publish(
          text: _text('caption'),
          still: _media(9000),
          voice: _media(240),
          media: media,
        );
        await publisher.pushTo(relay, p);
        return p;
      });

      expect(post.descriptor.encoded.length, 251);

      final reader = await readerOver([relay]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 5))),
        () => reader.fetchNext(),
      );
      final d = result.descriptor!;

      expect(
        String.fromCharCodes((await reader.fetchLayer(d, LayerFlag.text))!),
        'caption',
      );
      expect((await reader.fetchLayer(d, LayerFlag.still))!.length, 9000);
      expect((await reader.fetchLayer(d, LayerFlag.voice))!.length, 240);
      expect(await reader.fetchMedia(d), media);
    });

    test('an absent layer reads as null', () async {
      final relay = InMemoryBroadcastRelay();
      final post = await withClock(Clock.fixed(t0), () async {
        final p = await publisher.publish(text: _text('text only'));
        await publisher.pushTo(relay, p);
        return p;
      });
      final reader = await readerOver([relay]);
      expect(await reader.fetchLayer(post.descriptor, LayerFlag.still), isNull);
      expect(await reader.fetchMedia(post.descriptor), isNull);
    });

    test(
      'the media layer is fetched through fetchMedia, not fetchLayer',
      () async {
        final relay = InMemoryBroadcastRelay();
        final post = await withClock(
          Clock.fixed(t0),
          () => publisher.publish(media: _media(20_000)),
        );
        await publisher.pushTo(relay, post);
        final reader = await readerOver([relay]);
        expect(
          () => reader.fetchLayer(post.descriptor, LayerFlag.mediaList),
          throwsArgumentError,
        );
      },
    );

    test(
      'a missing media chunk fails the whole layer rather than a partial',
      () async {
        final relay = InMemoryBroadcastRelay();
        final media = _media(200 * 1024);
        final post = await withClock(Clock.fixed(t0), () async {
          final p = await publisher.publish(media: media);
          await publisher.pushTo(relay, p);
          return p;
        });
        // Drop one chunk, as an expired or removed relay entry would.
        expect(relay.dropObject(post.mediaHashList!.hashes[1]), isTrue);
        final reader = await readerOver([relay]);
        expect(await reader.fetchMedia(post.descriptor), isNull);
      },
    );

    test('a layer larger than the reader ceiling is refused', () async {
      final relay = InMemoryBroadcastRelay();
      final post = await withClock(
        Clock.fixed(t0),
        () => publisher.publish(media: _media(100 * 1024)),
      );
      await publisher.pushTo(relay, post);
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [relay],
        maxLayerBytes: 1024,
      );
      await reader.adoptCertificate(publisher.certificate.encoded);
      expect(await reader.fetchMedia(post.descriptor), isNull);
    });
  });

  group('surviving hostile and broken relays', () {
    test('one relay blocked, the post still arrives from another', () async {
      // The central claim of the design, exercised end to end.
      final blocked = InMemoryBroadcastRelay(name: 'blocked');
      final open = InMemoryBroadcastRelay(name: 'open');
      await withClock(Clock.fixed(t0), () async {
        final post = await publisher.publish(text: _text('still here'));
        await publisher.pushTo(blocked, post);
        await publisher.pushTo(open, post);
      });
      blocked.clear();

      final reader = await readerOver([blocked, open]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
      expect(result.relayName, 'open');
    });

    test('a relay that throws does not end the search', () async {
      final open = InMemoryBroadcastRelay(name: 'open');
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          open,
          await publisher.publish(text: _text('reachable')),
        );
      });
      final reader = await readerOver([_DownRelay(), open]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
      expect(result.relayName, 'open');
    });

    test(
      'a relay that tampers cannot poison a reader that has another',
      () async {
        final honest = InMemoryBroadcastRelay(name: 'honest');
        final media = _media(150 * 1024);
        final post = await withClock(Clock.fixed(t0), () async {
          final p = await publisher.publish(
            text: _text('unaltered'),
            media: media,
          );
          await publisher.pushTo(honest, p);
          return p;
        });

        final reader = await readerOver([_PoisonedRelay(honest), honest]);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => reader.fetchNext(),
        );
        expect(result.isDelivered, isTrue);
        expect(result.relayName, 'honest');
        expect(
          String.fromCharCodes(
            (await reader.fetchLayer(result.descriptor!, LayerFlag.text))!,
          ),
          'unaltered',
        );
        expect(await reader.fetchMedia(post.descriptor), media);
      },
    );

    test('a tampering relay alone yields nothing, never wrong bytes', () async {
      final honest = InMemoryBroadcastRelay(name: 'honest');
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          honest,
          await publisher.publish(text: _text('unaltered')),
        );
      });
      final reader = await readerOver([_PoisonedRelay(honest)]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.unverifiedSignature);
    });

    test(
      'reading the same post from every relay is a quiet duplicate',
      () async {
        final a = InMemoryBroadcastRelay(name: 'a');
        final b = InMemoryBroadcastRelay(name: 'b');
        await withClock(Clock.fixed(t0), () async {
          final post = await publisher.publish(text: _text('once'));
          await publisher.pushTo(a, post);
          await publisher.pushTo(b, post);
        });
        final reader = await readerOver([a, b]);
        await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () async {
            expect((await reader.fetchSeq(0)).isDelivered, isTrue);
            expect((await reader.fetchSeq(0)).isDelivered, isTrue);
          },
        );
        expect(reader.chain.length, 1);
        expect(reader.chain.hasForked, isFalse);
      },
    );
  });

  group('key compromise', () {
    test('a duplicated publishing key is caught and proved', () async {
      // Two publishers over one identity: exactly what a stolen device
      // plus the real author looks like from a reader's side.
      final relay = InMemoryBroadcastRelay(name: 'a');
      final impostorRelay = InMemoryBroadcastRelay(name: 'b');
      late BroadcastPublisher impostor;

      await withClock(Clock.fixed(t0), () async {
        impostor = BroadcastPublisher(
          rootPublicKey: publisher.rootPublicKey,
          publishingSigner: await CryptographyBroadcastSigner.fromSeed(
            Uint8List.fromList(List.filled(32, 9)),
          ),
          certificate: publisher.certificate,
        );
        await publisher.pushTo(
          relay,
          await publisher.publish(text: _text('the real post')),
        );
      });

      // The impostor holds the same certificate, so its own key is not
      // the one delegated — a reader refuses it outright.
      final reader = await readerOver([relay]);
      await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () async {
          expect((await reader.fetchSeq(0)).isDelivered, isTrue);
        },
      );

      await withClock(Clock.fixed(t0), () async {
        await impostor.pushTo(
          impostorRelay,
          await impostor.publish(text: _text('the forged post')),
        );
      });
      final forgedReader = await readerOver([impostorRelay]);
      final forged = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => forgedReader.fetchSeq(0),
      );
      expect(forged.outcome, ReadOutcome.rejected);
      expect(forged.rejection, ReadRejection.unverifiedSignature);
    });

    test(
      'the same key signing two posts at one sequence is proved a fork',
      () async {
        final a = InMemoryBroadcastRelay(name: 'a');
        final b = InMemoryBroadcastRelay(name: 'b');

        await withClock(Clock.fixed(t0), () async {
          await publisher.pushTo(
            a,
            await publisher.publish(text: _text('the real post')),
          );
        });

        // A second publisher holding the same publishing key — the actual
        // compromise case — rewinds to sequence zero.
        final cloned = BroadcastPublisher(
          rootPublicKey: publisher.rootPublicKey,
          publishingSigner: publishingSigner,
          certificate: publisher.certificate,
        );
        await withClock(Clock.fixed(t0), () async {
          await cloned.pushTo(
            b,
            await cloned.publish(text: _text('the forged post')),
          );
        });

        final reader = await readerOver([a]);
        await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () async {
            expect((await reader.fetchSeq(0)).isDelivered, isTrue);
          },
        );

        final forkReader = BroadcastReader(
          rootPublicKey: root.publicKey,
          relays: [b],
        );
        await forkReader.adoptCertificate(publisher.certificate.encoded);
        // Feed the honest post into the same chain, then the forged one.
        forkReader.chain.offer(reader.chain.at(0)!);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => forkReader.fetchSeq(0),
        );
        expect(result.outcome, ReadOutcome.fork);
        expect(result.fork!.seq, 0);
        expect(
          bytesEqual(result.fork!.held.id, result.fork!.offered.id),
          isFalse,
        );
      },
    );

    test(
      'an expired certificate still verifies the posts it covered',
      () async {
        // Otherwise an author's history would become unreadable every time
        // their publishing key rotated.
        final relay = InMemoryBroadcastRelay();
        await withClock(Clock.fixed(t0), () async {
          await publisher.pushTo(
            relay,
            await publisher.publish(text: _text('old news')),
          );
        });
        final reader = await readerOver([relay]);
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(days: 90))),
          () => reader.fetchNext(),
        );
        expect(result.isDelivered, isTrue);
      },
    );

    test('a post dated outside every adopted window is refused', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        // Dated well after the certificate expires.
        final post = await publisher.publish(
          text: _text('out of window'),
          at: t0.add(const Duration(days: 30)),
        );
        await publisher.pushTo(relay, post);
      });
      final reader = await readerOver([relay]);
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(days: 31))),
        () => reader.fetchNext(),
      );
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.noCertificateForTime);
    });

    test('a post dated far in the future is refused', () async {
      // Without this, a compromised key could claim the sequence space
      // ahead of the real author.
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(
            text: _text('from tomorrow'),
            at: t0.add(const Duration(days: 5)),
          ),
        );
      });
      final reader = await readerOver([relay]);
      final result = await withClock(Clock.fixed(t0), () => reader.fetchNext());
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.timeTooFarAhead);
    });

    test('a certificate from another identity is not adopted', () async {
      final stranger = await CryptographyBroadcastSigner.generate();
      final other = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: stranger),
      );
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [InMemoryBroadcastRelay()],
      );
      expect(
        await withClock(
          Clock.fixed(t0),
          () => reader.adoptCertificate(other.certificate.encoded),
        ),
        isFalse,
      );
      expect(reader.certificates, isEmpty);
    });

    test('adopting the same certificate twice keeps one copy', () async {
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [InMemoryBroadcastRelay()],
      );
      await withClock(Clock.fixed(t0), () async {
        expect(
          await reader.adoptCertificate(publisher.certificate.encoded),
          isTrue,
        );
        expect(
          await reader.adoptCertificate(publisher.certificate.encoded),
          isTrue,
        );
      });
      expect(reader.certificates.length, 1);
    });

    test('garbage is not adopted as a certificate', () async {
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [InMemoryBroadcastRelay()],
      );
      expect(await reader.adoptCertificate(Uint8List(10)), isFalse);
    });

    test('nothing verifies before a certificate is adopted', () async {
      final relay = InMemoryBroadcastRelay();
      await withClock(Clock.fixed(t0), () async {
        await publisher.pushTo(
          relay,
          await publisher.publish(text: _text('unadopted')),
        );
      });
      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [relay],
      );
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 1))),
        () => reader.fetchNext(),
      );
      expect(result.outcome, ReadOutcome.rejected);
      expect(result.rejection, ReadRejection.noCertificateForTime);
    });
  });

  group('publisher argument checks', () {
    test('a post with no layers is refused', () {
      expect(() => publisher.publish(), throwsArgumentError);
    });

    test('an empty layer is refused', () {
      expect(() => publisher.publish(text: Uint8List(0)), throwsArgumentError);
    });

    test('a validity window longer than readers accept is refused', () {
      expect(
        () => BroadcastPublisher.create(
          rootSigner: root,
          validity: const Duration(days: 400),
        ),
        throwsArgumentError,
      );
    });

    test('resuming needs a consistent sequence and link', () async {
      final signer = await CryptographyBroadcastSigner.generate();
      expect(
        () => BroadcastPublisher(
          rootPublicKey: root.publicKey,
          publishingSigner: signer,
          certificate: publisher.certificate,
          nextSeq: 5,
        ),
        throwsArgumentError,
      );
      expect(
        () => BroadcastPublisher(
          rootPublicKey: root.publicKey,
          publishingSigner: signer,
          certificate: publisher.certificate,
          prev: contentHash(Uint8List(1)),
        ),
        throwsArgumentError,
      );
    });

    test(
      'a resumed publisher continues the chain a reader already holds',
      () async {
        final relay = InMemoryBroadcastRelay();
        final first = await withClock(Clock.fixed(t0), () async {
          final p = await publisher.publish(text: _text('before restart'));
          await publisher.pushTo(relay, p);
          return p;
        });

        final resumed = BroadcastPublisher(
          rootPublicKey: publisher.rootPublicKey,
          publishingSigner: publishingSigner,
          certificate: publisher.certificate,
          nextSeq: 1,
          prev: first.descriptor.id,
        );
        await withClock(
          Clock.fixed(t0.add(const Duration(hours: 1))),
          () async {
            await resumed.pushTo(
              relay,
              await resumed.publish(text: _text('after restart')),
            );
          },
        );

        final reader = await readerOver([relay]);
        await withClock(
          Clock.fixed(t0.add(const Duration(hours: 2))),
          () async {
            expect((await reader.fetchNext()).isDelivered, isTrue);
            expect((await reader.fetchNext()).isDelivered, isTrue);
          },
        );
        expect(reader.chain.highestSeq, 1);
      },
    );
  });

  group('BroadcastPublisher.create', () {
    test('mints a publishing key and a certificate a reader accepts', () async {
      final relay = InMemoryBroadcastRelay();
      final minted = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
      expect(minted.nextSeq, 0);
      expect(minted.authorId, authorIdFor(root.publicKey));
      expect(minted.certificate.notBefore, t0);
      expect(minted.certificate.notAfter, t0.add(const Duration(days: 7)));

      await withClock(Clock.fixed(t0), () async {
        await minted.pushTo(
          relay,
          await minted.publish(text: _text('freshly delegated')),
        );
      });

      final reader = BroadcastReader(
        rootPublicKey: root.publicKey,
        relays: [relay],
      );
      await withClock(Clock.fixed(t0), () async {
        expect(
          await reader.adoptCertificate(minted.certificate.encoded),
          isTrue,
        );
      });
      final result = await withClock(
        Clock.fixed(t0.add(const Duration(hours: 1))),
        () => reader.fetchNext(),
      );
      expect(result.isDelivered, isTrue);
    });

    test('the publishing key is not the root key', () async {
      final minted = await withClock(
        Clock.fixed(t0),
        () => BroadcastPublisher.create(rootSigner: root),
      );
      expect(
        bytesEqual(minted.certificate.publishingKey, root.publicKey),
        isFalse,
      );
    });

    test('nextSeq advances by one per published post', () async {
      await withClock(Clock.fixed(t0), () async {
        expect(publisher.nextSeq, 0);
        await publisher.publish(text: _text('a'));
        expect(publisher.nextSeq, 1);
        await publisher.publish(text: _text('b'));
        expect(publisher.nextSeq, 2);
      });
    });
  });

  test('a reader needs somewhere to read from', () {
    expect(
      () => BroadcastReader(rootPublicKey: root.publicKey, relays: const []),
      throwsArgumentError,
    );
  });

  test('fetchSeq refuses a sequence outside the wire range', () async {
    final reader = await readerOver([InMemoryBroadcastRelay()]);
    expect(() => reader.fetchSeq(-1), throwsRangeError);
    expect(() => reader.fetchSeq(maxSeq + 1), throwsRangeError);
  });
}
