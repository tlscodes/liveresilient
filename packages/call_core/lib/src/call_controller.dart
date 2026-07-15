import 'dart:async';
import 'dart:math';

enum CallRole { initiator, receiver }

enum CallPhase {
  idle,
  connecting,
  negotiating,
  connected,
  reconnecting,
  ending,
  ended,
  failed,
}

enum CallEndReason {
  localHangup,
  remoteHangup,
  reconnectExhausted,
  protocolError,
  mediaFailure,
  signalingFailure,
  disposed,
}

enum SessionDescriptionType { offer, answer }

enum MediaConnectionState {
  newConnection,
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

enum MediaSignalingState {
  stable,
  haveLocalOffer,
  haveRemoteOffer,
  closed,
}

enum TransportStatus { connecting, connected, disconnected, closed }

final class SessionDescription {
  SessionDescription({
    required this.type,
    required this.sdp,
  }) {
    if (sdp.isEmpty || sdp.length > 1024 * 1024) {
      throw ArgumentError.value(sdp.length, 'sdp.length');
    }
    if (!sdp.trimLeft().startsWith('v=0')) {
      throw ArgumentError.value(
        '<redacted>',
        'sdp',
        'SDP must begin with a v=0 line',
      );
    }
  }

  final SessionDescriptionType type;
  final String sdp;
}

final class IceCandidate {
  IceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  }) {
    final value = candidate;
    if (value != null) {
      if (value.isEmpty || value.length > 16 * 1024) {
        throw ArgumentError.value(value.length, 'candidate.length');
      }
      if (value.contains('\r') || value.contains('\n')) {
        throw ArgumentError.value(
          '<redacted>',
          'candidate',
          'ICE candidates must be a single line',
        );
      }
      if (!value.startsWith('candidate:')) {
        throw ArgumentError.value(
          '<redacted>',
          'candidate',
          'ICE candidate must begin with candidate:',
        );
      }
      if (sdpMid == null && sdpMLineIndex == null) {
        throw ArgumentError(
          'A non-null candidate requires sdpMid or sdpMLineIndex',
        );
      }
    }
    if (sdpMid != null && (sdpMid!.isEmpty || sdpMid!.length > 256)) {
      throw ArgumentError.value(sdpMid, 'sdpMid');
    }
    if (sdpMLineIndex != null && sdpMLineIndex! < 0) {
      throw ArgumentError.value(sdpMLineIndex, 'sdpMLineIndex');
    }
  }

  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

sealed class MediaEvent {
  const MediaEvent();
}

final class LocalIceCandidateEvent extends MediaEvent {
  const LocalIceCandidateEvent(this.candidate);

  final IceCandidate candidate;
}

final class MediaConnectionChangedEvent extends MediaEvent {
  const MediaConnectionChangedEvent(this.state, {this.error});

  final MediaConnectionState state;
  final Object? error;
}

final class MediaFailureEvent extends MediaEvent {
  const MediaFailureEvent(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}

final class TransportEvent {
  const TransportEvent(this.status, {this.error});

  final TransportStatus status;
  final Object? error;
}

sealed class SignalingEvent {
  const SignalingEvent();
}

final class RemoteDescriptionEvent extends SignalingEvent {
  const RemoteDescriptionEvent(this.description);

  final SessionDescription description;
}

final class RemoteIceCandidateEvent extends SignalingEvent {
  const RemoteIceCandidateEvent(this.candidate);

  final IceCandidate candidate;
}

final class RemoteHangupEvent extends SignalingEvent {
  RemoteHangupEvent([this.reason]) {
    final value = reason;
    if (value != null && (value.length > 256 || _containsControl(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  final String? reason;
}

final class RestartRequestedEvent extends SignalingEvent {
  const RestartRequestedEvent();
}

final class SignalingFailureEvent extends SignalingEvent {
  const SignalingFailureEvent(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}

sealed class SignalingCommand {
  const SignalingCommand();
}

final class SendDescriptionCommand extends SignalingCommand {
  const SendDescriptionCommand(this.description);

  final SessionDescription description;
}

final class SendIceCandidateCommand extends SignalingCommand {
  const SendIceCandidateCommand(this.candidate);

  final IceCandidate candidate;
}

final class SendHangupCommand extends SignalingCommand {
  SendHangupCommand([this.reason]) {
    final value = reason;
    if (value != null && (value.length > 256 || _containsControl(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  final String? reason;
}

final class SendRestartRequestCommand extends SignalingCommand {
  const SendRestartRequestCommand();
}

abstract interface class CallTransport {
  Stream<TransportEvent> get events;

  Future<void> connect();

  Future<void> disconnect();
}

abstract interface class CallSignaling {
  Stream<SignalingEvent> get events;

  Future<void> start({
    required String callId,
    required CallRole role,
  });

  Future<void> send(SignalingCommand command);

  Future<void> stop();
}

abstract interface class CallMediaSession {
  Stream<MediaEvent> get events;

  MediaConnectionState get connectionState;

  MediaSignalingState get signalingState;

  Future<void> start();

  Future<SessionDescription> createOffer({required bool iceRestart});

  Future<SessionDescription> createAnswer();

  Future<void> setLocalDescription(SessionDescription description);

  Future<void> setRemoteDescription(SessionDescription description);

  Future<void> addRemoteIceCandidate(IceCandidate candidate);

  Future<void> rollback();

  Future<void> stop();
}

final class ReconnectContext {
  ReconnectContext({
    required this.attempt,
    required this.elapsed,
    required this.cause,
  }) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt');
    }
    if (elapsed.isNegative) {
      throw ArgumentError.value(elapsed, 'elapsed');
    }
  }

  final int attempt;
  final Duration elapsed;
  final Object cause;
}

final class ReconnectDecision {
  ReconnectDecision.retry(this.delay)
      : shouldRetry = true,
        reason = null {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay');
    }
  }

  ReconnectDecision.giveUp([this.reason])
      : shouldRetry = false,
        delay = Duration.zero {
    final value = reason;
    if (value != null && (value.length > 256 || _containsControl(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  final bool shouldRetry;
  final Duration delay;
  final String? reason;
}

abstract interface class ReconnectPolicy {
  ReconnectDecision evaluate(ReconnectContext context);
}

final class ExponentialBackoffReconnectPolicy implements ReconnectPolicy {
  ExponentialBackoffReconnectPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 20),
    this.maxElapsed = const Duration(minutes: 2),
    Random? random,
  }) : _random = random ?? Random() {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts');
    }
    if (baseDelay.isNegative) {
      throw ArgumentError.value(baseDelay, 'baseDelay');
    }
    if (maxDelay.isNegative || maxDelay < baseDelay) {
      throw ArgumentError.value(maxDelay, 'maxDelay');
    }
    if (maxElapsed <= Duration.zero) {
      throw ArgumentError.value(maxElapsed, 'maxElapsed');
    }
  }

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration maxElapsed;
  final Random _random;

  @override
  ReconnectDecision evaluate(ReconnectContext context) {
    if (context.attempt > maxAttempts || context.elapsed >= maxElapsed) {
      return ReconnectDecision.giveUp('Reconnect budget exhausted');
    }

    var capMilliseconds = baseDelay.inMilliseconds;
    for (var i = 1; i < context.attempt; i++) {
      if (capMilliseconds >= maxDelay.inMilliseconds) {
        capMilliseconds = maxDelay.inMilliseconds;
        break;
      }
      capMilliseconds = min(
        maxDelay.inMilliseconds,
        capMilliseconds * 2,
      );
    }

    if (capMilliseconds <= 0) {
      return ReconnectDecision.retry(Duration.zero);
    }

    return ReconnectDecision.retry(
      Duration(milliseconds: _random.nextInt(capMilliseconds + 1)),
    );
  }
}

final class CallState {
  CallState({
    required this.phase,
    required this.sequence,
    required this.changedAt,
    this.reconnectAttempt = 0,
    this.nextRetryAt,
    this.endReason,
    this.error,
  }) {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    if (reconnectAttempt < 0) {
      throw ArgumentError.value(reconnectAttempt, 'reconnectAttempt');
    }
    if (phase == CallPhase.reconnecting && reconnectAttempt < 1) {
      throw ArgumentError(
        'A reconnecting state requires reconnectAttempt >= 1',
      );
    }
    if (phase != CallPhase.reconnecting && nextRetryAt != null) {
      throw ArgumentError(
        'nextRetryAt is only valid for reconnecting states',
      );
    }
    if ((phase == CallPhase.ended || phase == CallPhase.failed) &&
        endReason == null) {
      throw ArgumentError(
        'Terminal states require an end reason',
      );
    }
    if (phase != CallPhase.ended &&
        phase != CallPhase.failed &&
        endReason != null) {
      throw ArgumentError(
        'endReason is only valid for terminal states',
      );
    }
  }

  final CallPhase phase;
  final int sequence;
  final DateTime changedAt;
  final int reconnectAttempt;
  final DateTime? nextRetryAt;
  final CallEndReason? endReason;
  final Object? error;

  bool get isTerminal =>
      phase == CallPhase.ended || phase == CallPhase.failed;
}

final class CallControllerException implements Exception {
  const CallControllerException(
    this.code,
    this.message, {
    this.cause,
  });

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'CallControllerException($code): $message';
}

final class CallProtocolException extends CallControllerException {
  const CallProtocolException(
    String message, {
    Object? cause,
  }) : super('protocol_error', message, cause: cause);
}

final class CallController {
  CallController({
    required String callId,
    required this.role,
    required this.transport,
    required this.signaling,
    required this.media,
    required this.reconnectPolicy,
    this.operationTimeout = const Duration(seconds: 15),
    this.connectionTimeout = const Duration(seconds: 20),
    this.maxBufferedIceCandidates = 256,
  })  : callId = _validateCallId(callId),
        _state = CallState(
          phase: CallPhase.idle,
          sequence: 0,
          changedAt: DateTime.now().toUtc(),
        ) {
    if (operationTimeout <= Duration.zero) {
      throw ArgumentError.value(operationTimeout, 'operationTimeout');
    }
    if (connectionTimeout <= Duration.zero) {
      throw ArgumentError.value(connectionTimeout, 'connectionTimeout');
    }
    if (maxBufferedIceCandidates < 1 ||
        maxBufferedIceCandidates > 4096) {
      throw ArgumentError.value(
        maxBufferedIceCandidates,
        'maxBufferedIceCandidates',
      );
    }
  }

  final String callId;
  final CallRole role;
  final CallTransport transport;
  final CallSignaling signaling;
  final CallMediaSession media;
  final ReconnectPolicy reconnectPolicy;
  final Duration operationTimeout;
  final Duration connectionTimeout;
  final int maxBufferedIceCandidates;

  final StreamController<CallState> _stateController =
      StreamController<CallState>.broadcast(sync: true);
  final Completer<CallState> _doneCompleter = Completer<CallState>();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final List<IceCandidate> _pendingLocalCandidates = <IceCandidate>[];

  late CallState _state;
  Future<void> _serialTail = Future<void>.value();

  bool _started = false;
  bool _disposed = false;
  bool _terminal = false;
  bool _subscriptionsInstalled = false;
  bool _mediaStarted = false;
  bool _signalingStarted = false;
  bool _makingOffer = false;
  bool _ignoreOffer = false;
  bool _suppressChannelEvents = false;
  bool _recoveryActive = false;
  bool _recoveryAttemptInFlight = false;
  bool _waitingForConnection = false;

  int _sequence = 0;
  int _recoveryAttempt = 0;
  DateTime? _recoveryStartedAt;
  Object? _lastRecoveryCause;
  Timer? _recoveryTimer;

  Stream<CallState> get states => _stateController.stream;

  CallState get state => _state;

  Future<CallState> get done => _doneCompleter.future;

  Future<void> start() {
    return _enqueue<void>(() async {
      _ensureNotDisposed();
      if (_started) {
        throw StateError('CallController.start may only be called once');
      }

      _started = true;
      _emit(CallPhase.connecting);
      _installSubscriptions();

      try {
        await _ensureMediaStarted();
        await _connectChannels();
        _emit(CallPhase.negotiating);

        if (role == CallRole.initiator) {
          await _negotiate(iceRestart: false);
        }
      } catch (error, stackTrace) {
        await _beginRecovery(error, stackTrace);
      }
    });
  }

  Future<void> hangUp({String reason = 'hangup'}) {
    if (reason.isEmpty || reason.length > 256 || _containsControl(reason)) {
      return Future<void>.error(
        ArgumentError.value(reason, 'reason'),
      );
    }

    return _enqueue<void>(() async {
      _ensureNotDisposed();
      if (_terminal) {
        return;
      }

      _emit(CallPhase.ending);
      if (_signalingStarted) {
        await _bestEffort(
          () => _bounded(
            signaling.send(SendHangupCommand(reason)),
            'send hangup',
          ),
        );
      }

      await _finishEnded(CallEndReason.localHangup);
    });
  }

  Future<void> dispose() {
    return _enqueue<void>(() async {
      if (_disposed) {
        return;
      }

      if (!_terminal) {
        if (_started) {
          _emit(CallPhase.ending);
        }
        await _finishEnded(CallEndReason.disposed);
      } else {
        await _cancelSubscriptions();
      }

      _disposed = true;
      await _stateController.close();
    });
  }

  void _installSubscriptions() {
    if (_subscriptionsInstalled) {
      throw StateError('Subscriptions are already installed');
    }
    _subscriptionsInstalled = true;

    _subscriptions.add(
      transport.events.listen(
        (event) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(() => _handleTransportEvent(event, suppressed));
        },
        onError: (Object error, StackTrace stackTrace) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              error,
              stackTrace,
              suppressed,
            ),
          );
        },
        onDone: () {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              const CallControllerException(
                'transport_stream_closed',
                'Transport event stream closed unexpectedly',
              ),
              StackTrace.current,
              suppressed,
            ),
          );
        },
      ),
    );

    _subscriptions.add(
      signaling.events.listen(
        (event) => _enqueueEvent(() => _handleSignalingEvent(event)),
        onError: (Object error, StackTrace stackTrace) {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              error,
              stackTrace,
              suppressed,
            ),
          );
        },
        onDone: () {
          final suppressed = _suppressChannelEvents;
          _enqueueEvent(
            () => _handleChannelStreamError(
              const CallControllerException(
                'signaling_stream_closed',
                'Signaling event stream closed unexpectedly',
              ),
              StackTrace.current,
              suppressed,
            ),
          );
        },
      ),
    );

    _subscriptions.add(
      media.events.listen(
        (event) => _enqueueEvent(() => _handleMediaEvent(event)),
        onError: (Object error, StackTrace stackTrace) {
          _enqueueEvent(() => _beginRecovery(error, stackTrace));
        },
        onDone: () {
          _enqueueEvent(
            () => _beginRecovery(
              const CallControllerException(
                'media_stream_closed',
                'Media event stream closed unexpectedly',
              ),
              StackTrace.current,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleTransportEvent(
    TransportEvent event,
    bool suppressed,
  ) async {
    if (_terminal || suppressed) {
      return;
    }

    switch (event.status) {
      case TransportStatus.connecting:
      case TransportStatus.connected:
        return;
      case TransportStatus.disconnected:
      case TransportStatus.closed:
        await _beginRecovery(
          event.error ??
              CallControllerException(
                'transport_${event.status.name}',
                'Call transport became ${event.status.name}',
              ),
          StackTrace.current,
        );
    }
  }

  Future<void> _handleChannelStreamError(
    Object error,
    StackTrace stackTrace,
    bool suppressed,
  ) async {
    if (_terminal || suppressed) {
      return;
    }
    await _beginRecovery(error, stackTrace);
  }

  Future<void> _handleSignalingEvent(SignalingEvent event) async {
    if (_terminal) {
      return;
    }

    try {
      switch (event) {
        case RemoteDescriptionEvent():
          await _handleRemoteDescription(event.description);
        case RemoteIceCandidateEvent():
          if (!_ignoreOffer) {
            await _bounded(
              media.addRemoteIceCandidate(event.candidate),
              'add remote ICE candidate',
            );
          }
        case RemoteHangupEvent():
          await _finishEnded(CallEndReason.remoteHangup);
        case RestartRequestedEvent():
          if (_signalingStarted) {
            await _negotiate(iceRestart: true);
          }
        case SignalingFailureEvent():
          await _beginRecovery(
            event.error,
            event.stackTrace ?? StackTrace.current,
          );
      }
    } on CallProtocolException catch (error, stackTrace) {
      await _fail(
        CallEndReason.protocolError,
        error,
        stackTrace,
      );
    } catch (error, stackTrace) {
      await _beginRecovery(error, stackTrace);
    }
  }

  Future<void> _handleMediaEvent(MediaEvent event) async {
    if (_terminal) {
      return;
    }

    switch (event) {
      case LocalIceCandidateEvent():
        if (_signalingStarted) {
          try {
            await _bounded(
              signaling.send(SendIceCandidateCommand(event.candidate)),
              'send local ICE candidate',
            );
          } catch (error, stackTrace) {
            _bufferLocalCandidate(event.candidate);
            await _beginRecovery(error, stackTrace);
          }
        } else {
          _bufferLocalCandidate(event.candidate);
        }

      case MediaConnectionChangedEvent():
        switch (event.state) {
          case MediaConnectionState.connected:
            _completeRecovery();
            if (_state.phase != CallPhase.connected) {
              _emit(CallPhase.connected);
            }
          case MediaConnectionState.disconnected:
          case MediaConnectionState.failed:
            await _beginRecovery(
              event.error ??
                  CallControllerException(
                    'media_${event.state.name}',
                    'Media connection became ${event.state.name}',
                  ),
              StackTrace.current,
            );
          case MediaConnectionState.closed:
            _mediaStarted = false;
            await _beginRecovery(
              event.error ??
                  const CallControllerException(
                    'media_closed',
                    'Media session closed unexpectedly',
                  ),
              StackTrace.current,
            );
          case MediaConnectionState.newConnection:
          case MediaConnectionState.connecting:
            return;
        }

      case MediaFailureEvent():
        await _beginRecovery(
          event.error,
          event.stackTrace ?? StackTrace.current,
        );
    }
  }

  Future<void> _handleRemoteDescription(
    SessionDescription description,
  ) async {
    switch (description.type) {
      case SessionDescriptionType.offer:
        final collision =
            _makingOffer || media.signalingState != MediaSignalingState.stable;
        final polite = role == CallRole.receiver;

        _ignoreOffer = !polite && collision;
        if (_ignoreOffer) {
          return;
        }

        if (collision) {
          await _bounded(media.rollback(), 'rollback local description');
        }

        await _bounded(
          media.setRemoteDescription(description),
          'set remote offer',
        );
        final answer = await _bounded(
          media.createAnswer(),
          'create answer',
        );
        if (answer.type != SessionDescriptionType.answer) {
          throw CallProtocolException(
            'Media adapter returned ${answer.type.name} from createAnswer',
          );
        }

        await _bounded(
          media.setLocalDescription(answer),
          'set local answer',
        );
        await _bounded(
          signaling.send(SendDescriptionCommand(answer)),
          'send answer',
        );
        _ignoreOffer = false;

      case SessionDescriptionType.answer:
        if (media.signalingState != MediaSignalingState.haveLocalOffer) {
          return;
        }
        await _bounded(
          media.setRemoteDescription(description),
          'set remote answer',
        );
        _ignoreOffer = false;
    }
  }

  Future<void> _negotiate({required bool iceRestart}) async {
    if (_terminal || !_signalingStarted) {
      return;
    }

    if (_makingOffer) {
      return;
    }

    _makingOffer = true;
    try {
      if (iceRestart &&
          media.signalingState != MediaSignalingState.stable) {
        await _bounded(
          media.rollback(),
          'rollback before ICE restart',
        );
      }

      final offer = await _bounded(
        media.createOffer(iceRestart: iceRestart),
        iceRestart ? 'create ICE restart offer' : 'create offer',
      );
      if (offer.type != SessionDescriptionType.offer) {
        throw CallProtocolException(
          'Media adapter returned ${offer.type.name} from createOffer',
        );
      }

      await _bounded(
        media.setLocalDescription(offer),
        'set local offer',
      );
      await _bounded(
        signaling.send(SendDescriptionCommand(offer)),
        'send offer',
      );
    } finally {
      _makingOffer = false;
    }
  }

  Future<void> _ensureMediaStarted() async {
    if (_mediaStarted) {
      return;
    }
    await _bounded(media.start(), 'start media session');
    _mediaStarted = true;
  }

  Future<void> _connectChannels() async {
    await _bounded(transport.connect(), 'connect transport');
    await _bounded(
      signaling.start(callId: callId, role: role),
      'start signaling',
    );
    _signalingStarted = true;
    await _flushLocalCandidates();
  }

  Future<void> _resetChannels() async {
    _suppressChannelEvents = true;
    try {
      if (_signalingStarted) {
        await _bestEffort(
          () => _bounded(signaling.stop(), 'stop signaling'),
        );
      }
      _signalingStarted = false;
      await _bestEffort(
        () => _bounded(transport.disconnect(), 'disconnect transport'),
      );
    } finally {
      _suppressChannelEvents = false;
    }
  }

  Future<void> _beginRecovery(
    Object cause,
    StackTrace stackTrace,
  ) async {
    if (_terminal || !_started) {
      return;
    }

    _lastRecoveryCause = cause;
    if (!_recoveryActive) {
      _recoveryActive = true;
      _recoveryAttempt = 0;
      _recoveryStartedAt = DateTime.now().toUtc();
    }

    if (_recoveryAttemptInFlight) {
      return;
    }

    if (_waitingForConnection) {
      _waitingForConnection = false;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    } else if (_recoveryTimer != null) {
      return;
    }

    await _scheduleNextRecovery(cause, stackTrace);
  }

  Future<void> _scheduleNextRecovery(
    Object cause,
    StackTrace stackTrace,
  ) async {
    if (_terminal) {
      return;
    }

    final startedAt = _recoveryStartedAt ?? DateTime.now().toUtc();
    final nextAttempt = _recoveryAttempt + 1;
    late final ReconnectDecision decision;

    try {
      decision = reconnectPolicy.evaluate(
        ReconnectContext(
          attempt: nextAttempt,
          elapsed: DateTime.now().toUtc().difference(startedAt),
          cause: cause,
        ),
      );
    } catch (error, policyStackTrace) {
      await _fail(
        CallEndReason.reconnectExhausted,
        CallControllerException(
          'invalid_reconnect_policy',
          'Reconnect policy evaluation failed',
          cause: error,
        ),
        policyStackTrace,
      );
      return;
    }

    if (!decision.shouldRetry) {
      await _fail(
        CallEndReason.reconnectExhausted,
        CallControllerException(
          'reconnect_exhausted',
          decision.reason ?? 'Reconnect policy declined another attempt',
          cause: cause,
        ),
        stackTrace,
      );
      return;
    }

    final retryAt = DateTime.now().toUtc().add(decision.delay);
    _emit(
      CallPhase.reconnecting,
      reconnectAttempt: nextAttempt,
      nextRetryAt: retryAt,
      error: cause,
    );

    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(decision.delay, () {
      _recoveryTimer = null;
      _enqueueEvent(() => _performRecoveryAttempt(nextAttempt));
    });
  }

  Future<void> _performRecoveryAttempt(int attempt) async {
    if (_terminal ||
        !_recoveryActive ||
        attempt != _recoveryAttempt + 1) {
      return;
    }

    _recoveryAttempt = attempt;
    _recoveryAttemptInFlight = true;
    _waitingForConnection = false;

    try {
      await _resetChannels();
      await _ensureMediaStarted();
      await _connectChannels();

      if (role == CallRole.initiator) {
        await _negotiate(iceRestart: true);
      } else {
        await _bounded(
          signaling.send(const SendRestartRequestCommand()),
          'request ICE restart',
        );
        await _negotiate(iceRestart: true);
      }

      _recoveryAttemptInFlight = false;

      if (media.connectionState == MediaConnectionState.connected) {
        _completeRecovery();
        if (_state.phase != CallPhase.connected) {
          _emit(CallPhase.connected);
        }
        return;
      }

      _waitingForConnection = true;
      _recoveryTimer = Timer(connectionTimeout, () {
        _recoveryTimer = null;
        _enqueueEvent(() async {
          if (_terminal ||
              !_recoveryActive ||
              !_waitingForConnection) {
            return;
          }
          _waitingForConnection = false;
          final cause = CallControllerException(
            'reconnect_connection_timeout',
            'Media did not reconnect within the connection timeout',
            cause: _lastRecoveryCause,
          );
          _lastRecoveryCause = cause;
          await _scheduleNextRecovery(cause, StackTrace.current);
        });
      });
    } catch (error, stackTrace) {
      _recoveryAttemptInFlight = false;
      _waitingForConnection = false;
      _lastRecoveryCause = error;
      await _scheduleNextRecovery(error, stackTrace);
    }
  }

  void _completeRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryActive = false;
    _recoveryAttemptInFlight = false;
    _waitingForConnection = false;
    _recoveryAttempt = 0;
    _recoveryStartedAt = null;
    _lastRecoveryCause = null;
  }

  void _bufferLocalCandidate(IceCandidate candidate) {
    if (_pendingLocalCandidates.length >= maxBufferedIceCandidates) {
      _pendingLocalCandidates.removeAt(0);
    }
    _pendingLocalCandidates.add(candidate);
  }

  Future<void> _flushLocalCandidates() async {
    while (_signalingStarted &&
        !_terminal &&
        _pendingLocalCandidates.isNotEmpty) {
      final candidate = _pendingLocalCandidates.first;
      await _bounded(
        signaling.send(SendIceCandidateCommand(candidate)),
        'flush local ICE candidate',
      );
      _pendingLocalCandidates.removeAt(0);
    }
  }

  Future<void> _finishEnded(CallEndReason reason) async {
    if (_terminal) {
      return;
    }

    _terminal = true;
    _completeRecovery();
    await _teardown();
    _emit(CallPhase.ended, endReason: reason);
    _completeDone();
  }

  Future<void> _fail(
    CallEndReason reason,
    Object error,
    StackTrace stackTrace,
  ) async {
    if (_terminal) {
      return;
    }

    _terminal = true;
    _completeRecovery();
    await _teardown();
    _emit(
      CallPhase.failed,
      endReason: reason,
      error: error,
    );
    _completeDone();
  }

  Future<void> _teardown() async {
    _suppressChannelEvents = true;
    try {
      if (_signalingStarted) {
        await _bestEffort(
          () => _bounded(signaling.stop(), 'stop signaling'),
        );
      }
      _signalingStarted = false;

      await _bestEffort(
        () => _bounded(transport.disconnect(), 'disconnect transport'),
      );

      if (_mediaStarted) {
        await _bestEffort(
          () => _bounded(media.stop(), 'stop media session'),
        );
      }
      _mediaStarted = false;
      _pendingLocalCandidates.clear();
    } finally {
      await _cancelSubscriptions();
      _suppressChannelEvents = false;
    }
  }

  Future<void> _cancelSubscriptions() async {
    if (_subscriptions.isEmpty) {
      return;
    }

    final subscriptions =
        List<StreamSubscription<Object?>>.of(_subscriptions);
    _subscriptions.clear();

    for (final subscription in subscriptions) {
      await _bestEffort(subscription.cancel);
    }
  }

  void _emit(
    CallPhase phase, {
    int reconnectAttempt = 0,
    DateTime? nextRetryAt,
    CallEndReason? endReason,
    Object? error,
  }) {
    if (!_isAllowedTransition(_state.phase, phase)) {
      throw StateError(
        'Invalid call state transition: ${_state.phase.name} -> ${phase.name}',
      );
    }

    final next = CallState(
      phase: phase,
      sequence: ++_sequence,
      changedAt: DateTime.now().toUtc(),
      reconnectAttempt: reconnectAttempt,
      nextRetryAt: nextRetryAt,
      endReason: endReason,
      error: error,
    );
    _state = next;

    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void _completeDone() {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete(_state);
    }
  }

  Future<T> _bounded<T>(Future<T> future, String operation) {
    return future.timeout(
      operationTimeout,
      onTimeout: () {
        throw TimeoutException(
          'Timed out while attempting to $operation',
          operationTimeout,
        );
      },
    );
  }

  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      return;
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      try {
        completer.complete(await task());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _enqueueEvent(Future<void> Function() task) {
    unawaited(
      _enqueue<void>(() async {
        if (_disposed) {
          return;
        }
        await task();
      }).catchError((Object _, StackTrace __) {}),
    );
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('CallController has been disposed');
    }
  }

  static bool _isAllowedTransition(CallPhase from, CallPhase to) {
    if (from == to) {
      return true;
    }

    return switch (from) {
      CallPhase.idle =>
        to == CallPhase.connecting ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.connecting =>
        to == CallPhase.negotiating ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.failed,
      CallPhase.negotiating =>
        to == CallPhase.connected ||
            to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.failed,
      CallPhase.connected =>
        to == CallPhase.reconnecting ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.reconnecting =>
        to == CallPhase.connected ||
            to == CallPhase.ending ||
            to == CallPhase.ended ||
            to == CallPhase.failed,
      CallPhase.ending =>
        to == CallPhase.ended || to == CallPhase.failed,
      CallPhase.ended => false,
      CallPhase.failed => false,
    };
  }

  static String _validateCallId(String value) {
    if (value.isEmpty || value.length > 128) {
      throw ArgumentError.value(value, 'callId');
    }

    final valid = RegExp(r'^[A-Za-z0-9._~-]+$');
    if (!valid.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'callId',
        'callId contains unsupported characters',
      );
    }
    return value;
  }
}

bool _containsControl(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) {
      return true;
    }
  }
  return false;
}

// GAPS:
