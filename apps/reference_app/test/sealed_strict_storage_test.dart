// Phase چ regression: a letter must survive a locked, protected-data-off
// wake (iOS before/at a background turn) and the receipt must still come back
// once the phone is unlocked. The overnight fix is two invariants:
//   1. strict DiskJsonStorage rethrows on an unreadable file instead of
//      reading it as empty (so a whole-snapshot saver never overwrites what
//      it never saw);
//   2. SealedLetterService loads before it saves, so a failed load leaves the
//      store untouched, and one background turn on a locked phone records the
//      reason and resubmits — it never wipes the inbox and never crashes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_background.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:security/security.dart';

import 'support/memory_shelf.dart';

/// Loads throw (a locked phone cannot read protected data); every save is
/// counted so a test can prove the store was never overwritten.
class _ThrowingStorage implements PersistentStorage {
  _ThrowingStorage(this.data);
  Map<String, Object?> data;
  int saveCalls = 0;
  bool failLoad = true;

  @override
  Future<Map<String, Object?>> load() async {
    if (failLoad) {
      throw const FileSystemException('protected data unavailable');
    }
    return jsonDecode(jsonEncode(data)) as Map<String, Object?>;
  }

  @override
  Future<void> save(Map<String, Object?> d) async {
    saveCalls++;
    data = jsonDecode(jsonEncode(d)) as Map<String, Object?>;
  }
}

class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};
  @override
  Future<Map<String, Object?>> load() async =>
      jsonDecode(jsonEncode(data)) as Map<String, Object?>;
  @override
  Future<void> save(Map<String, Object?> d) async {
    data = jsonDecode(jsonEncode(d)) as Map<String, Object?>;
  }
}

AppIdentity _newIdentity() => AppIdentity(
  engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
  pins: PinnedPeerStore(_MemoryStorage()),
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('DiskJsonStorage strict', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('strict_store_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file reads empty in both modes', () async {
      final loose = DiskJsonStorage(directoryFactory: () => dir, fileName: 'a');
      final strict = DiskJsonStorage(
        directoryFactory: () => dir,
        fileName: 'b',
        strict: true,
      );
      expect(await loose.load(), isEmpty);
      expect(await strict.load(), isEmpty);
    });

    test('a readable file round-trips', () async {
      final s = DiskJsonStorage(
        directoryFactory: () => dir,
        fileName: 'ok',
        strict: true,
      );
      await s.save(<String, Object?>{'v': 2, 'n': 7});
      expect(await s.load(), <String, Object?>{'v': 2, 'n': 7});
    });

    test('an unreadable file: strict rethrows, loose reads empty', () async {
      // A real file the process cannot read (chmod 000) — iOS before first
      // unlock fails readAsBytes the same way, with existsSync still true.
      final path = '${dir.path}/blocked';
      File(path).writeAsStringSync('{"v":2}');
      Process.runSync('chmod', <String>['000', path]);
      addTearDown(() => Process.runSync('chmod', <String>['644', path]));
      var readable = true;
      try {
        File(path).readAsBytesSync();
      } catch (_) {
        readable = false;
      }
      if (readable) return; // running as root: the invariant is untestable.
      final loose = DiskJsonStorage(
        directoryFactory: () => dir,
        fileName: 'blocked',
      );
      final strict = DiskJsonStorage(
        directoryFactory: () => dir,
        fileName: 'blocked',
        strict: true,
      );
      expect(await loose.load(), isEmpty);
      await expectLater(strict.load(), throwsA(isA<FileSystemException>()));
    });

    test('a readable but non-JSON file is empty even in strict', () async {
      File('${dir.path}/junk').writeAsStringSync('not json {{{');
      final strict = DiskJsonStorage(
        directoryFactory: () => dir,
        fileName: 'junk',
        strict: true,
      );
      expect(await strict.load(), isEmpty);
    });
  });

  group('SealedLetterService never overwrites after a failed load', () {
    test(
      'load() rethrows and flush() writes nothing when the store throws',
      () async {
        final relay = MemoryRelay();
        final id = _hex(await _newIdentity().installId());
        final storage = _ThrowingStorage(<String, Object?>{
          'v': 2,
          'inbox': <Object?>['a prior letter the locked wake must not destroy'],
        });
        final service = SealedLetterService(
          identity: _newIdentity(),
          shelf: relay.shelfOf(id),
          storage: storage,
        );
        await expectLater(service.load(), throwsA(isA<FileSystemException>()));
        await expectLater(service.flush(), throwsA(isA<FileSystemException>()));
        expect(storage.saveCalls, 0);
        expect(storage.data['inbox'], isNotEmpty);
      },
    );
  });

  group('one background turn on a locked phone', () {
    test('records the reason, resubmits, and wipes nothing', () async {
      final relay = MemoryRelay();
      final id = _hex(await _newIdentity().installId());
      final storage = _ThrowingStorage(<String, Object?>{
        'v': 2,
        'inbox': <Object?>['kept'],
      });
      final phone = SealedLetterService(
        identity: _newIdentity(),
        shelf: relay.shelfOf(id),
        storage: storage,
      );
      final journal = <Map<String, Object?>>[];
      final turn = SealedBackgroundTurn(
        service: () async => phone,
        notify: (_) async => const SealedNotifyResult(auth: 'authorized'),
        journal: (e, f) => journal.add({'event': e, ...f}),
      );
      final r = await turn.run(
        id: 'x.sealed.refresh',
        launchReason: 'bg_refresh',
        appState: 'background',
        protectedData: false,
      );
      // The turn never throws: the load failure is a journal line.
      expect(r['error'], 'FileSystemException');
      expect(r['looked'], isFalse);
      expect(r['fresh'], 0);
      expect(r['expired'], isFalse);
      expect(r['resubmit'], isTrue);
      // Nothing drained, so nothing was written over the kept inbox.
      expect(storage.saveCalls, 0);
      expect(storage.data['inbox'], <Object?>['kept']);
      final bg = journal.lastWhere((e) => e['event'] == 'bg_turn');
      expect(bg['error'], 'FileSystemException');
    });
  });
}
