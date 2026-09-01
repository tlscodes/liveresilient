/// The no-native branch of the conditional export in `native_transport.dart`.
/// Selected at compile time wherever `dart.library.ffi` does not exist —
/// today that means the web compilers (dart2js / dart2wasm).
///
/// Every type here mirrors the public shape of the real branch so that code
/// mentioning these names still compiles for the web, and every constructor
/// throws [UnsupportedError] so that code REACHING them fails loudly instead
/// of pretending a native session exists. Callers choose the honest path by
/// checking [isNativeTransportAvailable] first and degrading to the pure-Dart
/// lanes.
///
/// Deliberate difference from the real branch: this `PtNativeLane` does NOT
/// implement `TransportChannel`, because `package:adaptive_transport` imports
/// `dart:io` and would itself break the web compilation. On a platform with
/// no native lane there is no channel to register anyway.
library;

import 'dart:typed_data';

import 'pt_common.dart';

/// False on this branch: `dart:ffi` does not exist here, so no native
/// transport can ever be loaded. See `pt_ffi.dart` for what `true` means.
const bool isNativeTransportAvailable = false;

Never _unsupported() => throw UnsupportedError(
  'native_transport is not available on this platform: dart:ffi does not '
  'exist here (web). Check isNativeTransportAvailable before using it.',
);

/// Stub for the opaque native handle type. Never instantiable.
final class PtSessionHandle {
  PtSessionHandle._();
}

/// Mirrors the real branch's outcomes so code naming them still compiles here.
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

/// Mirrors the real branch's states so code naming them still compiles here.
/// Only one of them can ever occur on this branch, and it is the honest one:
/// a platform without `dart:ffi` cannot look a symbol up at all.
enum ShimProbeState {
  symbolsAbsent,
  presentBackendUnlinked,
  presentBackendLinked,
}

/// Stub of the shim probe. Constructing one is allowed and answers absent,
/// because "there is no backend here" is a true statement about the web rather
/// than an error — the asking is what would be a mistake, so the accessors
/// return the same nothing the real branch returns when symbols are missing.
class ShimProbe {
  ShimProbe._();

  factory ShimProbe.ofThisProcess() => ShimProbe._();

  ShimProbeState get state => ShimProbeState.symbolsAbsent;

  bool get backendLinked => false;

  String? buildPin() => null;

  Uint8List? firstRecord() => null;

  EchProbeOutcome echProbe({
    required String host,
    required int port,
    required Uint8List configList,
    required String innerName,
    Duration timeout = const Duration(seconds: 10),
  }) => EchProbeOutcome.noBackendInThisProcess;
}

/// Stub of the FFI bindings. Every way of obtaining one throws.
class PtBindings {
  PtBindings(Object library) {
    _unsupported();
  }

  factory PtBindings.open(String path) => _unsupported();

  factory PtBindings.openEmbedded() => _unsupported();

  String get abiVersion => _unsupported();
  String describeStatus(int status) => _unsupported();
}

/// Stub of the safe session wrapper. Every way of obtaining one throws.
class PtSession {
  PtSession._();

  static PtSession open(
    PtBindings bindings, {
    required String strategy,
    String? config,
  }) => _unsupported();

  bool get isDisposed => _unsupported();
  void connect(String endpoint, int port) => _unsupported();
  int send(List<int> bytes) => _unsupported();
  int sendAll(List<int> bytes) => _unsupported();
  Uint8List recv(int capacity) => _unsupported();
  void close() => _unsupported();
  void dispose() => _unsupported();
}

/// Stub of the native lane. Every way of obtaining one throws.
class PtNativeLane {
  PtNativeLane(PtSession session, {Object? health}) {
    _unsupported();
  }

  factory PtNativeLane.open({
    required String libraryPath,
    required String strategy,
    String? config,
    Object? health,
  }) => _unsupported();

  String get name => ptNativeLaneName;
  Future<bool> probe() => _unsupported();
  Uint8List receive({int capacity = 2048}) => _unsupported();
  Future<void> dispose() => _unsupported();
}
