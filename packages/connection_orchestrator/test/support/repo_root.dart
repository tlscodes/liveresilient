/// Finds the repository root from a test, wherever the test was started.
///
/// Two tests need this and both used to carry their own copy. A path walk is
/// harmless duplication right up to the day one copy learns a new anchor
/// directory and the other does not, so it lives here with two callers.
///
/// The anchor is `tools/t2/replay_corpus`: the recorded corpus is the thing
/// these tests are about, so a root without it is not a root they can use.
import 'dart:io';

Directory? _repoRootFrom(Directory start) {
  var dir = start.absolute;
  while (true) {
    if (Directory('${dir.path}/tools/t2/replay_corpus').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// Robust to running from the package root or the repo root: tries the working
/// directory first, then the test script's own location.
Directory repoRoot() {
  final fromCwd = _repoRootFrom(Directory.current);
  if (fromCwd != null) return fromCwd;
  final scriptDir = File.fromUri(Platform.script).parent;
  final fromScript = _repoRootFrom(scriptDir);
  if (fromScript != null) return fromScript;
  throw StateError(
    'tools/t2/replay_corpus not found above ${Directory.current.path} '
    'or ${scriptDir.path}',
  );
}
