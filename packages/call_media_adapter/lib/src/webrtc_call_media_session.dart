/// `call_core`'s [CallMediaSession] over `media_webrtc`'s
/// [mw.PeerConnectionPort].
///
/// `call_core` and `media_webrtc` are deliberately independent type
/// systems; this adapter is where they meet (the media twin of
/// `call_signaling_adapter`). It is pure mapping/delegation — no policy
/// logic:
/// - port [mw.PeerConnectionStatus] stream -> [MediaConnectionChangedEvent];
/// - port local candidates -> [LocalIceCandidateEvent];
/// - offer/answer/description/candidate calls delegate 1:1 with type
///   conversion between the two `IceCandidate`/description classes.
///
/// [MediaSignalingState] is tracked locally from the set-description calls
/// (the port contract does not expose the platform signaling state), which
/// is exactly the state `call_core` needs for its glare handling.
///
/// Rollback: the pure port contract has no rollback (its `SdpDescription`
/// only admits offer/answer), so the platform-specific rollback is an
/// injectable [NativeRollback] seam — the app passes the concrete
/// platform port's rollback there; without it (test fakes, adapters with
/// no such operation) [WebRtcCallMediaSession.rollback] only resets the
/// tracked signaling state (documented port-contract gap workaround).
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;

/// Builds the port when the call starts (so e.g. the microphone permission
/// prompt happens at call time, not app launch).
typedef PortFactory = Future<mw.PeerConnectionPort> Function();

/// Platform-specific local-description rollback, injected by the
/// composition layer that knows the concrete port type.
typedef NativeRollback = Future<void> Function(mw.PeerConnectionPort port);

class WebRtcCallMediaSession implements CallMediaSession {
  WebRtcCallMediaSession(
    this._portFactory, {
    NativeRollback? nativeRollback,
    List<mw.DataChannelConfig> preOpenChannels = const [],
  }) : _nativeRollback = nativeRollback,
       _preOpenChannels = List<mw.DataChannelConfig>.unmodifiable(
         preOpenChannels,
       ) {
    final ids = <int>{};
    for (final config in _preOpenChannels) {
      config.validate();
      if (!ids.add(config.negotiatedId)) {
        throw ArgumentError.value(
          preOpenChannels,
          'preOpenChannels',
          'negotiated id ${config.negotiatedId} listed twice',
        );
      }
    }
  }

  final PortFactory _portFactory;
  final NativeRollback? _nativeRollback;

  /// Negotiated channels created the moment the port exists — BEFORE the
  /// first offer or answer — so the very first SDP carries the application
  /// section and SCTP comes up with the call. A channel created after an
  /// audio-only offer has no transport until a full renegotiation round
  /// trip (measured: messaging_survival_test had to request recovery to
  /// bring the lane up mid-call). Both peers list the same configs.
  final List<mw.DataChannelConfig> _preOpenChannels;

  /// One channel object per negotiated id for the port's lifetime. A
  /// negotiated id is one SCTP stream; creating it twice would hand two
  /// consumers two objects over the same stream, so [openDataChannel]
  /// returns the existing object for an id already open.
  final Map<int, mw.MediaDataChannel> _channels = <int, mw.MediaDataChannel>{};

  /// Completes once [start] has a port (or once [stop] gives up on one),
  /// so a lane can be requested the moment a session handle exists —
  /// before the controller's own start reached the media engine.
  final Completer<void> _started = Completer<void>();

  final _events = StreamController<MediaEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];

  mw.PeerConnectionPort? _port;
  MediaConnectionState _connectionState = MediaConnectionState.newConnection;
  MediaSignalingState _signalingState = MediaSignalingState.stable;
  bool _stopped = false;

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  MediaConnectionState get connectionState => _connectionState;

  @override
  MediaSignalingState get signalingState => _signalingState;

  @override
  Future<void> start() async {
    if (_stopped) {
      throw StateError('WebRtcCallMediaSession has been stopped.');
    }
    if (_port != null) return;
    final port = await _portFactory();
    if (_stopped) {
      // stop() ran while the factory was in flight (an end preempted the
      // start): close the late port instead of leaking it — the capture
      // it opened must not outlive a call that already ended.
      await port.close();
      throw StateError('WebRtcCallMediaSession was stopped during start.');
    }
    _port = port;
    _connectionState = MediaConnectionState.connecting;

    _subscriptions.add(
      port.connectionStatus.listen((status) {
        _connectionState = _mapStatus(status);
        _emit(MediaConnectionChangedEvent(_connectionState));
      }),
    );
    _subscriptions.add(
      port.localCandidates.listen((candidate) {
        _emit(
          LocalIceCandidateEvent(
            IceCandidate(
              candidate: candidate.candidate,
              sdpMid: candidate.sdpMid,
              sdpMLineIndex: candidate.sdpMLineIndex,
            ),
          ),
        );
      }),
    );
    for (final config in _preOpenChannels) {
      _channels[config.negotiatedId] = await port.createDataChannel(config);
    }
    if (!_started.isCompleted) _started.complete();
  }

  @override
  Future<SessionDescription> createOffer({required bool iceRestart}) async {
    final offer = await _requirePort().createOffer(iceRestart: iceRestart);
    return _toSessionDescription(offer);
  }

  @override
  Future<SessionDescription> createAnswer() async {
    final answer = await _requirePort().createAnswer();
    return _toSessionDescription(answer);
  }

  @override
  Future<void> setLocalDescription(SessionDescription description) async {
    await _requirePort().setLocalDescription(_toSdpDescription(description));
    _signalingState = switch (description.type) {
      SessionDescriptionType.offer => MediaSignalingState.haveLocalOffer,
      SessionDescriptionType.answer => MediaSignalingState.stable,
    };
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    await _requirePort().setRemoteDescription(_toSdpDescription(description));
    _signalingState = switch (description.type) {
      SessionDescriptionType.offer => MediaSignalingState.haveRemoteOffer,
      SessionDescriptionType.answer => MediaSignalingState.stable,
    };
  }

  @override
  Future<void> addRemoteIceCandidate(IceCandidate candidate) async {
    final line = candidate.candidate;
    // End-of-candidates markers (null line) have no equivalent in the pure
    // port type; dropping them is safe (trickle ICE needs no terminator).
    if (line == null) return;
    await _requirePort().addRemoteCandidate(
      mw.IceCandidate(
        candidate: line,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ),
    );
  }

  /// Opens the call's NEGOTIATED application data channel (chat/attachments
  /// ride the call's own DTLS transport). Both peers must call this with an
  /// identical [config] — that is the negotiated-mode contract. Requires
  /// [start]; the returned channel reports open once the transport is up.
  ///
  /// Memoized per negotiated id: a lane pre-opened at [start] (or opened
  /// once here) is returned as the same object on every later call, so
  /// several consumers of one lane share one stream instead of racing
  /// duplicate channel objects over it.
  ///
  /// Called before [start] finished, it WAITS for the port (the app asks
  /// for its chat lanes as soon as a session exists); after [stop] it
  /// throws [StateError].
  Future<mw.MediaDataChannel> openDataChannel([
    mw.DataChannelConfig config = const mw.DataChannelConfig(),
  ]) async {
    if (_port == null && !_stopped) await _started.future;
    final port = _requirePort();
    final existing = _channels[config.negotiatedId];
    if (existing != null) return existing;
    final channel = await port.createDataChannel(config);
    return _channels.putIfAbsent(config.negotiatedId, () => channel);
  }

  @override
  Future<void> rollback() async {
    final port = _requirePort();
    await _nativeRollback?.call(port);
    _signalingState = MediaSignalingState.stable;
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _connectionState = MediaConnectionState.closed;
    _signalingState = MediaSignalingState.closed;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _channels.clear();
    await _port?.close();
    _port = null;
    // Release anyone waiting for a port that will never come; they fall
    // through to _requirePort and get the StateError.
    if (!_started.isCompleted) _started.complete();
    await _events.close();
  }

  mw.PeerConnectionPort _requirePort() {
    final port = _port;
    if (port == null || _stopped) {
      throw StateError('Media session is not started.');
    }
    return port;
  }

  void _emit(MediaEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static MediaConnectionState _mapStatus(mw.PeerConnectionStatus status) {
    switch (status) {
      case mw.PeerConnectionStatus.connecting:
        return MediaConnectionState.connecting;
      case mw.PeerConnectionStatus.connected:
        return MediaConnectionState.connected;
      case mw.PeerConnectionStatus.disconnected:
        return MediaConnectionState.disconnected;
      case mw.PeerConnectionStatus.failed:
        return MediaConnectionState.failed;
      case mw.PeerConnectionStatus.closed:
        return MediaConnectionState.closed;
    }
  }

  static SessionDescription _toSessionDescription(mw.SdpDescription sdp) {
    return SessionDescription(
      type: sdp.type == 'offer'
          ? SessionDescriptionType.offer
          : SessionDescriptionType.answer,
      sdp: sdp.sdp,
    );
  }

  static mw.SdpDescription _toSdpDescription(SessionDescription description) {
    return mw.SdpDescription(type: description.type.name, sdp: description.sdp);
  }
}
