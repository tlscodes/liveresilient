import 'dart:convert';
import 'dart:io';

import 'package:device_link/durable_store.dart';
import 'package:device_link/src/dtn_bundle_queue.dart';
import 'package:device_link/src/mesh_flow_control.dart';
import 'package:test/test.dart';

DtnBundle _bundle(
  String id, {
  MeshMessagePriority priority = MeshMessagePriority.bulk,
}) {
  return DtnBundle(
    id: id,
    payload: utf8.encode('payload-$id'),
    priority: priority,
    createdAtMs: 1000,
    lifetimeMs: 60000,
  );
}

void main() {
  late Directory tempDir;
  late File logFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('durable_bundle_store_test');
    logFile = File('${tempDir.path}/bundles.log');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('CRUD basics', () {
    final store = DurableBundleStore.open(logFile);
    expect(store.length, 0);
    store.put(_bundle('a'));
    expect(store.contains('a'), isTrue);
    expect(store.length, 1);
    expect(store.values().single.id, 'a');
    store.remove('a');
    expect(store.contains('a'), isFalse);
    expect(store.length, 0);
  });

  test(
    're-open survives with identical live set, order, and payload bytes',
    () {
      final store = DurableBundleStore.open(logFile);
      store.put(_bundle('a', priority: MeshMessagePriority.callSignal));
      store.put(_bundle('b'));
      store.put(_bundle('c', priority: MeshMessagePriority.presence));

      final reopened = DurableBundleStore.open(logFile);
      final values = reopened.values().toList();
      expect(values.map((b) => b.id).toList(), ['a', 'b', 'c']);
      for (final b in values) {
        expect(b.payload, utf8.encode('payload-${b.id}'));
        expect(b.createdAtMs, 1000);
        expect(b.lifetimeMs, 60000);
      }
      expect(values[0].priority, MeshMessagePriority.callSignal);
      expect(values[2].priority, MeshMessagePriority.presence);
    },
  );

  test('remove persisted across re-open', () {
    final store = DurableBundleStore.open(logFile);
    store.put(_bundle('a'));
    store.put(_bundle('b'));
    store.remove('a');

    final reopened = DurableBundleStore.open(logFile);
    expect(reopened.contains('a'), isFalse);
    expect(reopened.contains('b'), isTrue);
    expect(reopened.length, 1);
  });

  test('compaction preserves live set', () {
    final store = DurableBundleStore.open(logFile);
    for (var i = 0; i < 10; i++) {
      store.put(_bundle('id$i'));
    }
    for (var i = 0; i < 8; i++) {
      store.remove('id$i');
    }
    store.compact();
    store.put(_bundle('id10'));

    final reopened = DurableBundleStore.open(logFile);
    expect(reopened.values().map((b) => b.id).toSet(), {'id8', 'id9', 'id10'});
  });

  test('corrupt trailing line tolerated', () {
    final store = DurableBundleStore.open(logFile);
    store.put(_bundle('a'));
    store.put(_bundle('b'));
    logFile.writeAsStringSync('{"op":"put","id":"c"', mode: FileMode.append);

    final reopened = DurableBundleStore.open(logFile);
    expect(reopened.values().map((b) => b.id).toSet(), {'a', 'b'});
  });

  test('works as the store of a real DtnBundleQueue', () {
    final store = DurableBundleStore.open(logFile);
    final queue = DtnBundleQueue(store: store);
    queue.offer(
      _bundle('x', priority: MeshMessagePriority.callSignal),
      nowMs: 1000,
    );
    queue.offer(_bundle('y'), nowMs: 1001);

    final reopenedStore = DurableBundleStore.open(logFile);
    final reopenedQueue = DtnBundleQueue(store: reopenedStore);
    final pending = reopenedQueue.pendingInDeliveryOrder(2000);
    expect(pending.map((b) => b.id).toList(), ['x', 'y']);
  });
}
