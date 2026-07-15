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
/// [connect] simply calls through to the gateway. [disconnect] is a no-op
/// with respect to the (shared, caller-owned) gateway — it only detaches
/// this instance's listener.
class AdapterCallTransport implements CallTransport {
  AdapterCallTransport(this._gateway) {
    _stateSubscription = _gateway.connectionState.listen((state) {
      if (_eventsController.isClosed) return;
      _eventsController.add(TransportEvent(_mapStatus(state)));
    });
  }

  final SignalingGateway _gateway;
  final _eventsController = StreamController<TransportEvent>.broadcast();
  late final StreamSubscription<SignalingConnectionState> _stateSubscription;

  @override
  Stream<TransportEvent> get events => _eventsController.stream;

  @override
  Future<void> connect() => _gateway.connect();

  @override
  Future<void> disconnect() async {
    await _stateSubscription.cancel();
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
