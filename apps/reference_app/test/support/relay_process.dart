/// Shared spawn helper for probe tests that need the REAL datagram relay.
///
/// Why this exists (measured 2026-08-19, suite-logs/20260819T005913Z):
/// `dart run bin/datagram_relay.dart` JIT-compiles the whole server package
/// on every spawn; under a full-tree suite run that compile exceeded the 60s
/// readiness window and the failure said only "stderr: " — the compiler
/// emits nothing while it works, so the evidence was empty. This helper
/// raises the unit instead of the constant:
///   - the relay is AOT-compiled ONCE into a content-keyed cache
///     (server/.dart_tool/probe_relay_cache/), so per-test startup is
///     process-exec, not a package compile;
///   - the compile has its own labeled budget and reports its full output
///     on failure;
///   - a readiness failure reports process exit state, stdout AND stderr —
///     never an empty string.
/// The readiness-line contract ("datagram relay listening on host:port",
/// also grepped by tools/t2/h2_run.sh) is unchanged — same bin, same line.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RelayProcess {
  RelayProcess._(this.process, this.port);

  final Process process;
  final int port;

  static const _compileBudget = Duration(seconds: 240);
  static const _readyBudget = Duration(seconds: 30);

  /// cwd for these suites is apps/reference_app.
  static String get _serverDir =>
      '${Directory.current.parent.parent.path}/server/signaling_server';

  /// FNV-1a over the relay's sources — a cache key, not a security hash.
  /// Any edit to bin/ or lib/ re-keys the cache and forces a fresh compile.
  static String _sourceKey(String serverDir) {
    final files = <File>[
      File('$serverDir/bin/datagram_relay.dart'),
      ...Directory('$serverDir/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    ]..sort((a, b) => a.path.compareTo(b.path));
    var h = 0xcbf29ce484222325;
    for (final f in files) {
      for (final b in f.readAsBytesSync()) {
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
    }
    return h.toRadixString(16);
  }

  static Future<String> _ensureCompiled() async {
    final serverDir = _serverDir;
    final exe = File(
        '$serverDir/.dart_tool/probe_relay_cache/relay-${_sourceKey(serverDir)}.exe');
    if (exe.existsSync()) return exe.path;
    exe.parent.createSync(recursive: true);
    // Compile to a temp path, then atomic rename: parallel test isolates may
    // race here; both compiles succeed and the last rename wins.
    final tmp = '${exe.path}.tmp-$pid';
    final proc = await Process.start(
      'dart',
      ['compile', 'exe', 'bin/datagram_relay.dart', '-o', tmp],
      workingDirectory: serverDir,
    );
    final out = StringBuffer(), err = StringBuffer();
    proc.stdout.transform(const SystemEncoding().decoder).listen(out.write);
    proc.stderr.transform(const SystemEncoding().decoder).listen(err.write);
    final code = await proc.exitCode.timeout(_compileBudget, onTimeout: () {
      proc.kill();
      throw StateError(
          'relay AOT compile exceeded ${_compileBudget.inSeconds}s\n'
          'stdout: $out\nstderr: $err');
    });
    if (code != 0) {
      throw StateError('relay AOT compile failed (exit $code)\n'
          'stdout: $out\nstderr: $err');
    }
    File(tmp).renameSync(exe.path);
    return exe.path;
  }

  /// Compiles (or reuses) the relay executable, spawns it on an ephemeral
  /// port and returns once the readiness line has named the port.
  static Future<RelayProcess> start() async {
    final exePath = await _ensureCompiled();
    final proc = await Process.start(exePath, ['--port', '0']);
    final out = StringBuffer(), err = StringBuffer();
    final ready = Completer<int>();
    proc.stderr.transform(const SystemEncoding().decoder).listen(err.write);
    proc.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((l) {
      out.writeln(l);
      if (!ready.isCompleted && l.contains('datagram relay listening on')) {
        ready.complete(int.parse(l.split(':').last.trim()));
      }
    });
    unawaited(proc.exitCode.then((c) {
      if (!ready.isCompleted) {
        ready.completeError(StateError(
            'relay exited before readiness (exit $c)\n'
            'stdout: $out\nstderr: $err'));
      }
    }));
    final port = await ready.future.timeout(_readyBudget, onTimeout: () {
      proc.kill();
      throw StateError(
          'relay (AOT exe) not ready in ${_readyBudget.inSeconds}s\n'
          'stdout: $out\nstderr: $err');
    });
    return RelayProcess._(proc, port);
  }

  void kill() => process.kill();
}
