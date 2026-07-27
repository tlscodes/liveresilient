import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../transport_channel.dart';

/// Fallback transport path: a plain, honestly-labelled WebSocket
/// (`ws://`/`wss://`) connection to our own relay infrastructure. Frames are
/// sent as binary WS messages. Traverses most corporate proxies/NATs that
/// block raw UDP because it rides ordinary HTTP(S) upgrade semantics.
///
/// The connection is established lazily and reconnects lazily: a dropped
/// socket is not proactively retried, but the next [send] call notices the
/// drop and reconnects before delivering.
class WebSocketRelayLane implements TransportChannel {
  WebSocketRelayLane({
    required Uri relayUri,
    Duration connectTimeout = const Duration(seconds: 3),
  }) : _relayUri = relayUri,
       _connectTimeout = connectTimeout,
       health = ChannelHealth(reliabilityPrior: 0.75, bandwidth: 0.7);

  final Uri _relayUri;
  final Duration _connectTimeout;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  bool _dropped = false;

  @override
  final ChannelHealth health;

  @override
  String get name => 'websocket-relay';

  Future<WebSocket> _ensureConnected() async {
    final existing = _socket;
    if (existing != null && !_dropped) return existing;
    await _closeSocket();

    final socket = await WebSocket.connect(
      _relayUri.toString(),
    ).timeout(_connectTimeout);
    _dropped = false;
    _sub = socket.listen(
      (_) {},
      onDone: () => _dropped = true,
      onError: (_) => _dropped = true,
      cancelOnError: true,
    );
    _socket = socket;
    return socket;
  }

  Future<void> _closeSocket() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {
      // Already closed / broken pipe: nothing further to do.
    }
    _socket = null;
  }

  @override
  Future<bool> probe() async {
    // Always force a fresh connection attempt rather than trusting a
    // cached socket: the server side can close without the client's
    // onDone/onError callback having fired yet by the time probe() runs,
    // which would otherwise report a dead relay as reachable.
    await _closeSocket();
    _dropped = true;
    try {
      await _ensureConnected();
      health.observe(const SendResult(SendStatus.ok));
      return true;
    } catch (error) {
      _dropped = true;
      health.observe(SendResult(SendStatus.unavailable, error: error));
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    final started = DateTime.now();
    try {
      final socket = await _ensureConnected();
      socket.add(Uint8List.fromList(payload));
      final rtt = DateTime.now().difference(started).inMilliseconds;
      final result = SendResult(SendStatus.ok, rttMs: rtt);
      health.observe(result);
      return result;
    } catch (error) {
      _dropped = true;
      final result = SendResult(SendStatus.unavailable, error: error);
      health.observe(result);
      return result;
    }
  }

  @override
  Future<void> dispose() async {
    await _closeSocket();
  }
}
