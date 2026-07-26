/// Durable, disk-backed [BundleStore] for the DTN fallback queue: an
/// append-only JSON-lines log so a bundle offered while the app is degraded
/// survives an app restart. Lives in the app (not `packages/device_link`)
/// because it needs `dart:io`, which the package deliberately does not
/// depend on.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:device_link/device_link.dart';

/// [BundleStore] backed by an append-only log file: one JSON object per
/// line, either `{"op":"put",...}` or `{"op":"remove","id":...}`. Opening
/// the file replays the log into an in-memory, insertion-ordered mirror
/// (later ops win); `put`/`remove` append synchronously and update the
/// mirror. A corrupt trailing line (e.g. a write cut short by a crash) is
/// skipped rather than failing the whole replay.
class FileBundleStore implements BundleStore {
  FileBundleStore._(this._file, this._sink, this._bundles);

  final File _file;
  IOSink _sink;
  final LinkedHashMap<String, DtnBundle> _bundles;

  /// Opens (creating if absent) the log at [file] and replays it.
  static Future<FileBundleStore> open(File file) async {
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    // ignore: prefer_collection_literals
    final bundles = LinkedHashMap<String, DtnBundle>();
    var live = 0;
    var dead = 0;
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> record;
      try {
        record = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        // Corrupt trailing line (e.g. a partial write) — skip it.
        continue;
      }
      try {
        final op = record['op'] as String;
        if (op == 'put') {
          final id = record['id'] as String;
          bundles[id] = DtnBundle(
            id: id,
            payload: base64Decode(record['payload'] as String),
            priority: LinkMessagePriority.values[record['priority'] as int],
            createdAtMs: record['createdAtMs'] as int,
            lifetimeMs: record['lifetimeMs'] as int,
          );
          live++;
        } else if (op == 'remove') {
          final id = record['id'] as String;
          if (bundles.remove(id) != null) {
            live--;
          }
          dead++;
        }
      } catch (_) {
        // Malformed record — skip it, keep replaying the rest of the log.
        continue;
      }
    }
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    final store = FileBundleStore._(file, sink, bundles);
    // Auto-compact when the log carries more dead weight than live records.
    if (dead > live) {
      await store.compact();
    }
    return store;
  }

  @override
  void put(DtnBundle bundle) {
    _bundles[bundle.id] = bundle;
    _appendSync(<String, dynamic>{
      'op': 'put',
      'id': bundle.id,
      'payload': base64Encode(bundle.payload),
      'priority': bundle.priority.index,
      'createdAtMs': bundle.createdAtMs,
      'lifetimeMs': bundle.lifetimeMs,
    });
  }

  @override
  void remove(String id) {
    final existed = _bundles.remove(id) != null;
    if (existed) {
      _appendSync(<String, dynamic>{'op': 'remove', 'id': id});
    }
  }

  @override
  bool contains(String id) => _bundles.containsKey(id);

  @override
  Iterable<DtnBundle> values() => _bundles.values;

  @override
  int get length => _bundles.length;

  void _appendSync(Map<String, dynamic> record) {
    _sink.writeln(jsonEncode(record));
  }

  /// Rewrites the log to contain only the currently-live records, dropping
  /// every superseded `put`/matched `remove` pair. Safe to call any time;
  /// [open] calls it automatically when the log is dominated by dead
  /// records.
  Future<void> compact() async {
    await _sink.flush();
    await _sink.close();
    final tmp = File('${_file.path}.compact.tmp');
    final tmpSink = tmp.openWrite(mode: FileMode.writeOnly);
    for (final bundle in _bundles.values) {
      tmpSink.writeln(
        jsonEncode(<String, dynamic>{
          'op': 'put',
          'id': bundle.id,
          'payload': base64Encode(bundle.payload),
          'priority': bundle.priority.index,
          'createdAtMs': bundle.createdAtMs,
          'lifetimeMs': bundle.lifetimeMs,
        }),
      );
    }
    await tmpSink.flush();
    await tmpSink.close();
    await tmp.rename(_file.path);
    _sink = _file.openWrite(mode: FileMode.writeOnlyAppend);
  }

  /// Flushes and closes the underlying file handle. Call before the app
  /// exits or when done with this store in a test.
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}
