/// A [CallMediaSession] fake that behaves like a real handshake instead of
/// a timer: it watches the actual offer/answer application driven by
/// [CallController] over the real signaling wire and flips to
/// [MediaConnectionState.connected] the moment its own side has finished
/// applying the exchanged descriptions — never on a `Timer`/`Future.delayed`.
///
/// [start] also emits one local ICE candidate. [SignalingRelayServer] only
/// pairs two sockets into a room once each has sent at least one frame for
/// the shared `callId` — a purely-reactive receiver (which has nothing to
/// send until it has an offer to answer) would otherwise never send
/// anything, never join the room, and never see the offer the initiator's
/// socket already has buffered there. Real WebRTC ICE gathering starts the
/// same way, independent of SDP exchange, so this mirrors production
/// behavior rather than papering over a test-only gap.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';

class HandshakingFakeMedia implements CallMediaSession {
  HandshakingFakeMedia({required this.role});

  final CallRole role;

  final StreamController<MediaEvent> _events =
      StreamController<MediaEvent>.broadcast();

  MediaConnectionState _connectionState = MediaConnectionState.newConnection;
  MediaSignalingState _signalingState = MediaSignalingState.stable;
  bool _stopped = false;
  int _sdpSequence = 0;

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  MediaConnectionState get connectionState => _connectionState;

  @override
  MediaSignalingState get signalingState => _signalingState;

  @override
  Future<void> start() async {
    if (_stopped) return;
    _connectionState = MediaConnectionState.connecting;
    _emit(
      LocalIceCandidateEvent(
        IceCandidate(
          candidate: 'candidate:1 1 UDP 2122260223 127.0.0.1 51000 typ host',
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      ),
    );
  }

  @override
  Future<SessionDescription> createOffer({required bool iceRestart}) async {
    return SessionDescription(
      type: SessionDescriptionType.offer,
      sdp: _fakeSdp('offer'),
    );
  }

  @override
  Future<SessionDescription> createAnswer() async {
    return SessionDescription(
      type: SessionDescriptionType.answer,
      sdp: _fakeSdp('answer'),
    );
  }

  @override
  Future<void> setLocalDescription(SessionDescription description) async {
    switch (description.type) {
      case SessionDescriptionType.offer:
        _signalingState = MediaSignalingState.haveLocalOffer;
      case SessionDescriptionType.answer:
        _signalingState = MediaSignalingState.stable;
        // The receiver completes the handshake by applying its own answer
        // locally — unlike the initiator it gets no further wire
        // confirmation, matching a real ICE agent that is ready to send
        // the moment its local description is set.
        _markConnected();
    }
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    switch (description.type) {
      case SessionDescriptionType.offer:
        _signalingState = MediaSignalingState.haveRemoteOffer;
      case SessionDescriptionType.answer:
        _signalingState = MediaSignalingState.stable;
        // The initiator completes the handshake here: it just applied the
        // answer it received over the real wire from the other side.
        _markConnected();
    }
  }

  @override
  Future<void> addRemoteIceCandidate(IceCandidate candidate) async {}

  @override
  Future<void> rollback() async {
    _signalingState = MediaSignalingState.stable;
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _connectionState = MediaConnectionState.closed;
    await _events.close();
  }

  void _markConnected() {
    if (_stopped || _connectionState == MediaConnectionState.connected) {
      return;
    }
    _connectionState = MediaConnectionState.connected;
    _emit(const MediaConnectionChangedEvent(MediaConnectionState.connected));
  }

  void _emit(MediaEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  String _fakeSdp(String kind) {
    _sdpSequence++;
    return 'v=0\r\n'
        'o=- $_sdpSequence $_sdpSequence IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'c=IN IP4 127.0.0.1\r\n'
        'a=fake-$kind-${role.name}\r\n';
  }
}
