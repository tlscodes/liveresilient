// The letter queue sealed at rest: the file under letters/ is never raw
// JSON and never holds the letter's text; the key is the keystore's alone,
// and without it the file reads as nothing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        ConnectivitySnapshot,
        DeliveryOutcome,
        FabricMode,
        LaneStatus,
        ResilientLaneIds;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_composer.dart' show LetterState;
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_queue.dart';
import 'package:security/security.dart' show InMemoryKeyStore, KeyMaterialStore;

const _text = 'meet at the north gate at seven';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('letters'));
  tearDown(() => dir.delete(recursive: true));

  File sealedFile() =>
      File('${dir.path}/${SealedFileLetterQueueStore.fileName}');

  /// The raw file is ciphertext: magic header, not JSON, no letter text
  /// (neither plain nor base64).
  void expectSealed(File f) {
    final raw = f.readAsBytesSync();
    expect(utf8.decode(raw.sublist(0, 4)), 'VLQ1');
    expect(
      () => jsonDecode(utf8.decode(raw, allowMalformed: true)),
      throwsFormatException,
    );
    final asText = latin1.decode(raw);
    expect(asText, isNot(contains(_text)));
    expect(asText, isNot(contains(base64Encode(utf8.encode(_text)))));
    expect(asText, isNot(contains('"bytes"')));
  }

  QueuedLetter letter(String id) => QueuedLetter(
    id: id,
    bytes: Uint8List.fromList(utf8.encode(_text)),
    kind: 'typed',
    queuedAt: DateTime.utc(2026, 10, 4, 12),
  );

  test('empty queue: nothing on disk loads empty; an empty save is sealed '
      'and reads back empty', () async {
    final keys = InMemoryKeyStore();
    final store = SealedFileLetterQueueStore(dir, keys);
    expect(await store.load(), isEmpty);
    await store.save(const []);
    expectSealed(sealedFile());
    expect(await SealedFileLetterQueueStore(dir, keys).load(), isEmpty);
  });

  test('one letter: sealed on disk, round-trips with the key, reads as '
      'nothing without it or with another key', () async {
    final keys = InMemoryKeyStore();
    await SealedFileLetterQueueStore(dir, keys).save([letter('a')]);
    expectSealed(sealedFile());

    final back = await SealedFileLetterQueueStore(dir, keys).load();
    expect(back.single.id, 'a');
    expect(utf8.decode(back.single.bytes), _text);

    expect(
      await SealedFileLetterQueueStore(dir, InMemoryKeyStore()).load(),
      isEmpty,
    );
    final other = InMemoryKeyStore();
    await other.write(
      SealedFileLetterQueueStore.keyHandle,
      Uint8List.fromList(List<int>.filled(32, 7)),
    );
    expect(await SealedFileLetterQueueStore(dir, other).load(), isEmpty);
    // A failed read never overwrites the sealed file.
    expect((await SealedFileLetterQueueStore(dir, keys).load()).single.id, 'a');
  });

  test('a parked letter: the courier parks it behind a closed door; the '
      'file is sealed and only the key brings it back', () async {
    final keys = InMemoryKeyStore();
    var now = DateTime(2026, 10, 4, 12);
    final courier = LetterCourier(
      endpoints: () => throw StateError('scripted lanes, never assembled'),
      budget: const LetterCourierBudget(
        select: Duration(milliseconds: 300),
        carry: Duration(seconds: 15),
        refreshEvery: Duration(milliseconds: 50),
      ),
      now: () => now,
      queue: LetterQueue(SealedFileLetterQueueStore(dir, keys)),
      openLanes: () async => _ClosedLanes(),
      wait: (d) async => now = now.add(d),
      schedulePeriodic: (_, _) => _HeldTimer(),
    );
    final state = await courier.send(
      Uint8List.fromList(utf8.encode(_text)),
      kind: 'typed',
    );
    await courier.dispose();

    expect(state, LetterState.queued);
    expectSealed(sealedFile());
    expect(
      File('${dir.path}/${FileLetterQueueStore.fileName}').existsSync(),
      isFalse,
    );
    final parked = await SealedFileLetterQueueStore(dir, keys).load();
    expect(utf8.decode(parked.single.bytes), _text);
    expect(
      await SealedFileLetterQueueStore(dir, InMemoryKeyStore()).load(),
      isEmpty,
    );
  });

  test(
    'a raw JSON queue from an older build is sealed once and deleted',
    () async {
      await FileLetterQueueStore(dir).save([letter('old')]);
      final legacy = File('${dir.path}/${FileLetterQueueStore.fileName}');
      expect(legacy.existsSync(), isTrue);

      final keys = InMemoryKeyStore();
      final moved = await SealedFileLetterQueueStore(dir, keys).load();
      expect(moved.single.id, 'old');
      expect(legacy.existsSync(), isFalse);
      expectSealed(sealedFile());
      expect(
        (await SealedFileLetterQueueStore(dir, keys).load()).single.id,
        'old',
      );
    },
  );

  test(
    'a failing keystore keeps the queue in memory, never in the clear',
    () async {
      final store = SealedFileLetterQueueStore(dir, _BrokenKeys());
      await store.save([letter('m')]);
      expect(dir.listSync(), isEmpty);
      expect((await store.load()).single.id, 'm');
    },
  );
}

class _BrokenKeys implements KeyMaterialStore {
  @override
  Future<Uint8List?> read(String keyHandle) =>
      Future.error(StateError('keystore unavailable'));
  @override
  Future<void> write(String keyHandle, Uint8List seed) =>
      Future.error(StateError('keystore unavailable'));
  @override
  Future<void> delete(String keyHandle) async {}
}

/// Every lane dead: the courier parks the letter without offering it.
class _ClosedLanes implements LetterLanes {
  @override
  Future<void> refresh() async {}

  @override
  ConnectivitySnapshot get snapshot {
    final lanes = [
      const LaneStatus(
        id: ResilientLaneIds.webSocketRelay,
        eligible: true,
        score: -1.05,
      ),
      const LaneStatus(
        id: ResilientLaneIds.httpLongPoll,
        eligible: true,
        score: -1.10,
      ),
      const LaneStatus(
        id: ResilientLaneIds.txtQuery,
        eligible: true,
        score: -1.15,
      ),
    ];
    return ConnectivitySnapshot(
      mode: FabricMode.storeAndForward,
      lanes: lanes,
      bestLaneId: lanes.first.id,
      pendingBundles: 0,
      atMs: 0,
    );
  }

  @override
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  }) => throw StateError('a closed door is never offered a letter');

  @override
  void reclaim(String bundleId) {}

  @override
  bool get hasDoor => true;

  @override
  String? get doorSessionId => null;

  @override
  Future<void> dispose() async {}
}

class _HeldTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
