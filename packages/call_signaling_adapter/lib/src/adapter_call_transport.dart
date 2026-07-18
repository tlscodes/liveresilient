/// [CallTransport] implementation over a [SignalingGateway].
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:signaling/signaling.dart';

import 'signaling_gateway.dart';

/// Bridges `call_core`'s [CallTransport] onto a [SignalingGateway]'s
/// connection-state stream.
///
/// `call_core` only cares whether the signaling channel is usable, so the
/// five-state [SignalingConnectionState] collapses to the four-state
/// [TransportStatus]:
/// - `connecting` / `reconnecting` -> [TransportStatus.connecting] —
///   `signaling`'s own reconnect loop drives the retries; `call_core`
///   should not treat a reconnect attempt as a hard disconnect.
/// - `connected` -> [TransportStatus.connected].
/// - `disconnected` / `closed` -> [TransportStatus.disconnected] — both
///   mean the channel is not usable right now.
///
/// [connect] re-attaches this instance's state listener (dropped by a
/// previous [disconnect]) and calls through to the gateway, so a recovery
/// cycle (`disconnect()` then `connect()` on the same instance) keeps
/// observing gateway state changes. [disconnect] is a no-op with respect
/// to the (shared, caller-owned) gateway — it only detaches this
/// instance's listener. [dispose] additionally closes [events].
final class AdapterCallTransport implements CallTransport {
  AdapterCallTransport(this._gateway) {
    _attach();
  }

  final SignalingGateway _gateway;
  final _eventsController = StreamController<TransportEvent>.broadcast();
  StreamSubscription<TransportStatus>? _stateSubscription;
  bool _disposed = false;

  @override
  Stream<TransportEvent> get events => _eventsController.stream;

  @override
  Future<void> connect() {
    if (_disposed) {
      throw StateError(
        'AdapterCallTransport.connect() called after dispose().',
      );
    }
    _attach();
    return _gateway.connect();
  }

  @override
  Future<void> disconnect() async {
    final subscription = _stateSubscription;
    _stateSubscription = null;
    await subscription?.cancel();
  }

  /// Releases this instance's listener and closes [events]. Idempotent —
  /// calling [dispose] more than once is safe. A later [connect] throws
  /// [StateError]. The gateway itself is caller-owned and stays untouched.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _eventsController.close();
  }

  void _attach() {
    if (_stateSubscription != null || _eventsController.isClosed) {
      return;
    }
    // distinct() after the mapping collapses rapid gateway flapping
    // (ping-ponging through states that map to the same TransportStatus)
    // so the core call state machine never sees redundant duplicates.
    _stateSubscription = _gateway.connectionState
        .map(_mapStatus)
        .distinct()
        .listen((status) {
          if (_eventsController.isClosed) return;
          _eventsController.add(TransportEvent(status));
        });
  }

  static TransportStatus _mapStatus(SignalingConnectionState state) {
    switch (state) {
      case SignalingConnectionState.connecting:
      case SignalingConnectionState.reconnecting:
        return TransportStatus.connecting;
      case SignalingConnectionState.connected:
        return TransportStatus.connected;
      case SignalingConnectionState.disconnected:
      case SignalingConnectionState.closed:
        return TransportStatus.disconnected;
    }
  }
}
