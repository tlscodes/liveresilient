/// Platform-independent pieces of the native-transport API.
///
/// This file must stay free of `dart:ffi`, `dart:io`, and every package that
/// pulls them in: it is compiled on EVERY platform, including the web, where
/// no native lane exists. Status codes and the exception type carry no native
/// state, so they live here and are shared by both conditional branches.
library;

/// Status codes, mirroring `pt_status_t` (transport_ffi.h:34-42).
abstract final class PtStatus {
  static const int ok = 0;
  static const int invalid = -1;
  static const int noStrategy = -2;
  static const int init = -3;
  static const int connect = -4;
  static const int io = -5;
  static const int nomem = -6;
}

/// Raised for any non-zero status coming back across the boundary. [message]
/// is a Dart copy taken while the native buffer was still alive.
class PtException implements Exception {
  PtException(this.status, this.message, this.statusName);

  /// The negative `pt_status_t` value.
  final int status;

  /// The library's own description of the failure, already copied.
  final String message;

  /// The status code's symbolic name, e.g. "unknown strategy".
  final String statusName;

  @override
  String toString() => 'PtException($status $statusName): $message';
}

/// Lane identifier reported by the native lane's `name`.
const String ptNativeLaneName = 'pt-native';
