/// Durable JSON persistence for the learning models — crash-safe by
/// construction.
///
/// Writes are atomic (temp file + rename) so a power loss mid-write can
/// never corrupt the previous good state; reads of a damaged file return
/// an empty map (the "fresh brain"). Saves are debounced so per-sample
/// learning never turns into per-sample disk I/O.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Abstract persistence seam (fake in tests, disk in production).
abstract interface class PersistentStorage {
  Future<void> save(Map<String, Object?> data);
  Future<Map<String, Object?>> load();
}

/// Atomic-write JSON file storage.
class DiskJsonStorage implements PersistentStorage {
  DiskJsonStorage({required this._directoryFactory, required this.fileName});

  final Directory Function() _directoryFactory;
  final String fileName;

  File get _file => File('${_directoryFactory().path}/$fileName');

  @override
  Future<void> save(Map<String, Object?> data) async {
    try {
      final dir = _directoryFactory();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // Atomic: write beside the target, then rename over it. A crash
      // between the two steps leaves the OLD file intact.
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(_file.path);
    } catch (_) {
      // Disk trouble must never break the app's main flow.
    }
  }

  @override
  Future<Map<String, Object?>> load() async {
    try {
      if (!_file.existsSync()) return {};
      final decoded = jsonDecode(await _file.readAsString());
      return decoded is Map<String, Object?>
          ? decoded
          : decoded is Map
          ? decoded.map((k, v) => MapEntry(k.toString(), v))
          : {};
    } catch (_) {
      return {}; // Corrupt file → fresh brain, never a crash.
    }
  }
}

/// Debounces frequent save requests into rare disk writes, and flushes
/// on demand (e.g. app pause).
class DebouncedSaver {
  DebouncedSaver({
    required this._storage,
    required this._snapshot,
    this.delay = const Duration(seconds: 5),
  });

  final PersistentStorage _storage;
  final Map<String, Object?> Function() _snapshot;
  final Duration delay;
  Timer? _timer;
  bool _disposed = false;

  /// Marks state dirty; the actual write happens at most once per [delay].
  void markDirty() {
    if (_disposed) return;
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaited(_storage.save(_snapshot()));
    });
  }

  /// Writes immediately (app going to background, fabric disposing).
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _storage.save(_snapshot());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await flush();
    _disposed = true;
  }
}
