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

  /// Extra concurrent sockets for HEDGED transmission (raised 2026-08-09,
  /// loss60): one TCP stream under heavy loss stalls for tens of seconds
  /// on retransmission, and a stalled stream serialized the whole
  /// negotiation. Each outbound frame fans out over every open socket
  /// (first delivery wins — the relay's multi-socket seat fans inbound
  /// frames back to all of them, and the client deduplicator drops the
  /// copies). 0 = classic single-socket behavior.
  final int hedgeSockets;

  /// How long an enqueued outbound message keeps being retried before the
  /// outbox gives up with `OutboxOutcome.expired`.
  ///
  /// Was a fixed 2 minutes inside `OutboxConfig` with no path to change it.
  /// Measured 2026-08-07 (T2 loss60, 60% per-direction loss): a signaling
  /// send legitimately outlived 2 minutes across socket flaps and
  /// retransmit ladders, the expiry fired, the caller treated it as a
  /// recovery trigger, and the recovery it triggered restarted the very
  /// negotiation the message belonged to. The invariant this field exists
  /// to carry: the outbox never gives up before the reconnect budget does
  /// (`AdaptiveConnectionBudget.signalingTiming` derives it as
  /// `max(floor, maxElapsed)`).
  final Duration outboxMessageLifetime;

  // Not a `const` constructor: validation below must run eagerly and
  // unconditionally (an `assert` in a const-constructor initializer list
  // must be a compile-time-constant expression, and `Duration` getters/
  // operators are not const-evaluable — confirmed by `dart analyze`), so
  // this throws a real `ArgumentError` on every code path, debug or
  // release.
  SignalingClientConfig({
    this.heartbeatInterval = const Duration(seconds: 15),
    this.livenessTimeout = const Duration(seconds: 45),
    this.initialReconnectDelay = const Duration(milliseconds: 500),
    this.maxReconnectDelay = const Duration(seconds: 30),
    this.maxReconnectAttempts = 10,
    this.maxEnvelopeAge = const Duration(minutes: 5),
    this.connectTimeout = const Duration(seconds: 10),
    this.outboxMessageLifetime = const Duration(minutes: 2),
    this.hedgeSockets = 0,
  }) {
    if (outboxMessageLifetime <= Duration.zero) {
      throw ArgumentError.value(
        outboxMessageLifetime,
        'outboxMessageLifetime',
        'Must be positive.',
      );
    }
    if (heartbeatInterval <= Duration.zero) {
      throw ArgumentError.value(
        heartbeatInterval,
        'heartbeatInterval',
        'Must be positive.',
      );
    }
    if (livenessTimeout <= Duration.zero) {
      throw ArgumentError.value(
        livenessTimeout,
        'livenessTimeout',
        'Must be positive.',
      );
    }
    if (initialReconnectDelay <= Duration.zero) {
      throw ArgumentError.value(
        initialReconnectDelay,
        'initialReconnectDelay',
        'Must be positive.',
      );
    }
    if (maxReconnectDelay <= Duration.zero) {
      throw ArgumentError.value(
        maxReconnectDelay,
        'maxReconnectDelay',
        'Must be positive.',
      );
    }
    if (maxReconnectAttempts < 1) {
      throw ArgumentError.value(
        maxReconnectAttempts,
        'maxReconnectAttempts',
        'Must be >= 1.',
      );
    }
    if (maxEnvelopeAge <= Duration.zero) {
      throw ArgumentError.value(
        maxEnvelopeAge,
        'maxEnvelopeAge',
        'Must be positive.',
      );
    }
    if (connectTimeout <= Duration.zero) {
      throw ArgumentError.value(
        connectTimeout,
        'connectTimeout',
        'Must be positive.',
      );
    }
    if (livenessTimeout <= heartbeatInterval) {
      throw ArgumentError.value(
        livenessTimeout,
        'livenessTimeout',
        'Must be greater than heartbeatInterval ($heartbeatInterval): a '
            'liveness timeout shorter than (or equal to) the heartbeat '
            'interval tears the socket down before the next heartbeat is '
            'even due.',
      );
    }
  }
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
  final List<SignalingSocket> _hedges = <SignalingSocket>[];
  final List<StreamSubscription<List<int>>> _hedgeSubscriptions =
      <StreamSubscription<List<int>>>[];
  bool _hedgeDialInFlight = false;
  Timer? _heartbeatTimer;
  Timer? _livenessTimer;
  Timer? _reconnectTimer;

  SignalingConnectionState _state = SignalingConnectionState.disconnected;
  int _reconnectAttempts = 0;
  int _outgoingSequence = 0;

  /// The room id of the most recent APP envelope through [send] or
  /// [_onFrame] — heartbeats carry it so every socket's first frame pins
  /// the socket to the call room on the relay (see _startHeartbeat).
  String? _appRoomId;
  bool _disposed = false;
  bool _connectInFlight = false;
  final math.Random _random = math.Random.secure();

  SignalingClient({
    required this.endpoint,
    required this.localKeyId,
    required SignalingSocketConnector connector,
    OutboxStore? outboxStore,
    SignalingClientConfig? config,
  }) : _connector = connector,
       // `SignalingClientConfig` validates eagerly and so is no longer
       // `const`-constructible; a compile-time-constant default value is
       // therefore not possible here, hence the nullable parameter with
       // this runtime fallback (same effective default as before).
       config = config ?? SignalingClientConfig() {
    if (endpoint.scheme != 'wss') {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Signaling requires a wss:// endpoint.',
      );
    }
    _outbox = ReliableOutbox(
      transmit: _transmitFrame,
      store: outboxStore,
      config: OutboxConfig(messageLifetime: this.config.outboxMessageLifetime),
    );
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
    // A manual connect() is a fresh attempt, not a continuation of whatever
    // reconnect back-off happened before: reset the budget so it reports
    // `connecting` (not a stale `reconnecting`) and gets a full, un-exhausted
    // retry allowance on any subsequent failure.
    _reconnectAttempts = 0;
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
    _appRoomId = callId;
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
      unawaited(_topUpHedges());
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
    if (_promoteHedge()) return;
    _teardownSocket();
    _scheduleReconnect();
  }

  /// HEDGE PROMOTION (raised 2026-08-09, loss60): losing the primary used
  /// to tear down every healthy hedge with it — the redundancy bought for
  /// heavy loss had a single point of failure, so one server-side seat
  /// eviction or one liveness lapse cost the whole transport plus three
  /// fresh dial lotteries at 60% loss. Now the oldest hedge takes over as
  /// primary: the dead primary is closed, the hedge's existing
  /// subscription is retargeted to the primary handlers (frames are
  /// single-subscription — never cancel + re-listen), timers restart, the
  /// hedge pool re-fills lazily, and pending envelopes flush immediately.
  /// Returns false when no hedge remains — only then does the full
  /// teardown + reconnect lottery run.
  bool _promoteHedge() {
    _heartbeatTimer?.cancel();
    _livenessTimer?.cancel();
    _frameSubscription?.cancel();
    final dead = _socket;
    _socket = null;
    dead?.close().catchError((Object _) {});
    if (_hedges.isEmpty) {
      return false;
    }
    final promoted = _hedges.removeAt(0);
    final subscription = _hedgeSubscriptions.removeAt(0);
    subscription
      ..onError((Object _) => _onSocketLost())
      ..onDone(_onSocketLost);
    _socket = promoted;
    _frameSubscription = subscription;
    _startHeartbeat();
    _armLivenessTimer();
    unawaited(_topUpHedges());
    _outbox.flush();
    return true;
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
    for (final subscription in _hedgeSubscriptions) {
      unawaited(subscription.cancel());
    }
    _hedgeSubscriptions.clear();
    for (final hedge in _hedges) {
      unawaited(hedge.close().catchError((Object _) {}));
    }
    _hedges.clear();
  }

  // ---------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------

  Future<bool> _transmitFrame(SignalEnvelope envelope) async {
    final socket = _socket;
    if (socket == null || _state != SignalingConnectionState.connected) {
      return false;
    }
    final bytes = envelope.toBytes();
    // HEDGED FAN-OUT: the same frame races over every open socket; a
    // stalled stream can no longer serialize the negotiation. Hedge
    // failures are absorbed (the primary's await below is the truth the
    // outbox acts on) and trigger a lazy top-up.
    for (final hedge in List<SignalingSocket>.of(_hedges)) {
      unawaited(
        hedge.sendFrame(bytes).catchError((Object _) {
          _dropHedge(hedge);
        }),
      );
    }
    unawaited(_topUpHedges());
    await socket.sendFrame(bytes);
    return true;
  }

  Future<void> _topUpHedges() async {
    if (_disposed ||
        _hedgeDialInFlight ||
        config.hedgeSockets <= 0 ||
        _state != SignalingConnectionState.connected ||
        _hedges.length >= config.hedgeSockets) {
      return;
    }
    _hedgeDialInFlight = true;
    try {
      while (!_disposed &&
          _state == SignalingConnectionState.connected &&
          _hedges.length < config.hedgeSockets) {
        final SignalingSocket hedge;
        try {
          hedge = await _connector(endpoint).timeout(config.connectTimeout);
        } catch (_) {
          return; // Lazy: the next transmit tops up again.
        }
        if (_disposed || _state != SignalingConnectionState.connected) {
          unawaited(hedge.close().catchError((Object _) {}));
          return;
        }
        _hedges.add(hedge);
        _hedgeSubscriptions.add(
          hedge.frames.listen(
            _onFrame,
            onError: (Object _) => _dropHedge(hedge),
            onDone: () => _dropHedge(hedge),
            cancelOnError: true,
          ),
        );
      }
    } finally {
      _hedgeDialInFlight = false;
    }
  }

  void _dropHedge(SignalingSocket hedge) {
    final index = _hedges.indexWhere((s) => identical(s, hedge));
    if (index < 0) return;
    _hedges.removeAt(index);
    final subscription = _hedgeSubscriptions.removeAt(index);
    unawaited(subscription.cancel());
    unawaited(hedge.close().catchError((Object _) {}));
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
        _appRoomId = envelope.callId;
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
      // ROOM-TRUE HEARTBEATS (raised 2026-08-09, loss60): the relay pins a
      // socket to the room of its FIRST frame. A hedge socket whose first
      // fanned frame was a heartbeat used to join a room literally named
      // 'session'; after a hedge promotion the whole transport could end
      // up there while the peer stayed in the call room — two stranded
      // rooms, offers/candidates buffering forever, zero CreatePermission
      // in a 500 s verbose TURN log. Heartbeats now carry the last app
      // envelope's room id so every socket pins to the CALL room;
      // 'session' remains only before the first-ever send().
      final heartbeat = SignalEnvelope(
        messageId: generateSignalMessageId(),
        sequence: _outgoingSequence,
        callId: _appRoomId ?? 'session',
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
