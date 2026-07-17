/// Signaling client over standard secure WebSocket (WSS).
///
/// Responsibilities:
/// - maintain a WSS session to the signaling service with automatic
///   reconnect (bounded exponential back-off with jitter);
/// - heartbeats with liveness timeout detection;
/// - reliable at-least-once outgoing delivery via [ReliableOutbox];
/// - receiver-side de-duplication and automatic acknowledgements;
/// - a typed inbound stream and a connection-state stream for the UI.
///
/// The socket itself is abstracted behind [SignalingSocket] /
/// [SignalingSocketConnector] so platform WebSocket implementations and
/// tests plug in without touching protocol logic. Endpoints come from the
/// verified signed manifest (`signed_config` package) — this client never
/// invents or rewrites destinations.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';

import 'reliable_outbox.dart';
import 'signal_envelope.dart';

/// Minimal duplex frame socket contract (implemented over `WebSocket` /
/// `web_socket_channel` in the app layer).
abstract interface class SignalingSocket {
  Stream<List<int>> get frames;
  Future<void> sendFrame(List<int> frame);
  Future<void> close();
}

/// Opens a socket to [uri]. Must throw on failure; must only accept `wss`
/// URIs (enforced again by the client as defense in depth).
typedef SignalingSocketConnector = Future<SignalingSocket> Function(Uri uri);

enum SignalingConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  closed,
}

class SignalingClientConfig {
  final Duration heartbeatInterval;

  /// The connection is considered dead when nothing (including heartbeats)
  /// arrives for this long.
  final Duration livenessTimeout;

  final Duration initialReconnectDelay;
  final Duration maxReconnectDelay;

  /// Give up after this many consecutive failed reconnect attempts.
  final int maxReconnectAttempts;

  /// Inbound envelopes older than this are dropped as stale.
  final Duration maxEnvelopeAge;

  /// Bound on a single socket dial: a connector that hangs past this is
  /// treated as a failed attempt and schedules a reconnect, so the client
  /// never sits in `connecting` indefinitely.
  final Duration connectTimeout;

  const SignalingClientConfig({
    this.heartbeatInterval = const Duration(seconds: 15),
    this.livenessTimeout = const Duration(seconds: 45),
    this.initialReconnectDelay = const Duration(milliseconds: 500),
    this.maxReconnectDelay = const Duration(seconds: 30),
    this.maxReconnectAttempts = 10,
    this.maxEnvelopeAge = const Duration(minutes: 5),
    this.connectTimeout = const Duration(seconds: 10),
  });
}

class SignalingClient {
  final Uri endpoint;
  final String localKeyId;
  final SignalingSocketConnector _connector;
  final SignalingClientConfig config;

  late final ReliableOutbox _outbox;
  final InboxDeduplicator _deduplicator = InboxDeduplicator();

  final _inboundController = StreamController<SignalEnvelope>.broadcast();
  final _stateController =
      StreamController<SignalingConnectionState>.broadcast();

  SignalingSocket? _socket;
  StreamSubscription<List<int>>? _frameSubscription;
  Timer? _heartbeatTimer;
  Timer? _livenessTimer;
  Timer? _reconnectTimer;

  SignalingConnectionState _state = SignalingConnectionState.disconnected;
  int _reconnectAttempts = 0;
  int _outgoingSequence = 0;
  bool _disposed = false;
  bool _connectInFlight = false;
  final math.Random _random = math.Random.secure();

  SignalingClient({
    required this.endpoint,
    required this.localKeyId,
    required SignalingSocketConnector connector,
    OutboxStore? outboxStore,
    this.config = const SignalingClientConfig(),
  }) : _connector = connector {
    if (endpoint.scheme != 'wss') {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Signaling requires a wss:// endpoint.',
      );
    }
    _outbox = ReliableOutbox(transmit: _transmitFrame, store: outboxStore);
  }

  /// Application-facing inbound envelopes (acks and heartbeats are consumed
  /// internally and never surface here).
  Stream<SignalEnvelope> get inbound => _inboundController.stream;

  Stream<SignalingConnectionState> get connectionState =>
      _stateController.stream;

  SignalingConnectionState get currentState => _state;

  Future<void> connect() async {
    if (_disposed) throw StateError('Client has been disposed.');
    if (_state == SignalingConnectionState.connected ||
        _state == SignalingConnectionState.connecting) {
      return;
    }
    await _outbox.restore();
    await _openSocket();
  }

  /// Sends an application envelope with at-least-once delivery. Completes
  /// with the terminal outbox outcome.
  Future<OutboxOutcome> send({
    required String callId,
    required SignalType type,
    required Map<String, Object?> payload,
  }) {
    if (_disposed) throw StateError('Client has been disposed.');
    _outgoingSequence++;
    final envelope = SignalEnvelope(
      messageId: generateSignalMessageId(),
      sequence: _outgoingSequence,
      callId: callId,
      senderKeyId: localKeyId,
      type: type,
      createdAtMs: clock.now().millisecondsSinceEpoch,
      payload: payload,
    );
    return _outbox.enqueue(envelope);
  }

  // ---------------------------------------------------------------------
  // Socket lifecycle
  // ---------------------------------------------------------------------

  Future<void> _openSocket() async {
    // Single-flight: connect() during a reconnect back-off (or two racing
    // connect() calls) must never dial twice — the pending back-off timer
    // is absorbed here and the in-flight flag blocks a second dial that
    // would leak the first socket.
    if (_disposed || _connectInFlight || _socket != null) {
      return;
    }
    _connectInFlight = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(
      _reconnectAttempts == 0
          ? SignalingConnectionState.connecting
          : SignalingConnectionState.reconnecting,
    );
    try {
      final socket = await _connector(endpoint).timeout(config.connectTimeout);
      if (_disposed) {
        // dispose() ran while the dial was in flight: the late socket must
        // not outlive the client.
        unawaited(socket.close().catchError((Object _) {}));
        return;
      }
      _socket = socket;
      _frameSubscription = socket.frames.listen(
        _onFrame,
        onError: (Object _) => _onSocketLost(),
        onDone: _onSocketLost,
        cancelOnError: true,
      );
      _reconnectAttempts = 0;
      _setState(SignalingConnectionState.connected);
      _startHeartbeat();
      _armLivenessTimer();
      _outbox.flush();
    } catch (_) {
      if (!_disposed) {
        _scheduleReconnect();
      }
    } finally {
      _connectInFlight = false;
    }
  }

  void _onSocketLost() {
    if (_disposed) return;
    _teardownSocket();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempts >= config.maxReconnectAttempts) {
      _setState(SignalingConnectionState.disconnected);
      return;
    }
    _reconnectAttempts++;
    final base =
        config.initialReconnectDelay.inMilliseconds *
        math.pow(2, _reconnectAttempts - 1).toDouble();
    final capped = math.min(base, config.maxReconnectDelay.inMilliseconds);
    // Full jitter prevents synchronized reconnect storms after an outage.
    final delayMs = (_random.nextDouble() * capped).round();
    _setState(SignalingConnectionState.reconnecting);
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), _openSocket);
  }

  void _teardownSocket() {
    _heartbeatTimer?.cancel();
    _livenessTimer?.cancel();
    _frameSubscription?.cancel();
    final socket = _socket;
    _socket = null;
    socket?.close().catchError((Object _) {});
  }

  // ---------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------

  Future<bool> _transmitFrame(SignalEnvelope envelope) async {
    final socket = _socket;
    if (socket == null || _state != SignalingConnectionState.connected) {
      return false;
    }
    await socket.sendFrame(envelope.toBytes());
    return true;
  }

  Future<void> _onFrame(List<int> frame) async {
    _armLivenessTimer();

    final SignalEnvelope envelope;
    try {
      envelope = SignalEnvelope.fromBytes(frame);
    } on FormatException {
      return; // Malformed frames are dropped, never crash the session.
    }

    final ageMs = clock.now().millisecondsSinceEpoch - envelope.createdAtMs;
    if (ageMs > config.maxEnvelopeAge.inMilliseconds) {
      return;
    }

    switch (envelope.type) {
      case SignalType.heartbeat:
        return; // Liveness already recorded above.
      case SignalType.ack:
        final acked = envelope.payload['ackedMessageId'];
        if (acked is String) {
          await _outbox.acknowledge(acked);
        }
        return;
      case SignalType.offer:
      case SignalType.answer:
      case SignalType.iceCandidate:
      case SignalType.callControl:
        await _acknowledge(envelope);
        if (_deduplicator.markIfNew(envelope.messageId)) {
          if (!_inboundController.isClosed) {
            _inboundController.add(envelope);
          }
        }
    }
  }

  Future<void> _acknowledge(SignalEnvelope received) async {
    _outgoingSequence++;
    final ack = received.buildAck(
      ackSenderKeyId: localKeyId,
      sequence: _outgoingSequence,
      nowMs: clock.now().millisecondsSinceEpoch,
    );
    try {
      await _transmitFrame(ack); // Fire-and-forget; sender retries anyway.
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Liveness
  // ---------------------------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(config.heartbeatInterval, (_) {
      _outgoingSequence++;
      final heartbeat = SignalEnvelope(
        messageId: generateSignalMessageId(),
        sequence: _outgoingSequence,
        callId: 'session',
        senderKeyId: localKeyId,
        type: SignalType.heartbeat,
        createdAtMs: clock.now().millisecondsSinceEpoch,
        payload: const {},
      );
      _transmitFrame(heartbeat).catchError((Object _) => false);
    });
  }

  void _armLivenessTimer() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer(config.livenessTimeout, _onSocketLost);
  }

  void _setState(SignalingConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _teardownSocket();
    await _outbox.dispose();
    _setState(SignalingConnectionState.closed);
    await _inboundController.close();
    await _stateController.close();
  }
}
