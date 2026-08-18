/// The Dart side of the pinned backend's shim: a probe that answers at run
/// time, never a compile-time flag.
///
/// The three questions this can answer are exactly the three the shim exports:
/// is the backend in this process, what revision was it built from, and what
/// bytes does it compose for its first record. Everything else about the
/// backend stays behind the shim.
///
/// WHY LOOKUP FAILURE IS A RESULT, NOT AN EXCEPTION
/// On the host, in unit tests, and on a simulator, the symbols are simply not
/// in the process, and that is a legitimate answer rather than a fault. So the
/// constructor never throws: it reports [ShimProbeState.symbolsAbsent], which
/// a caller can distinguish from a linked build whose backend answered no.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'generated/shim_bindings.dart';

/// What the process itself can tell us, before the backend is asked anything.
enum ShimProbeState {
  /// The shim's symbols are not in this process at all — a host build, a unit
  /// test, or a build made where the archives were absent.
  symbolsAbsent,

  /// The symbols are here and the shim reports the backend is NOT linked; this
  /// is the stub branch of pt_shim.c answering honestly.
  presentBackendUnlinked,

  /// The symbols are here and the shim reports the backend is linked.
  presentBackendLinked,
}

/// What a peer did with a configuration this process offered it.
///
/// [applied] and [ignored] are both "the exchange finished", and keeping them
/// apart is the only reason this enum exists: a caller that treats finishing as
/// success learns nothing about the capability under test. [rejected] is a
/// failure that still proves the peer read the configuration, which is a
/// different fact again from never having been understood.
enum EchProbeOutcome {
  applied,
  ignored,
  rejected,
  timedOut,
  unreachable,
  badArgument,
  internalFailure,
  noBackendInThisProcess,
}

/// A live probe of this process. Construct once and ask.
class ShimProbe {
  ShimProbe._(this._bindings, this.state);

  final ShimBindings? _bindings;

  /// What the process reports about itself.
  final ShimProbeState state;

  /// Looks the shim up in the running process image. The pod links the shim
  /// into a framework that is loaded with the app, so there is no library file
  /// to name and nothing to fail to find on disk.
  factory ShimProbe.ofThisProcess() {
    final ShimBindings bindings;
    try {
      bindings = ShimBindings(ffi.DynamicLibrary.process());
      // Touching one symbol here is what turns a missing-symbol failure into a
      // state, instead of leaving it to explode at the first real question.
      final linked = bindings.pt_shim_backend_linked();
      return ShimProbe._(
        bindings,
        linked == 1
            ? ShimProbeState.presentBackendLinked
            : ShimProbeState.presentBackendUnlinked,
      );
    } on ArgumentError {
      return ShimProbe._(null, ShimProbeState.symbolsAbsent);
    }
  }

  /// True only when the symbols are present AND the backend answered yes.
  bool get backendLinked => state == ShimProbeState.presentBackendLinked;

  /// The revision the backend was built from, or null when there is none to
  /// report. Uses the shim's two-call length discovery, so a longer revision
  /// string than expected is read in full rather than truncated.
  String? buildPin() {
    final bindings = _bindings;
    if (bindings == null) return null;
    final needed = bindings.pt_shim_build_pin(ffi.nullptr, 0);
    if (needed < 0) return null;
    final buffer = pkg_ffi.calloc<ffi.Char>(needed + 1);
    try {
      final written = bindings.pt_shim_build_pin(buffer, needed + 1);
      if (written < 0) return null;
      return buffer.cast<pkg_ffi.Utf8>().toDartString();
    } finally {
      pkg_ffi.calloc.free(buffer);
    }
  }

  /// The bytes the backend composes for its first record, or null when this
  /// process has no backend to ask.
  ///
  /// Two calls: the first learns the true length, the second fills a buffer of
  /// that size. Nothing is written when the buffer is too small, so a short
  /// answer can never be mistaken for a whole one.
  Uint8List? firstRecord() {
    final bindings = _bindings;
    if (bindings == null) return null;
    final needed = bindings.pt_shim_first_record(ffi.nullptr, 0);
    if (needed <= 0) return null;
    final buffer = pkg_ffi.calloc<ffi.Uint8>(needed);
    try {
      final written = bindings.pt_shim_first_record(buffer, needed);
      if (written <= 0 || written > needed) return null;
      // Copied out of native memory before the allocation is released.
      return Uint8List.fromList(buffer.asTypedList(written));
    } finally {
      pkg_ffi.calloc.free(buffer);
    }
  }

  /// Asks a cooperating peer at [host]:[port] to honour [configList] while
  /// this side asks for [innerName], and reports what the peer did with it.
  ///
  /// The wait is bounded and has no "forever": a caller that wants to keep
  /// trying writes that loop where a reader can see it.
  EchProbeOutcome echProbe({
    required String host,
    required int port,
    required Uint8List configList,
    required String innerName,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final bindings = _bindings;
    if (bindings == null) return EchProbeOutcome.noBackendInThisProcess;

    final hostPtr = host.toNativeUtf8();
    final namePtr = innerName.toNativeUtf8();
    final configPtr = pkg_ffi.calloc<ffi.Uint8>(configList.length);
    try {
      configPtr.asTypedList(configList.length).setAll(0, configList);
      final code = bindings.pt_shim_ech_probe(
        hostPtr.cast<ffi.Char>(),
        port,
        configPtr,
        configList.length,
        namePtr.cast<ffi.Char>(),
        timeout.inMilliseconds,
      );
      switch (code) {
        case PT_SHIM_ECH_APPLIED:
          return EchProbeOutcome.applied;
        case PT_SHIM_ECH_IGNORED:
          return EchProbeOutcome.ignored;
        case PT_SHIM_ERR_ECH_REJECTED:
          return EchProbeOutcome.rejected;
        case PT_SHIM_ERR_TIMEOUT:
          return EchProbeOutcome.timedOut;
        case PT_SHIM_ERR_UNREACHABLE:
          return EchProbeOutcome.unreachable;
        case PT_SHIM_ERR_ARG:
          return EchProbeOutcome.badArgument;
        case PT_SHIM_ERR_UNLINKED:
          return EchProbeOutcome.noBackendInThisProcess;
        default:
          return EchProbeOutcome.internalFailure;
      }
    } finally {
      pkg_ffi.calloc.free(configPtr);
      pkg_ffi.calloc.free(namePtr);
      pkg_ffi.calloc.free(hostPtr);
    }
  }
}
