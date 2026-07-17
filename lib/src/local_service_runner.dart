import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Starts and supervises a single local child process.
///
/// The process is launched with [Process.start]; its stdout/stderr are
/// consumed line-by-line for ordinary debug logging only. [shutdown] stops
/// the process safely by sending the OS-standard termination signal
/// (SIGTERM) and waiting for it to exit.
class LocalServiceRunner {
  LocalServiceRunner(this.executablePath, {this.arguments = const <String>[]});

  /// Path of the executable to run.
  final String executablePath;

  /// Optional command-line arguments passed to the process.
  final List<String> arguments;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _active = false;

  /// Whether the child process is currently running.
  bool get isActive => _active;

  /// Launches the child process. No-op if it is already active.
  Future<void> start() async {
    if (_active) {
      return;
    }

    final process = await Process.start(executablePath, arguments);
    _process = process;
    _active = true;

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stdout.writeln('[LocalServiceRunner][out] $line');
        });

    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderr.writeln('[LocalServiceRunner][err] $line');
        });

    // Reflect spontaneous exits (crash or normal completion) in isActive.
    unawaited(
      process.exitCode.then((_) {
        _active = false;
      }),
    );
  }

  /// Stops the child process safely with the standard termination signal
  /// and waits until it has fully exited before releasing resources.
  Future<void> shutdown() async {
    final process = _process;
    if (process == null) {
      return;
    }

    if (_active) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
    _active = false;
  }
}
