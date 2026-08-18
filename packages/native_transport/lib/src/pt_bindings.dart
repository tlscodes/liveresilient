/// Raw dart:ffi declarations for the pluggable-transport C ABI.
///
/// This file is the literal transcription of the twelve exported symbols in
/// `transport_ffi.h` and nothing else — no policy, no safety, no allocation.
/// The safe wrapper lives in `pt_session.dart`; keeping the two apart means a
/// mistake in the safe layer cannot silently change what the ABI is believed
/// to be.
///
/// The header's own memory contract is the authority for every rule the safe
/// layer enforces; the relevant ones are repeated at each binding below.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'pt_library_locator.dart';

// PtStatus is platform-independent and lives in pt_common.dart so the web
// branch can share it; re-exported here so existing imports keep working.
export 'pt_common.dart' show PtStatus;

/// Opaque native session handle. Never dereferenced on the Dart side.
final class PtSessionHandle extends Opaque {}

// ignore: camel_case_types
typedef _pt_global_init_native = Int32 Function();
typedef _PtGlobalInitDart = int Function();

// ignore: camel_case_types
typedef _pt_global_shutdown_native = Void Function();
typedef _PtGlobalShutdownDart = void Function();

// ignore: camel_case_types
typedef _pt_open_ex_native =
    Pointer<PtSessionHandle> Function(
      Pointer<Utf8> strategy,
      Pointer<Utf8> config,
      Pointer<Int32> status,
    );
typedef _PtOpenExDart =
    Pointer<PtSessionHandle> Function(
      Pointer<Utf8> strategy,
      Pointer<Utf8> config,
      Pointer<Int32> status,
    );

// ignore: camel_case_types
typedef _pt_last_error_native =
    Pointer<Utf8> Function(Pointer<PtSessionHandle> s);
typedef _PtLastErrorDart = Pointer<Utf8> Function(Pointer<PtSessionHandle> s);

// ignore: camel_case_types
typedef _pt_connect_native =
    Int32 Function(
      Pointer<PtSessionHandle> s,
      Pointer<Utf8> endpoint,
      Uint16 port,
    );
typedef _PtConnectDart =
    int Function(Pointer<PtSessionHandle> s, Pointer<Utf8> endpoint, int port);

// ignore: camel_case_types
typedef _pt_send_native =
    IntPtr Function(
      Pointer<PtSessionHandle> s,
      Pointer<Uint8> buffer,
      Size len,
    );
typedef _PtSendDart =
    int Function(Pointer<PtSessionHandle> s, Pointer<Uint8> buffer, int len);

// ignore: camel_case_types
typedef _pt_recv_native =
    IntPtr Function(
      Pointer<PtSessionHandle> s,
      Pointer<Uint8> buffer,
      Size cap,
    );
typedef _PtRecvDart =
    int Function(Pointer<PtSessionHandle> s, Pointer<Uint8> buffer, int cap);

// ignore: camel_case_types
typedef _pt_close_native = Int32 Function(Pointer<PtSessionHandle> s);
typedef _PtCloseDart = int Function(Pointer<PtSessionHandle> s);

// ignore: camel_case_types
typedef _pt_free_native = Void Function(Pointer<PtSessionHandle> s);
typedef _PtFreeDart = void Function(Pointer<PtSessionHandle> s);

// ignore: camel_case_types
typedef _pt_strerror_native = Pointer<Utf8> Function(Int32 status);
typedef _PtStrerrorDart = Pointer<Utf8> Function(int status);

// ignore: camel_case_types
typedef _pt_version_native = Pointer<Utf8> Function();
typedef _PtVersionDart = Pointer<Utf8> Function();

/// Resolved entry points of one loaded copy of the shared library.
///
/// Construction performs every `lookupFunction` eagerly, so a library that is
/// missing a symbol fails HERE with the symbol's name rather than at the first
/// call site — an ABI mismatch is a load-time error, not a runtime surprise.
class PtBindings {
  PtBindings(this.library)
    : globalInit = library
          .lookupFunction<_pt_global_init_native, _PtGlobalInitDart>(
            'pt_global_init',
          ),
      globalShutdown = library
          .lookupFunction<_pt_global_shutdown_native, _PtGlobalShutdownDart>(
            'pt_global_shutdown',
          ),
      openEx = library.lookupFunction<_pt_open_ex_native, _PtOpenExDart>(
        'pt_open_ex',
      ),
      lastError = library
          .lookupFunction<_pt_last_error_native, _PtLastErrorDart>(
            'pt_last_error',
          ),
      connect = library.lookupFunction<_pt_connect_native, _PtConnectDart>(
        'pt_connect',
      ),
      send = library.lookupFunction<_pt_send_native, _PtSendDart>('pt_send'),
      recv = library.lookupFunction<_pt_recv_native, _PtRecvDart>('pt_recv'),
      close = library.lookupFunction<_pt_close_native, _PtCloseDart>(
        'pt_close',
      ),
      free = library.lookupFunction<_pt_free_native, _PtFreeDart>('pt_free'),
      strerror = library.lookupFunction<_pt_strerror_native, _PtStrerrorDart>(
        'pt_strerror',
      ),
      version = library.lookupFunction<_pt_version_native, _PtVersionDart>(
        'pt_version',
      );

  /// Opens the library at [path]. The path is always explicit: there is no
  /// fallback to whatever the loader happens to find, because a silently
  /// substituted library is indistinguishable from the intended one until it
  /// misbehaves.
  factory PtBindings.open(String path) => PtBindings(DynamicLibrary.open(path));

  /// Opens the library a shipped Apple build embeds as `PtTransport.framework`.
  ///
  /// This is the release path: no absolute host path exists on a user's
  /// device, and iOS does not accept a loose dylib in the bundle. It still
  /// resolves ONE named artifact — the framework — so the "no silent
  /// substitution" rule above continues to hold. On any other platform, or
  /// when the framework was not embedded, it throws rather than degrading.
  factory PtBindings.openEmbedded() => PtBindings(openPtLibrary());

  /// The loaded library. Retained so the handle outlives the resolved function
  /// pointers above — releasing it while they are in use would invalidate them.
  final DynamicLibrary library;

  final _PtGlobalInitDart globalInit;
  final _PtGlobalShutdownDart globalShutdown;
  final _PtOpenExDart openEx;
  final _PtLastErrorDart lastError;
  final _PtConnectDart connect;
  final _PtSendDart send;
  final _PtRecvDart recv;
  final _PtCloseDart close;
  final _PtFreeDart free;
  final _PtStrerrorDart strerror;
  final _PtVersionDart version;

  /// The library's ABI version string, e.g. "1.1". Static storage on the
  /// native side, so the returned Dart string is a copy and outlives anything.
  String get abiVersion => version().toDartString();

  /// Human-readable name for a status code. Static storage natively.
  String describeStatus(int status) => strerror(status).toDartString();
}
