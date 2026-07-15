import 'dart:async';

import 'package:call_core/call_core.dart';

/// A minimal valid offer SDP, unique per [tag]/[version] so different
/// invocations can be told apart in assertions/logs if needed.
SessionDescription fakeOffer({String tag = 'offer', int version = 1}) =>
    SessionDescription(
      type: SessionDescriptionType.offer,
      sdp: 'v=0\r\no=- $version 1 IN IP4 127.0.0.1\r\ns=$tag\r\nt=0 0\r\n',
    );

/// A minimal valid answer SDP.
SessionDescription fakeAnswer({String tag = 'answer', int version = 1}) =>
    SessionDescription(
      type: SessionDescriptionType.answer,
      sdp: 'v=0\r\no=- $version 1 IN IP4 127.0.0.1\r\ns=$tag\r\nt=0 0\r\n',
    );

/// A syntactically valid ICE candidate, distinguishable by [index].
IceCandidate fakeCandidate(int index) => IceCandidate(
  candidate: 'candidate:$index 1 UDP 2122260223 10.0.0.$index 5$index typ host',
  sdpMid: '0',
  sdpMLineIndex: 0,
);

/// Shared, ordered call log across fakes so cross-collaborator ordering
/// (e.g. "media.start before transport.connect before signaling.start")
/// can be asserted on a single timeline instead of three separate ones.
final class CallLog {
  final List<String> entries = <String>[];

  void add(String entry) => entries.add(entry);
}

final class FakeTransport implements CallTransport {
  FakeTransport({CallLog? log}) : _log = log;

  final CallLog? _log;
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);

  int connectCalls = 0;
  int disconnectCalls = 0;

  /// Overridable async behavior; defaults to an immediate success.
  Future<void> Function()? connectImpl;
  Future<void> Function()? disconnectImpl;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    connectCalls++;
    _log?.add('transport.connect');
    if (connectImpl != null) {
      await connectImpl!();
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _log?.add('transport.disconnect');
    if (disconnectImpl != null) {
      await disconnectImpl!();
    }
  }

  void emit(TransportEvent event) => _events.add(event);

  void emitError(Object error, [StackTrace? stackTrace]) =>
      _events.addError(error, stackTrace ?? StackTrace.current);

  Future<void> close() => _events.close();
}

final class FakeSignaling implements CallSignaling {
  FakeSignaling({CallLog? log}) : _log = log;

  final CallLog? _log;
  final StreamController<SignalingEvent> _events =
      StreamController<SignalingEvent>.broadcast(sync: true);

  int startCalls = 0;
  int stopCalls = 0;
  final List<SignalingCommand> sent = <SignalingCommand>[];

  Future<void> Function({required String callId, required CallRole role})?
  startImpl;
  Future<void> Function(SignalingCommand command)? sendImpl;
  Future<void> Function()? stopImpl;

  @override
  Stream<SignalingEvent> get events => _events.stream;

  @override
  Future<void> start({required String callId, required CallRole role}) async {
    startCalls++;
    _log?.add('signaling.start');
    if (startImpl != null) {
      await startImpl!(callId: callId, role: role);
    }
  }

  @override
  Future<void> send(SignalingCommand command) async {
    sent.add(command);
    _log?.add('signaling.send(${_describe(command)})');
    if (sendImpl != null) {
      await sendImpl!(command);
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _log?.add('signaling.stop');
    if (stopImpl != null) {
      await stopImpl!();
    }
  }

  static String _describe(SignalingCommand command) => switch (command) {
    SendDescriptionCommand(:final description) =>
      'description:${description.type.name}',
    SendIceCandidateCommand() => 'ice',
    SendHangupCommand() => 'hangup',
    SendRestartRequestCommand() => 'restart',
  };

  void emit(SignalingEvent event) => _events.add(event);

  void emitError(Object error, [StackTrace? stackTrace]) =>
      _events.addError(error, stackTrace ?? StackTrace.current);

  Future<void> close() => _events.close();
}

final class FakeMedia implements CallMediaSession {
  FakeMedia({CallLog? log}) : _log = log;

  final CallLog? _log;
  final StreamController<MediaEvent> _events =
      StreamController<MediaEvent>.broadcast(sync: true);

  @override
  MediaConnectionState connectionState = MediaConnectionState.newConnection;

  @override
  MediaSignalingState signalingState = MediaSignalingState.stable;

  int startCalls = 0;
  int stopCalls = 0;
  int rollbackCalls = 0;
  final List<IceCandidate> remoteCandidates = <IceCandidate>[];

  Future<void> Function()? startImpl;
  Future<SessionDescription> Function({required bool iceRestart})?
  createOfferImpl;
  Future<SessionDescription> Function()? createAnswerImpl;
  Future<void> Function(SessionDescription description)?
  setLocalDescriptionImpl;
  Future<void> Function(SessionDescription description)?
  setRemoteDescriptionImpl;
  Future<void> Function(IceCandidate candidate)? addRemoteIceCandidateImpl;
  Future<void> Function()? rollbackImpl;
  Future<void> Function()? stopImpl;

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    startCalls++;
    _log?.add('media.start');
    if (startImpl != null) {
      await startImpl!();
    }
  }

  @override
  Future<SessionDescription> createOffer({required bool iceRestart}) async {
    _log?.add('media.createOffer(iceRestart:$iceRestart)');
    if (createOfferImpl != null) {
      return createOfferImpl!(iceRestart: iceRestart);
    }
    return fakeOffer();
  }

  @override
  Future<SessionDescription> createAnswer() async {
    _log?.add('media.createAnswer');
    if (createAnswerImpl != null) {
      return createAnswerImpl!();
    }
    return fakeAnswer();
  }

  @override
  Future<void> setLocalDescription(SessionDescription description) async {
    _log?.add('media.setLocalDescription(${description.type.name})');
    if (setLocalDescriptionImpl != null) {
      await setLocalDescriptionImpl!(description);
    } else {
      signalingState = description.type == SessionDescriptionType.offer
          ? MediaSignalingState.haveLocalOffer
          : MediaSignalingState.stable;
    }
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    _log?.add('media.setRemoteDescription(${description.type.name})');
    if (setRemoteDescriptionImpl != null) {
      await setRemoteDescriptionImpl!(description);
    } else {
      signalingState = description.type == SessionDescriptionType.offer
          ? MediaSignalingState.haveRemoteOffer
          : MediaSignalingState.stable;
    }
  }

  @override
  Future<void> addRemoteIceCandidate(IceCandidate candidate) async {
    remoteCandidates.add(candidate);
    _log?.add('media.addRemoteIceCandidate');
    if (addRemoteIceCandidateImpl != null) {
      await addRemoteIceCandidateImpl!(candidate);
    }
  }

  @override
  Future<void> rollback() async {
    rollbackCalls++;
    _log?.add('media.rollback');
    if (rollbackImpl != null) {
      await rollbackImpl!();
    }
    signalingState = MediaSignalingState.stable;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _log?.add('media.stop');
    if (stopImpl != null) {
      await stopImpl!();
    }
  }

  void emit(MediaEvent event) => _events.add(event);

  void emitError(Object error, [StackTrace? stackTrace]) =>
      _events.addError(error, stackTrace ?? StackTrace.current);

  Future<void> close() => _events.close();
}

/// A [ReconnectPolicy] driven by a fixed script of decisions instead of
/// real backoff math, so recovery tests are exact rather than randomized.
/// Once the script is exhausted, the last decision repeats indefinitely
/// (so a single `[retry]` script can drive multiple recovery cycles).
final class ScriptedReconnectPolicy implements ReconnectPolicy {
  ScriptedReconnectPolicy(this.decisions)
    : assert(decisions.isNotEmpty, 'ScriptedReconnectPolicy needs >=1 entry');

  final List<ReconnectDecision> decisions;
  final List<ReconnectContext> contexts = <ReconnectContext>[];

  @override
  ReconnectDecision evaluate(ReconnectContext context) {
    contexts.add(context);
    final index = contexts.length - 1;
    return decisions[index < decisions.length ? index : decisions.length - 1];
  }
}

/// A [ReconnectPolicy] that always throws, for exercising the
/// "invalid_reconnect_policy" failure path.
final class ThrowingReconnectPolicy implements ReconnectPolicy {
  @override
  ReconnectDecision evaluate(ReconnectContext context) {
    throw StateError('policy exploded');
  }
}
