/// Safe ownership wrapper around one native transport session.
///
/// Every rule enforced here is stated in the C header's memory contract; the
/// three that shape this class:
///
///  * A single native session is NOT internally synchronized. Its error buffer
///    and strategy context are written without a lock, so two threads — and a
///    Dart isolate IS a thread — using one handle is a data race. This class
///    therefore records the isolate that created it and refuses any call from
///    another one. The handle is not sendable across isolates by construction:
///    it is never exposed.
///  * `pt_last_error` returns a buffer that lives inside the session and dies
///    with `pt_free`. Every message is copied into a Dart string before any
///    free happens.
///  * `pt_send`/`pt_recv` may transfer FEWER bytes than asked, and a `pt_recv`
///    of 0 means "nothing available right now" — not end of stream and not an
///    error. Only a negative return is a failure.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pt_bindings.dart';
import 'pt_common.dart';

// PtException is platform-independent and lives in pt_common.dart so the web
// branch can share it; re-exported here so existing imports keep working.
export 'pt_common.dart' show PtException;

/// One open native session. Owns exactly one handle and frees it once.
class PtSession {
  PtSession._(this._bindings, this._handle, this._owner);

  /// Opens a session for [strategy] with an optional [config] string.
  ///
  /// On failure the native side returns NULL and the reason is only available
  /// from the THREAD-LOCAL error channel (`pt_last_error(NULL)`), because there
  /// is no session to carry it — so that is what is read here.
  static PtSession open(
    PtBindings bindings, {
    required String strategy,
    String? config,
  }) {
    bindings.globalInit();

    final strategyPtr = strategy.toNativeUtf8();
    // A null `config` is legal natively and means "defaults"; passing
    // nullptr is therefore not an error path.
    final configPtr = config == null ? nullptr : config.toNativeUtf8();
    final statusPtr = calloc<Int32>();
    try {
      final handle = bindings.openEx(strategyPtr, configPtr.cast(), statusPtr);
      final status = statusPtr.value;
      if (handle == nullptr) {
        throw PtException(
          status,
          bindings.lastError(nullptr).toDartString(),
          bindings.describeStatus(status),
        );
      }
      return PtSession._(bindings, handle, Isolate.current.hashCode);
    } finally {
      // Freed on every path, including the throw: these three allocations are
      // borrowed by the callee for the duration of the call only.
      calloc.free(strategyPtr);
      if (configPtr != nullptr) calloc.free(configPtr);
      calloc.free(statusPtr);
    }
  }

  final PtBindings _bindings;
  final Pointer<PtSessionHandle> _handle;

  /// Identity of the isolate that opened this session. See the class comment:
  /// the native session has no internal lock, so use from another isolate is a
  /// data race and is refused rather than risked.
  final int _owner;

  bool _disposed = false;

  /// Whether [dispose] has already run. A disposed session throws on use.
  bool get isDisposed => _disposed;

  void _check() {
    if (_disposed) {
      throw StateError('PtSession used after dispose()');
    }
    if (Isolate.current.hashCode != _owner) {
      throw StateError(
        'PtSession used from a different isolate than the one that opened it; '
        'the native session has no internal lock, so this would be a data race',
      );
    }
  }

  /// Copies the session's current error text out of native memory. Must be
  /// called while the session is still alive.
  String _errorText() => _bindings.lastError(_handle).toDartString();

  Never _fail(int status) =>
      throw PtException(status, _errorText(), _bindings.describeStatus(status));

  /// Connects the session to [endpoint]:[port]. Throws [PtException] on
  /// failure; the endpoint string is borrowed for the call only.
  void connect(String endpoint, int port) {
    _check();
    final endpointPtr = endpoint.toNativeUtf8();
    try {
      final rc = _bindings.connect(_handle, endpointPtr, port);
      if (rc != PtStatus.ok) _fail(rc);
    } finally {
      calloc.free(endpointPtr);
    }
  }

  /// Sends [bytes] and returns how many were actually written, which may be
  /// FEWER than `bytes.length` — a partial write is success, not an error.
  /// Callers that need everything written must loop.
  int send(List<int> bytes) {
    _check();
    if (bytes.isEmpty) return 0;
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final n = _bindings.send(_handle, buffer, bytes.length);
      if (n < 0) _fail(n);
      return n;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Sends every byte of [bytes], looping over partial writes. Returns the
  /// total written, which equals `bytes.length` on success.
  int sendAll(List<int> bytes) {
    var sent = 0;
    while (sent < bytes.length) {
      final n = send(bytes.sublist(sent));
      if (n == 0) break; // no progress; the caller decides what to do
      sent += n;
    }
    return sent;
  }

  /// Reads up to [capacity] bytes. An EMPTY result means nothing was available
  /// at this moment — it is NOT end of stream and NOT an error.
  Uint8List recv(int capacity) {
    _check();
    if (capacity <= 0) return Uint8List(0);
    final buffer = calloc<Uint8>(capacity);
    try {
      final n = _bindings.recv(_handle, buffer, capacity);
      if (n < 0) _fail(n);
      // Copy out: the native buffer is freed in the finally below.
      return Uint8List.fromList(buffer.asTypedList(n));
    } finally {
      calloc.free(buffer);
    }
  }

  /// Tears the connection down. The session stays valid for [dispose].
  void close() {
    _check();
    final rc = _bindings.close(_handle);
    if (rc != PtStatus.ok) _fail(rc);
  }

  /// Releases the native handle exactly once. Safe to call repeatedly; the
  /// second and later calls do nothing. After this the session's error buffer
  /// is gone, so nothing may read it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.free(_handle);
  }
}
