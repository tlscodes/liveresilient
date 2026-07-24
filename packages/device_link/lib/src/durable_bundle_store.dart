/// Disk-backed [BundleStore]: an append-only JSON-lines log that survives
/// process restart. Kept out of the neutral `device_link.dart` barrel (it
/// pulls in `dart:io`); use `package:device_link/durable_store.dart` to
/// opt in on platforms that have a filesystem.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'dtn_bundle_queue.dart' show BundleStore, DtnBundle;
import 'mesh_flow_control.dart' show MeshMessagePriority;

/// A [BundleStore] backed by an append-only log file. Each line is one JSON
/// record: `{"op":"put", ...bundle fields}` or `{"op":"remove","id":...}`.
/// On [open], the log is replayed in order (later ops win) into an
/// insertion-ordered map. `put`/`remove` append synchronously so state is
/// durable across process restart.
class DurableBundleStore implements BundleStore {
  DurableBundleStore._(this._file, this._bundles, int deadCount)
    : _deadCount = deadCount;

  final File _file;
  final LinkedHashMap<String, DtnBundle> _bundles;
  int _deadCount;

  /// Opens (creating if absent) the log at [file], replaying prior state.
  /// Auto-compacts if dead (removed/overwritten) records outnumber live
  /// ones.
  static DurableBundleStore open(File file) {
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    final bundles = LinkedHashMap<String, DtnBundle>();
    var deadCount = 0;
    final lines = file.readAsLinesSync();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> record;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        record = decoded;
      } catch (_) {
        // Corrupt/partial trailing line — skip it.
        continue;
      }
      final op = record['op'];
      final id = record['id'];
      if (id is! String) continue;
      if (op == 'put') {
        try {
          final bundle = _bundleFromRecord(record);
          if (bundles.containsKey(id)) deadCount++;
          bundles[id] = bundle;
        } catch (_) {
          continue;
        }
      } else if (op == 'remove') {
        if (bundles.remove(id) != null) {
          deadCount++;
        } else {
          deadCount++;
        }
      }
    }

    final store = DurableBundleStore._(file, bundles, deadCount);
    if (deadCount > bundles.length) {
      store.compact();
    }
    return store;
  }

  static DtnBundle _bundleFromRecord(Map<String, dynamic> record) {
    return DtnBundle(
      id: record['id'] as String,
      payload: base64Decode(record['payload'] as String),
      priority: MeshMessagePriority.values.byName(record['priority'] as String),
      createdAtMs: record['createdAtMs'] as int,
      lifetimeMs: record['lifetimeMs'] as int,
    );
  }

  Map<String, dynamic> _recordFromBundle(DtnBundle bundle) => {
    'op': 'put',
    'id': bundle.id,
    'payload': base64Encode(bundle.payload),
    'priority': bundle.priority.name,
    'createdAtMs': bundle.createdAtMs,
    'lifetimeMs': bundle.lifetimeMs,
  };

  void _appendLine(Map<String, dynamic> record) {
    _file.writeAsStringSync(
      '${jsonEncode(record)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Number of dead (superseded/removed) records currently in the log.
  int get deadRecordCount => _deadCount;

  @override
  void put(DtnBundle bundle) {
    if (_bundles.containsKey(bundle.id)) _deadCount++;
    _bundles[bundle.id] = bundle;
    _appendLine(_recordFromBundle(bundle));
  }

  @override
  void remove(String id) {
    final removed = _bundles.remove(id) != null;
    if (removed) {
      _deadCount++;
      _appendLine({'op': 'remove', 'id': id});
    }
  }

  @override
  bool contains(String id) => _bundles.containsKey(id);

  @override
  Iterable<DtnBundle> values() => _bundles.values;

  @override
  int get length => _bundles.length;

  /// Rewrites the log to contain only the current live records, dropping
  /// dead history. Safe to call any time; called automatically on [open]
  /// when dead records outnumber live ones.
  void compact() {
    final tmp = File('${_file.path}.compact.tmp');
    final buffer = StringBuffer();
    for (final bundle in _bundles.values) {
      buffer.writeln(jsonEncode(_recordFromBundle(bundle)));
    }
    tmp.writeAsStringSync(buffer.toString(), flush: true);
    tmp.renameSync(_file.path);
    _deadCount = 0;
  }
}
