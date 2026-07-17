import 'dart:io';

/// Probes a local service by attempting a short-lived TCP connection.
class LocalConnectionVerifier {
  /// Returns `true` if a TCP connection to [host]:[port] succeeds within
  /// [timeout]; `false` on any error or timeout.
  Future<bool> verifyServiceReadiness(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
