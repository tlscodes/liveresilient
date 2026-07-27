import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryBroadcastRelay relay;

  setUp(() => relay = InMemoryBroadcastRelay(name: 'one'));

  test('an object is filed under the hash of its own bytes', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await relay.putObject(bytes);
    final fetched = await relay.fetchObject(ObjectAddress(contentHash(bytes)));
    expect(fetched, bytes);
    expect(relay.objectCount, 1);
  });

  test('storing the same object twice is idempotent', () async {
    final bytes = Uint8List.fromList([7, 7, 7]);
    await relay.putObject(bytes);
    await relay.putObject(Uint8List.fromList(bytes));
    expect(relay.objectCount, 1);
  });

  test('a missing object reads as null, not as empty bytes', () async {
    expect(
      await relay.fetchObject(ObjectAddress(contentHash(Uint8List(1)))),
      isNull,
    );
  });

  test('fetch returns a copy, so a caller cannot edit stored bytes', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await relay.putObject(bytes);
    final address = ObjectAddress(contentHash(bytes));
    (await relay.fetchObject(address))![0] = 99;
    expect((await relay.fetchObject(address))![0], 1);
  });

  test(
    'a descriptor address may not be overwritten with other bytes',
    () async {
      // The rule that makes a fork visible instead of letting history be
      // quietly replaced.
      final address = DescriptorAddress(authorId: Uint8List(8), seq: 0);
      await relay.putDescriptor(address, Uint8List.fromList([1, 2, 3]));
      expect(
        () => relay.putDescriptor(address, Uint8List.fromList([4, 5, 6])),
        throwsStateError,
      );
      expect(await relay.fetchDescriptor(address), [1, 2, 3]);
    },
  );

  test(
    'rewriting a descriptor address with identical bytes is allowed',
    () async {
      final address = DescriptorAddress(authorId: Uint8List(8), seq: 0);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await relay.putDescriptor(address, bytes);
      await relay.putDescriptor(address, Uint8List.fromList(bytes));
      expect(relay.descriptorCount, 1);
    },
  );

  test('descriptor slots are keyed by author as well as sequence', () async {
    final a = DescriptorAddress(authorId: Uint8List(8), seq: 0);
    final b = DescriptorAddress(
      authorId: Uint8List.fromList(List.filled(8, 1)),
      seq: 0,
    );
    await relay.putDescriptor(a, Uint8List.fromList([1]));
    await relay.putDescriptor(b, Uint8List.fromList([2]));
    expect(relay.descriptorCount, 2);
    expect(await relay.fetchDescriptor(a), [1]);
    expect(await relay.fetchDescriptor(b), [2]);
  });

  test('clear models the short retention a relay is meant to have', () async {
    await relay.putObject(Uint8List.fromList([1]));
    await relay.putDescriptor(
      DescriptorAddress(authorId: Uint8List(8), seq: 0),
      Uint8List.fromList([1]),
    );
    relay.clear();
    expect(relay.objectCount, 0);
    expect(relay.descriptorCount, 0);
  });

  test('dropObject reports whether anything was there', () async {
    final bytes = Uint8List.fromList([5]);
    await relay.putObject(bytes);
    expect(relay.dropObject(contentHash(bytes)), isTrue);
    expect(relay.dropObject(contentHash(bytes)), isFalse);
  });

  test('the relay name is what a reader reports back', () async {
    expect(relay.name, 'one');
    expect(InMemoryBroadcastRelay().name, 'memory');
  });
}
