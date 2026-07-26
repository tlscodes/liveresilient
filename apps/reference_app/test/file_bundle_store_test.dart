/// [FileBundleStore]: durable append-only-log [BundleStore] — CRUD,
/// survival across close/re-open, compaction, and corrupt-line tolerance.
library;

import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/file_bundle_store.dart';

DtnBundle _bundle(String id, {int createdAtMs = 1000, List<int>? payload}) =>
    DtnBundle(
      id: id,
      payload: payload ?? List<int>.filled(8, id.hashCode % 256),
      priority: LinkMessagePriority.bulk,
      createdAtMs: createdAtMs,
      lifetimeMs: const Duration(minutes: 10).inMilliseconds,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_bundle_store_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('CRUD operations behave like the in-memory store', () async {
    final file = File('${tempDir.path}/bundles.log');
    final store = await FileBundleStore.open(file);
    addTearDown(store.close);

    expect(store.length, 0);
    expect(store.contains('a'), isFalse);

    store.put(_bundle('a'));
    store.put(_bundle('b'));
    expect(store.length, 2);
    expect(store.contains('a'), isTrue);
    expect(store.values().map((b) => b.id), ['a', 'b']);

    store.remove('a');
    expect(store.length, 1);
    expect(store.contains('a'), isFalse);
    expect(store.values().single.id, 'b');
  });

  test('bundles survive close/re-open: live set, insertion order, and '
      'payload bytes are all intact', () async {
    final file = File('${tempDir.path}/bundles.log');
    final store1 = await FileBundleStore.open(file);
    final payloadA = [1, 2, 3, 4, 5];
    final payloadC = [9, 9, 9];
    store1.put(_bundle('a', payload: payloadA));
    store1.put(_bundle('b'));
    store1.put(_bundle('c', payload: payloadC));
    store1.remove('b');
    await store1.close();

    final store2 = await FileBundleStore.open(file);
    addTearDown(store2.close);

    expect(store2.length, 2);
    expect(store2.values().map((b) => b.id).toList(), ['a', 'c']);
    expect(store2.values().firstWhere((b) => b.id == 'a').payload, payloadA);
    expect(store2.values().firstWhere((b) => b.id == 'c').payload, payloadC);
  });

  test('compaction preserves the live set and shrinks the log', () async {
    final file = File('${tempDir.path}/bundles.log');
    final store = await FileBundleStore.open(file);
    addTearDown(store.close);

    for (var i = 0; i < 10; i++) {
      store.put(_bundle('id-$i'));
      store.remove('id-$i');
    }
    store.put(_bundle('keeper'));

    await store.compact();
    final linesAfterCompact = await file.readAsLines();

    expect(store.length, 1);
    expect(store.values().single.id, 'keeper');
    // Compaction rewrites the log to only the live records: one `put` line.
    expect(linesAfterCompact.where((l) => l.trim().isNotEmpty), hasLength(1));

    // Re-open to confirm the compacted log alone reconstitutes correctly.
    await store.close();
    final reopened = await FileBundleStore.open(file);
    addTearDown(reopened.close);
    expect(reopened.length, 1);
    expect(reopened.values().single.id, 'keeper');
  });

  test('a corrupt trailing line is skipped on replay', () async {
    final file = File('${tempDir.path}/bundles.log');
    final store = await FileBundleStore.open(file);
    store.put(_bundle('good'));
    await store.close();

    // Simulate a crash mid-write: append a truncated/garbage line.
    await file.writeAsString(
      '{"op":"put","id":"broken"garbage\n',
      mode: FileMode.append,
    );

    final reopened = await FileBundleStore.open(file);
    addTearDown(reopened.close);
    expect(reopened.length, 1);
    expect(reopened.values().single.id, 'good');
  });
}
