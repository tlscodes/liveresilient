/// Minimal WebSocket signaling relay.
///
/// Pairs at most two sockets per `callId` and forwards frames between them
/// verbatim. The server never parses or trusts envelope payloads beyond the
/// single `callId` field needed for routing: it does not decrypt, does not
/// validate signaling semantics, and does not log frame contents. This
/// mirrors the "dumb pipe" role the v2 blueprint assigns to signaling
/// infrastructure — all trust decisions live in the endpoints.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Upper bound for a single relayed frame, matching
/// `signal_envelope.maxEnvelopeBytes` in package:signaling. Kept as a literal
/// here (not a dependency) so this server stays a standalone, dependency-free
/// relay that can be deployed independent of client-side protocol code.
const int maxRelayFrameBytes = 64 * 1024;

/// Max buffered frames held for a peer that has not joined its room yet.
const int maxBufferedFramesPerRoom = 64;

/// WebSocket close code used to reject a third participant on a `callId`
/// that already has two paired sockets.
const int roomFullCloseCode = 4409;

/// WebSocket close code used to notify the surviving peer that its room
/// partner disconnected.
const int peerDisconnectedCloseCode = 1000;

/// Redaction-safe logging hook. Receives only structural event names and
/// non-sensitive metadata (callId, byte counts, error types) — callers must
/// never pass frame payloads or envelope contents through [error].
typedef SignalingLogSink =
    void Function(String event, {String? callId, Object? error});

void _noopLogSink(String event, {String? callId, Object? error}) {}

/// A two-party relay room keyed by `callId`.
class _Room {
  _Room(this.callId);

  final String callId;
  final List<WebSocket> sockets = <WebSocket>[];
  final List<Object> _pending = <Object>[];

  WebSocket? _peerOf(WebSocket sender) {
    for (final socket in sockets) {
      if (!identical(socket, sender)) return socket;
    }
    return null;
  }

  /// Relays [raw] to the other peer if present, otherwise buffers it
  /// (dropping the oldest buffered frame once [maxBufferedFramesPerRoom] is
  /// exceeded).
  void relayOrBuffer(WebSocket sender, Object raw) {
    final peer = _peerOf(sender);
    if (peer != null) {
      peer.add(raw);
      return;
    }
    _pending.add(raw);
    while (_pending.length > maxBufferedFramesPerRoom) {
      _pending.removeAt(0);
    }
  }

  /// Flushes buffered frames (from the first peer) to a newly-joined
  /// [socket], in original order, then clears the buffer.
  void flushPendingTo(WebSocket socket) {
    for (final raw in _pending) {
      socket.add(raw);
    }
    _pending.clear();
  }
}

/// A minimal, standards-based `wss://` relay for opaque signaling frames.
///
/// The server does not understand the signaling protocol carried inside
/// frames; it only reads the top-level `callId` string to decide where a
/// frame goes. Two sockets sharing a `callId` are paired into a room and
/// every frame either one sends is forwarded verbatim to the other.
class SignalingRelayServer {
  SignalingRelayServer._(this._httpServer, this._logSink) {
    _subscription = _httpServer.listen(
      _handleRequest,
      onError: (Object error) => _logSink('http_server_error', error: error),
    );
  }

  final HttpServer _httpServer;
  final SignalingLogSink _logSink;
  late final StreamSubscription<HttpRequest> _subscription;
  final Map<String, _Room> _rooms = <String, _Room>{};

  /// Binds a TLS WebSocket server on [address]:[port] (ephemeral if `0`)
  /// using [security] for the TLS handshake.
  static Future<SignalingRelayServer> bind({
    required SecurityContext security,
    InternetAddress? address,
    int port = 0,
    SignalingLogSink logSink = _noopLogSink,
  }) async {
    final httpServer = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      security,
    );
    return SignalingRelayServer._(httpServer, logSink);
  }

  /// The bound TCP port (useful when constructed with `port: 0`).
  int get port => _httpServer.port;

  /// Number of rooms currently tracked (0, 1, or 2 sockets joined).
  int get activeRooms => _rooms.length;

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    late final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (error) {
      _logSink('upgrade_failed', error: error);
      return;
    }
    unawaited(_handleSocket(socket));
  }

  Future<void> _handleSocket(WebSocket socket) async {
    _Room? room;
    try {
      await for (final Object raw in socket) {
        final bytes = _frameBytes(raw);
        if (bytes == null || bytes.length > maxRelayFrameBytes) {
          _logSink('frame_dropped_oversized', callId: room?.callId);
          continue;
        }

        final Map<String, Object?>? decoded = _decodeEnvelope(bytes);
        if (decoded == null) {
          _logSink('frame_dropped_malformed', callId: room?.callId);
          continue;
        }

        final callIdField = decoded['callId'];
        if (callIdField is! String ||
            callIdField.isEmpty ||
            callIdField.length > 128) {
          _logSink('frame_dropped_bad_call_id', callId: room?.callId);
          continue;
        }

        room ??= _joinRoom(callIdField, socket);
        if (room == null) {
          _logSink('room_rejected_full', callId: callIdField);
          await _safeClose(socket, roomFullCloseCode, 'room full');
          return;
        }

        room.relayOrBuffer(socket, raw);
      }
    } catch (error) {
      _logSink('socket_stream_error', callId: room?.callId, error: error);
    } finally {
      if (room != null) {
        _closeRoom(room, socket);
      }
    }
  }

  /// Registers [socket] into the room for [callId], creating the room if
  /// needed. Returns `null` if the room already has two other sockets
  /// (caller must reject the connection).
  _Room? _joinRoom(String callId, WebSocket socket) {
    final room = _rooms.putIfAbsent(callId, () => _Room(callId));
    if (room.sockets.any((s) => identical(s, socket))) {
      return room;
    }
    if (room.sockets.length >= 2) {
      return null;
    }
    room.sockets.add(socket);
    if (room.sockets.length == 2) {
      room.flushPendingTo(socket);
    }
    return room;
  }

  void _closeRoom(_Room room, WebSocket disconnected) {
    if (!identical(_rooms[room.callId], room)) {
      // Already torn down by the peer's disconnect handler.
      return;
    }
    _rooms.remove(room.callId);
    _logSink('room_closed', callId: room.callId);
    for (final socket in room.sockets) {
      if (!identical(socket, disconnected)) {
        unawaited(
          _safeClose(socket, peerDisconnectedCloseCode, 'peer disconnected'),
        );
      }
    }
  }

  Future<void> _safeClose(WebSocket socket, int code, String reason) async {
    try {
      await socket.close(code, reason);
    } catch (error) {
      _logSink('socket_close_failed', error: error);
    }
  }

  static List<int>? _frameBytes(Object raw) {
    if (raw is List<int>) return raw;
    if (raw is String) return utf8.encode(raw);
    return null;
  }

  static Map<String, Object?>? _decodeEnvelope(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) return decoded;
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Stops accepting new connections and closes every tracked room's
  /// sockets, then shuts down the underlying HTTP server.
  Future<void> close() async {
    await _subscription.cancel();
    for (final room in _rooms.values.toList()) {
      for (final socket in room.sockets.toList()) {
        await _safeClose(socket, peerDisconnectedCloseCode, 'server closing');
      }
    }
    _rooms.clear();
    await _httpServer.close(force: true);
  }
}
