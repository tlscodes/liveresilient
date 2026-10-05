// Where sealed chunk boxes wait: the sender's until the receipt, the
// recipient's until the whole letter is there (and after, so the letter can
// be opened again). Boxes only — nothing here is in the clear.
import 'dart:io';
import 'dart:typed_data';

abstract class SealedBlobStore {
  Future<void> put(String name, Uint8List bytes);
  Future<Uint8List?> get(String name);

  /// Names that start with [prefix].
  Future<List<String>> list(String prefix);

  /// Removes every blob whose name starts with [prefix].
  Future<void> deletePrefix(String prefix);
}

class MemorySealedBlobStore implements SealedBlobStore {
  final Map<String, Uint8List> blobs = <String, Uint8List>{};

  @override
  Future<void> put(String name, Uint8List bytes) async {
    blobs[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> get(String name) async => blobs[name];

  @override
  Future<List<String>> list(String prefix) async => [
    for (final name in blobs.keys)
      if (name.startsWith(prefix)) name,
  ]..sort();

  @override
  Future<void> deletePrefix(String prefix) async {
    blobs.removeWhere((name, _) => name.startsWith(prefix));
  }
}

/// One file per blob in a folder. Names are made by the service from hex
/// ids and numbers only, so a name is always a safe file name; anything
/// else is refused rather than written.
class DiskSealedBlobStore implements SealedBlobStore {
  DiskSealedBlobStore(this._directoryFactory);

  final Directory Function() _directoryFactory;
  static final RegExp _safe = RegExp(r'^[a-z0-9.]{1,96}$');

  Directory get _dir => _directoryFactory();

  File _file(String name) {
    if (!_safe.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a blob name');
    }
    return File('${_dir.path}/$name');
  }

  @override
  Future<void> put(String name, Uint8List bytes) async {
    final file = _file(name);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<Uint8List?> get(String name) async {
    final file = _file(name);
    return await file.exists() ? await file.readAsBytes() : null;
  }

  @override
  Future<List<String>> list(String prefix) async {
    final dir = _dir;
    if (!await dir.exists()) return const <String>[];
    final names = <String>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (name.startsWith(prefix) && !name.endsWith('.tmp')) names.add(name);
    }
    return names..sort();
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    for (final name in await list(prefix)) {
      try {
        await _file(name).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}
