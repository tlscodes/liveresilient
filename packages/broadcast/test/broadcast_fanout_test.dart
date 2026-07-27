import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:clock/clock.dart';
import 'package:test/test.dart';

/// A relay that refuses with a chosen status shape.
class _RefusingRelay implements BroadcastRelay {
  _RefusingRelay(this.name, this.failure, {this.onlyDescriptor = false});

  @override
  final String name;

  final BroadcastPublishFailure failure;

  /// When true, objects are accepted and only the descriptor is refused —
  /// the shape a rate limit or a used sequence number takes.
  final bool onlyDescriptor;

  final InMemoryBroadcastRelay _backing = InMemoryBroadcastRelay();

  int objectsAccepted = 0;

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress a) =>
      _backing.fetchDescriptor(a);

  @override
  Future<Uint8List?> fetchObject(ObjectAddress a) => _backing.fetchObject(a);

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async {
    throw BroadcastPublishRejected(
      failure,
      409,
      Uri.parse('https://x/${a.seq}'),
    );
  }

  @override
  Future<void> putObject(Uint8List bytes) async {
    if (onlyDescriptor) {
      objectsAccepted += 1;
      return _backing.putObject(bytes);
    }
    throw BroadcastPublishRejected(failure, 413, Uri.parse('https://x/o'));
  }
}

/// A relay whose transport simply breaks.
class _BrokenRelay implements BroadcastRelay {
  @override
  String get name => 'broken';

  @override
  Future<Uint8List?> fetchDescriptor(DescriptorAddress a) async => null;

  @override
  Future<Uint8List?> fetchObject(ObjectAddress a) async => null;

  @override
  Future<void> putDescriptor(DescriptorAddress a, Uint8List e) async =>
      throw StateError('socket died');

  @override
  Future<void> putObject(Uint8List bytes) async =>
      throw StateError('socket died');
}

void main() {
  final t0 = DateTime.utc(2026, 7, 28, 12);

  late CryptographyBroadcastSigner root;
  late BroadcastPublisher publisher;

  setUp(() async {
    root = await CryptographyBroadcastSigner.generate();
    publisher = await withClock(
      Clock.fixed(t0),
      () => BroadcastPublisher.create(rootSigner: root),
    );
  });

  Future<BroadcastPost> post([String body = 'a message']) => withClock(
    Clock.fixed(t0),
    () => publisher.publish(text: Uint8List.fromList(body.codeUnits)),
  );

  test('a post reaches every healthy relay', () async {
    final relays = [
      InMemoryBroadcastRelay(name: 'a'),
      InMemoryBroadcastRelay(name: 'b'),
      InMemoryBroadcastRelay(name: 'c'),
    ];
    final result = await BroadcastFanout(relays: relays).publish(await post());
    expect(result.storedOn, ['a', 'b', 'c']);
    expect(result.failures, isEmpty);
    for (final relay in relays) {
      expect(relay.descriptorCount, 1);
      expect(relay.objectCount, 1);
    }
  });

  test('one dead relay does not stop the publish', () async {
    // The property replication exists for: reach degrades, publishing does
    // not fail.
    final healthy = InMemoryBroadcastRelay(name: 'healthy');
    final result = await BroadcastFanout(
      relays: [_BrokenRelay(), healthy],
    ).publish(await post());
    expect(result.storedOn, ['healthy']);
    expect(result.failures, {'broken': BroadcastPublishFailure.refused});
    expect(healthy.descriptorCount, 1);
  });

  test('every relay failing raises, with the reasons attached', () async {
    await expectLater(
      BroadcastFanout(
        relays: [
          _BrokenRelay(),
          _RefusingRelay('full', BroadcastPublishFailure.outOfSpace),
        ],
      ).publish(await post()),
      throwsA(
        isA<BroadcastFanoutFailed>()
            .having((e) => e.required, 'required', 1)
            .having((e) => e.result.storedCount, 'storedCount', 0)
            .having(
              (e) => e.result.failures['full'],
              'full',
              BroadcastPublishFailure.outOfSpace,
            ),
      ),
    );
  });

  test(
    'a quorum below the requirement raises even though one relay took it',
    () async {
      final healthy = InMemoryBroadcastRelay(name: 'healthy');
      await expectLater(
        BroadcastFanout(
          relays: [healthy, _BrokenRelay()],
          minimumRelays: 2,
        ).publish(await post()),
        throwsA(
          isA<BroadcastFanoutFailed>()
              .having((e) => e.required, 'required', 2)
              .having((e) => e.result.storedCount, 'storedCount', 1),
        ),
      );
      // The relay that accepted still holds it: this is a report, not a
      // rollback. There is nothing to roll back to on an immutable store.
      expect(healthy.descriptorCount, 1);
    },
  );

  test('a relay that fails partway gets no descriptor', () async {
    // Otherwise it would advertise a post whose layers it cannot serve,
    // spending a reader's scarcest resource on a dead end.
    final relay = _RefusingRelay(
      'partial',
      BroadcastPublishFailure.rateLimited,
      onlyDescriptor: true,
    );
    final healthy = InMemoryBroadcastRelay(name: 'healthy');
    final result = await BroadcastFanout(
      relays: [relay, healthy],
    ).publish(await post());

    expect(result.storedOn, ['healthy']);
    expect(result.failures, {'partial': BroadcastPublishFailure.rateLimited});
    expect(relay.objectsAccepted, 1, reason: 'the object went through');
    expect(
      await relay.fetchDescriptor(
        DescriptorAddress(authorId: publisher.authorId, seq: 0),
      ),
      isNull,
      reason: 'the descriptor did not',
    );
  });

  test('a conflict is called out separately from a relay being down', () async {
    // A conflict says the publisher's own sequence state disagrees with the
    // world, which retrying cannot fix.
    final conflicted = await BroadcastFanout(
      relays: [
        InMemoryBroadcastRelay(name: 'ok'),
        _RefusingRelay('taken', BroadcastPublishFailure.conflict),
      ],
    ).publish(await post());
    expect(conflicted.sawConflict, isTrue);

    final merelyDown = await BroadcastFanout(
      relays: [
        InMemoryBroadcastRelay(name: 'ok'),
        _BrokenRelay(),
      ],
    ).publish(await post('second'));
    expect(merelyDown.sawConflict, isFalse);
  });

  test(
    'a reader over the same relays finds the post after any single loss',
    () async {
      final a = InMemoryBroadcastRelay(name: 'a');
      final b = InMemoryBroadcastRelay(name: 'b');
      final c = InMemoryBroadcastRelay(name: 'c');
      await BroadcastFanout(relays: [a, b, c]).publish(await post('resilient'));

      for (final lost in [a, b, c]) {
        lost.clear();
        final reader = BroadcastReader(
          rootPublicKey: root.publicKey,
          relays: [a, b, c],
        );
        await withClock(
          Clock.fixed(t0),
          () => reader.adoptCertificate(publisher.certificate.encoded),
        );
        final result = await withClock(
          Clock.fixed(t0.add(const Duration(minutes: 1))),
          () => reader.fetchNext(),
        );
        expect(
          result.isDelivered,
          isTrue,
          reason: 'must survive losing ${lost.name}',
        );
        // Restore for the next round so exactly one relay is missing each
        // time.
        await BroadcastFanout(
          relays: [lost],
        ).publish(BroadcastPost(descriptor: result.descriptor!, objects: {}));
      }
    },
  );

  test('argument checks', () {
    expect(() => BroadcastFanout(relays: const []), throwsArgumentError);
    expect(
      () =>
          BroadcastFanout(relays: [InMemoryBroadcastRelay()], minimumRelays: 2),
      throwsArgumentError,
    );
    expect(
      () =>
          BroadcastFanout(relays: [InMemoryBroadcastRelay()], minimumRelays: 0),
      throwsArgumentError,
    );
  });

  test('the failure message names the shortfall and the reasons', () {
    final result = FanoutResult([
      const RelayPublishOutcome.stored('a'),
      const RelayPublishOutcome.failed('b', BroadcastPublishFailure.tooLarge),
    ]);
    final error = BroadcastFanoutFailed(result, 2);
    expect(error.toString(), contains('1 of 2'));
    expect(error.toString(), contains('needed 2'));
    expect(error.toString(), contains('tooLarge'));
  });
}
