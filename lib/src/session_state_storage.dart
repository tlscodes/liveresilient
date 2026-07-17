import 'dart:convert';
import 'dart:io';

/// Persists session state as a local JSON config file inside a given
/// root directory, and physically removes that file when the storage
/// is closed.
class SessionStateStorage {
  /// [rootDirectoryPath] is the local project-root directory the config
  /// file lives in. [fileName] can be overridden for tests.
  SessionStateStorage(
    this.rootDirectoryPath, {
    this.fileName = 'session_state.json',
  });

  /// Local directory (project root) that holds the config file.
  final String rootDirectoryPath;

  /// Name of the JSON config file inside [rootDirectoryPath].
  final String fileName;

  bool _closed = false;

  File get _file =>
      File('$rootDirectoryPath${Platform.pathSeparator}$fileName');

  /// Absolute path of the config file this storage manages.
  String get filePath => _file.path;

  /// Whether [close] has already been called.
  bool get isClosed => _closed;

  /// Serializes [state] as pretty-printed JSON and writes it to the
  /// config file inside the root directory, creating the directory
  /// if needed. Returns the written file.
  Future<File> save(Map<String, dynamic> state) async {
    if (_closed) {
      throw StateError('SessionStateStorage is closed.');
    }
    final dir = Directory(rootDirectoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    const encoder = JsonEncoder.withIndent('  ');
    return _file.writeAsString(encoder.convert(state), flush: true);
  }

  /// Closes the storage and physically deletes the config file from
  /// disk if it exists. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final file = _file;
    if (await file.exists()) {
      await file.delete();
    }
  }
}
