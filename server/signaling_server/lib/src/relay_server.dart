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

import 'abuse_controls.dart';

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

/// WebSocket close code sent to a member's PREVIOUS socket when the same
/// identity reconnects and takes its seat (session resumption).
const int supersededCloseCode = 4410;

/// Redaction-safe logging hook. Receives only structural event names and
/// non-sensitive metadata (callId, byte counts, error types) — callers must
/// never pass frame payloads or envelope contents through [error].
typedef SignalingLogSink =
    void Function(String event, {String? callId, Object? error});

void _noopLogSink(String event, {String? callId, Object? error}) {}

/// A two-party relay room keyed by `callId`.
class _Room {
  _Room(this.callId, this.lastActivity);

  final String callId;

  /// Last time a frame was relayed/buffered or a peer joined; drives the
  /// idle-room TTL sweep.
  DateTime lastActivity;

  /// Membership is keyed by the envelope's `senderKeyId` — an IDENTITY —
  /// not by socket. Measured 2026-08-07 (T2 loss60): a client that
  /// abandons a stalled connection under heavy loss leaves a ZOMBIE socket
  /// here (its FIN never delivers, so its stream never ends), and while
  /// membership was socket-keyed the zombie held the seat: every
  /// reconnection by the same peer was rejected `room_rejected_full`, the
  /// relay log showed exactly that four times in one run, and no recovery
  /// architecture on the client side could ever succeed — the door was
  /// locked from the outside. A returning identity now REPLACES its dead
  /// socket (session resumption); "full" means two OTHER identities.
  /// MULTI-SOCKET SEATS (raised 2026-08-09): under heavy loss a single
  /// TCP stream stalls tens of seconds on retransmission. A seat may hold
  /// up to [maxSocketsPerSeat] concurrent sockets; every frame fans out
  /// to ALL of the peer seat's sockets (first arrival wins — the client
  /// adapter already drops duplicates), and a join beyond the cap
  /// supersedes the seat's OLDEST socket, so zombies age out instead of
  /// locking the seat.
  final Map<String, List<WebSocket>> members = <String, List<WebSocket>>{};

  /// The room's replayable recent history: (senderKeyId, frame) pairs,
  /// capped at [maxBufferedFramesPerRoom] (drop-oldest). See
  /// [relayOrBuffer] — a TCP write is not delivery, so every frame is
  /// ring-buffered and re-delivered on every fresh join.
  final List<(String?, Object)> _pending = <(String?, Object)>[];

  static const int maxSocketsPerSeat = 3;

  Iterable<WebSocket> get sockets => members.values.expand((seat) => seat);

  bool isMember(WebSocket socket) =>
      members.values.any((seat) => seat.any((s) => identical(s, socket)));

  List<WebSocket> _peerSocketsOf(WebSocket sender) {
    final result = <WebSocket>[];
    for (final seat in members.values) {
      if (seat.any((s) => identical(s, sender))) continue;
      result.addAll(seat);
    }
    return result;
  }

  String? _seatKeyOf(WebSocket sender) {
    for (final entry in members.entries) {
      if (entry.value.any((s) => identical(s, sender))) {
        return entry.key;
      }
    }
    return null;
  }

  /// Ring-buffers [raw] ALWAYS, and relays it to every socket of the
  /// other seat when one exists. Raised 2026-08-09 (loss60): a TCP write
  /// into a seat is NOT delivery — under heavy loss the peer seat can
  /// hold only zombie sockets (client-abandoned, their FIN never
  /// crossed), and a frame written there was counted relayed and lost
  /// forever, costing the sender a full outbox backoff per frame. The
  /// ring keeps the last [maxBufferedFramesPerRoom] frames; every fresh
  /// join replays the other identity's frames (the client adapter drops
  /// duplicates), so a live socket replacing a zombie immediately hears
  /// everything sent into the dead window.
  void relayOrBuffer(WebSocket sender, Object raw) {
    _pending.add((_seatKeyOf(sender), raw));
    while (_pending.length > maxBufferedFramesPerRoom) {
      _pending.removeAt(0);
    }
    for (final socket in _peerSocketsOf(sender)) {
      socket.add(raw);
    }
  }

  /// Replays the ring to a newly-joined [socket] of [joiningKey], in
  /// original order, skipping that identity's own frames. The ring is
  /// NOT cleared — it is the room's replayable recent history and the
  /// cap bounds it (see [relayOrBuffer]).
  void flushPendingTo(WebSocket socket, String joiningKey) {
    for (final (senderKey, raw) in _pending) {
      if (senderKey == joiningKey) {
        continue;
      }
      socket.add(raw);
    }
  }
}

/// A minimal, standards-based `wss://` relay for opaque signaling frames.
///
/// The server does not understand the signaling protocol carried inside
/// frames; it only reads the top-level `callId` string to decide where a
/// frame goes. Two sockets sharing a `callId` are paired into a room and
/// every frame either one sends is forwarded verbatim to the other.
class SignalingRelayServer {
  SignalingRelayServer._(
    this._httpServer,
    this._logSink,
    this._guard,
    this._now,
  ) {
    _subscription = _httpServer.listen(
      _handleRequest,
      onError: (Object error) => _logSink('http_server_error', error: error),
    );
    _sweepTimer = Timer.periodic(
      _guard.config.sweepInterval,
      (_) => _sweepIdleRooms(),
    );
  }

  final HttpServer _httpServer;
  final SignalingLogSink _logSink;
  final AbuseGuard _guard;
  final Clock _now;
  late final StreamSubscription<HttpRequest> _subscription;
  late final Timer _sweepTimer;
  final Map<String, _Room> _rooms = <String, _Room>{};

  /// Binds a TLS WebSocket server on [address]:[port] (ephemeral if `0`)
  /// using [security] for the TLS handshake.
  ///
  /// [abuseControls] tunes the application-level rate/session/room limits
  /// (validated defaults when omitted); [clock] injects a deterministic time
  /// source for the limiters and the idle-room sweep.
  static Future<SignalingRelayServer> bind({
    required SecurityContext security,
    InternetAddress? address,
    int port = 0,
    SignalingLogSink logSink = _noopLogSink,
    AbuseControlConfig? abuseControls,
    Clock? clock,
  }) async {
    final httpServer = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      security,
    );
    final now = clock ?? DateTime.now;
    return SignalingRelayServer._(
      httpServer,
      logSink,
      AbuseGuard(config: abuseControls, clock: now),
      now,
    );
  }

  /// The bound TCP port (useful when constructed with `port: 0`).
  int get port => _httpServer.port;

  /// Number of rooms currently tracked (0, 1, or 2 sockets joined).
  int get activeRooms => _rooms.length;

  /// Aggregate, identity-free abuse counters (see [AbuseCounters]).
  AbuseCounters get counters => _guard.counters;

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    // Transient source key for in-memory limiting only — never stored in
    // counters, never logged.
    final sourceKey =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    late final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (error) {
      _logSink('upgrade_failed', error: error);
      return;
    }
    unawaited(_handleSocket(socket, sourceKey));
  }

  Future<void> _handleSocket(WebSocket socket, String sourceKey) async {
    _guard.counters.connectionsTotal++;
    final bucket = _guard.newConnectionBucket();
    _Room? room;
    try {
      await for (final Object raw in socket) {
        if (!bucket.tryConsume()) {
          _guard.counters.rateLimitDisconnects++;
          _logSink('rate_limit_close', callId: room?.callId);
          await _safeClose(socket, rateLimitCloseCode, 'message rate limit');
          return;
        }

        final bytes = _frameBytes(raw);
        if (bytes == null || bytes.length > _guard.config.maxFrameBytes) {
          _guard.counters.oversizedFramesDropped++;
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

        if (room == null) {
          // Membership is identity-keyed (see _Room), so the join frame's
          // sender identity is validated exactly like the callId.
          final senderKeyField = decoded['senderKeyId'];
          if (senderKeyField is! String ||
              senderKeyField.isEmpty ||
              senderKeyField.length > 128) {
            _logSink('frame_dropped_bad_sender_key', callId: callIdField);
            continue;
          }
          final admission = _guard.admitRoomJoin(
            sourceKey: sourceKey,
            callId: callIdField,
            roomExists: _rooms.containsKey(callIdField),
            activeRooms: _rooms.length,
          );
          if (!admission.allowed) {
            _logSink('room_rejected_limited', callId: callIdField);
            await _safeClose(socket, admission.closeCode, admission.reason);
            return;
          }
          room = _joinRoom(callIdField, senderKeyField, socket);
          if (room == null) {
            _guard.leaveRoom(sourceKey, callIdField);
            _logSink('room_rejected_full', callId: callIdField);
            await _safeClose(socket, roomFullCloseCode, 'room full');
            return;
          }
        }

        room.relayOrBuffer(socket, raw);
        room.lastActivity = _now();
      }
    } catch (error) {
      _logSink('socket_stream_error', callId: room?.callId, error: error);
    } finally {
      if (room != null) {
        _guard.leaveRoom(sourceKey, room.callId);
        // A SUPERSEDED socket's stream ending must not tear the room down:
        // its seat already belongs to the member's fresh socket, and this
        // late death is exactly the zombie whose seat-holding caused the
        // room_rejected_full lockout.
        //
        // A CURRENT member's death VACATES ITS SEAT — nothing more. The
        // pre-resumption behavior (close the room, force-close the peer
        // with 1000) actively destroyed the HEALTHY side's socket and the
        // room's frame buffer every time one side flapped; measured
        // 2026-08-07 on loss60, that turned every single-sided reconnect
        // into a two-sided from-zero rebuild and no cycle ever finished.
        // The peer keeps its socket and its seat, the buffer survives,
        // and the vacated identity resumes into the SAME room. Empty
        // rooms are removed at once; abandoned one-seat rooms age out via
        // the idle-TTL sweep. Deliberate call ends still propagate at the
        // signaling layer (hangup envelopes), not by socket teardown.
        if (room.isMember(socket)) {
          for (final seat in room.members.values) {
            seat.removeWhere((s) => identical(s, socket));
          }
          room.members.removeWhere((_, seat) => seat.isEmpty);
          room.lastActivity = _now();
          _logSink('room_member_left', callId: room.callId);
          if (room.members.isEmpty && identical(_rooms[room.callId], room)) {
            _rooms.remove(room.callId);
            _logSink('room_closed', callId: room.callId);
          }
        }
      }
    }
  }

  /// Reaps rooms with no traffic for [AbuseControlConfig.idleRoomTtl] and
  /// prunes the guard's transient session-tracking maps (bounded memory).
  void _sweepIdleRooms() {
    _guard.prune();
    final cutoff = _now().subtract(_guard.config.idleRoomTtl);
    for (final room in _rooms.values.toList()) {
      if (room.lastActivity.isAfter(cutoff)) continue;
      _rooms.remove(room.callId);
      _guard.counters.idleRoomsReaped++;
      _logSink('idle_room_reaped', callId: room.callId);
      for (final socket in room.sockets) {
        unawaited(_safeClose(socket, idleTimeoutCloseCode, 'idle timeout'));
      }
    }
  }

  /// Registers [socket] as [senderKey]'s seat in the room for [callId],
  /// creating the room if needed. A returning identity replaces its own
  /// previous socket (session resumption — see the membership note on
  /// [_Room]); the old socket is closed as superseded. Returns `null` only
  /// when the room already seats two OTHER identities.
  _Room? _joinRoom(String callId, String senderKey, WebSocket socket) {
    final room = _rooms.putIfAbsent(callId, () => _Room(callId, _now()));
    final seat = room.members[senderKey];
    if (seat != null) {
      if (seat.any((s) => identical(s, socket))) {
        return room;
      }
      seat.add(socket);
      room.lastActivity = _now();
      WebSocket? superseded;
      if (seat.length > _Room.maxSocketsPerSeat) {
        superseded = seat.removeAt(0);
      }
      _logSink('room_member_replaced', callId: callId);
      if (superseded != null) {
        unawaited(
          _safeClose(
            superseded,
            supersededCloseCode,
            'superseded by reconnect',
          ),
        );
      }
      if (room.members.length == 2) {
        room.flushPendingTo(socket, senderKey);
      }
      return room;
    }
    if (room.members.length >= 2) {
      return null;
    }
    room.members[senderKey] = <WebSocket>[socket];
    room.lastActivity = _now();
    if (room.members.length == 2) {
      room.flushPendingTo(socket, senderKey);
    }
    return room;
  }

  // _closeRoom (close the whole room and force-close the peer on any member
  // death) was removed 2026-08-07: with identity-keyed session resumption a
  // member's death only vacates its seat — see the finally block in
  // _handleSocket. Deliberate call ends travel as hangup envelopes.

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
    _sweepTimer.cancel();
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

/// Test/fuzz-only exposure of the relay's internal envelope decoder.
///
/// The relay deliberately never parses or trusts frame contents at
/// runtime beyond this one step (extracting `callId` for room routing);
/// everything else is relayed as opaque bytes. This top-level function
/// exists solely so out-of-process fuzz and regression suites can drive
/// [SignalingRelayServer._decodeEnvelope] directly, without standing up a
/// live socket. Not part of the relay's operational surface.
Map<String, Object?>? decodeSignalingEnvelopeForFuzzing(List<int> bytes) =>
    SignalingRelayServer._decodeEnvelope(bytes);
