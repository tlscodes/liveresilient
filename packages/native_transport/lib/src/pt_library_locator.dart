/// Resolves the native transport library without an absolute host path.
///
/// WHY THIS EXISTS. `PtBindings.open(path)` takes a filesystem path, which is
/// right for a development host and wrong for a shipped app: iOS rejects a
/// loose `.dylib` inside a bundle, and an absolute path from the build machine
/// does not exist on a user's device. A shipped Apple build embeds
/// `PtTransport.xcframework` (built by `engine/pt/tools/make_xcframework.sh`),
/// whose install name is `@rpath/PtTransport.framework/PtTransport`, so the
/// dynamic loader finds it relative to the app bundle.
///
/// The explicit-path form is kept, not replaced: tests and desktop dev hosts
/// load a freshly built dylib straight out of the engine tree.
library;

import 'dart:ffi';
import 'dart:io';

/// The framework name embedded in Apple app bundles.
const String ptFrameworkName = 'PtTransport';

/// Opens the native library.
///
/// [path] wins when given — that is the development and test path. Otherwise
/// the embedded framework is resolved through the app bundle's rpath, and if
/// the symbols were linked statically into the host process, that is used
/// instead. Every failure is loud: a silent fallback to a stub would let a
/// build ship believing it has a native transport when it does not.
DynamicLibrary openPtLibrary({String? path}) {
  if (path != null) return DynamicLibrary.open(path);

  if (Platform.isIOS || Platform.isMacOS) {
    final candidates = <String>[
      '$ptFrameworkName.framework/$ptFrameworkName',
      '@rpath/$ptFrameworkName.framework/$ptFrameworkName',
    ];
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } on ArgumentError {
        continue;
      }
    }
    // Statically linked into the runner: the symbols are already in-process.
    try {
      final process = DynamicLibrary.process();
      process.lookup<NativeFunction<Void Function()>>('pt_transport_version');
      return process;
    } on ArgumentError {
      // fall through to the throw below
    }
    throw StateError(
      'PtTransport was not found. An Apple release build must embed '
      '$ptFrameworkName.xcframework (Embed & Sign in the Runner target); a '
      'development host must pass an explicit libraryPath.',
    );
  }

  if (Platform.isAndroid) {
    // Packaged under jniLibs/<abi>/ and unpacked into the app's own native
    // library directory, so the system linker resolves it by soname alone —
    // there is no path to give, and giving one would be wrong on a device.
    return DynamicLibrary.open('libpt_transport.so');
  }

  throw UnsupportedError(
    'No embedded native transport exists for ${Platform.operatingSystem}. '
    'Pass an explicit libraryPath, or build the library for this platform '
    'first — see PLATFORM-RELEASE.md.',
  );
}
