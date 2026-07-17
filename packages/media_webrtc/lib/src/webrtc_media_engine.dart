/// WebRTC media engine.
///
/// Owns the standards-based media session for one call:
/// - drives the platform peer connection (offer/answer, trickle ICE,
///   ICE restart) through the [PeerConnectionPort] abstraction;
/// - encryption is WebRTC's native DTLS-SRTP — this engine adds no custom
///   crypto and no transport tricks;
/// - wires [RtcStatsSampler] to [AdaptiveMediaPolicy] and applies profile
///   changes through standard sender-parameter updates;
/// - reports connection quality events upward to the call controller.
///
/// The [PeerConnectionPort] indirection keeps this package free of a direct
/// plugin dependency: the app supplies an adapter over `flutter_webrtc` (or
/// any binding), and tests supply fakes.
///
/// Designed from the v2 blueprint role (no v1 equivalent; the v1 kit had
/// no media layer).
library;

import 'dart:async';

import 'adaptive_media_policy.dart';
import 'rtc_stats_sampler.dart';

/// Subset of `RTCPeerConnectionState` the engine reacts to.
enum PeerConnectionStatus {
  connecting,
  connected,
  disconnected,
  failed,
  closed,
}

class SdpDescription {
  /// 'offer' or 'answer'.
  final String type;
  final String sdp;

  SdpDescription({required this.type, required this.sdp}) {
    if (type != 'offer' && type != 'answer') {
      throw ArgumentError.value(type, 'type', "must be 'offer' or 'answer'");
    }
    if (sdp.isEmpty) {
      throw ArgumentError.value('', 'sdp', 'must not be empty');
    }
  }
}

class IceCandidate {
  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  const IceCandidate({
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });
}

/// Video sender knobs applied via standard `RTCRtpSender.setParameters`.
class VideoSenderParameters {
  final bool enabled;
  final int maxBitrateBps;
  final int maxFramerate;
  final double scaleResolutionDownBy;

  const VideoSenderParameters({
    required this.enabled,
    required this.maxBitrateBps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
  });
}

/// Platform adapter over a real peer connection (DTLS-SRTP is handled by
/// the platform WebRTC stack).
abstract interface class PeerConnectionPort {
  Stream<PeerConnectionStatus> get connectionStatus;
  Stream<IceCandidate> get localCandidates;

  Future<SdpDescription> createOffer({required bool iceRestart});
  Future<SdpDescription> createAnswer();
  Future<void> setLocalDescription(SdpDescription description);
  Future<void> setRemoteDescription(SdpDescription description);
  Future<void> addRemoteCandidate(IceCandidate candidate);

  Future<void> setVideoSenderParameters(VideoSenderParameters parameters);
  Future<void> setAudioMaxBitrate(int bitrateBps);

  /// Reads cumulative counters from the platform stats report.
  Future<RawRtcCounters?> readStatsCounters();

  Future<void> close();
}

/// Events the engine surfaces to the call controller / UI.
sealed class MediaEngineEvent {
  const MediaEngineEvent();
}

class MediaConnectionChanged extends MediaEngineEvent {
  final PeerConnectionStatus status;
  const MediaConnectionChanged(this.status);
}

class MediaProfileChanged extends MediaEngineEvent {
  final MediaPolicyDecision decision;
  const MediaProfileChanged(this.decision);
}

class MediaStatsUpdated extends MediaEngineEvent {
  final RtcStatsSample sample;
  const MediaStatsUpdated(this.sample);
}

class WebRtcMediaEngine {
  final PeerConnectionPort _port;
  final AdaptiveMediaPolicy _policy;
  late final RtcStatsSampler _sampler;

  final _eventsController = StreamController<MediaEngineEvent>.broadcast();
  final _outgoingCandidates = StreamController<IceCandidate>.broadcast();

  StreamSubscription<PeerConnectionStatus>? _statusSubscription;
  StreamSubscription<IceCandidate>? _candidateSubscription;
  StreamSubscription<RtcStatsSample>? _sampleSubscription;

  /// Candidates that arrived before the remote description was applied.
  final List<IceCandidate> _pendingRemoteCandidates = [];
  bool _remoteDescriptionSet = false;
  bool _negotiating = false;
  bool _disposed = false;

  /// Upper bound for every negotiation-related port call. A hung platform
  /// channel must fail the operation (and release the negotiation guard via
  /// try/finally), never freeze the engine for the life of the call.
  final Duration operationTimeout;

  WebRtcMediaEngine({
    required PeerConnectionPort port,
    AdaptiveMediaPolicy? policy,
    Duration statsInterval = const Duration(seconds: 2),
    this.operationTimeout = const Duration(seconds: 15),
  }) : _port = port,
       _policy = policy ?? AdaptiveMediaPolicy() {
    if (operationTimeout <= Duration.zero) {
      throw ArgumentError.value(operationTimeout, 'operationTimeout');
    }
    _sampler = RtcStatsSampler(
      reader: _port.readStatsCounters,
      interval: statsInterval,
    );

    _statusSubscription = _port.connectionStatus.listen(_onStatus);
    _candidateSubscription = _port.localCandidates.listen((candidate) {
      if (!_outgoingCandidates.isClosed) {
        _outgoingCandidates.add(candidate);
      }
    });
    _sampleSubscription = _sampler.samples.listen(_onSample);
  }

  /// Engine events for the call controller and diagnostics UI.
  Stream<MediaEngineEvent> get events => _eventsController.stream;

  /// Trickled local ICE candidates; the call layer forwards these over
  /// signaling.
  Stream<IceCandidate> get outgoingCandidates => _outgoingCandidates.stream;

  MediaProfile get currentProfile => _policy.profile;

  // ---------------------------------------------------------------------
  // Negotiation
  // ---------------------------------------------------------------------

  /// Creates and applies a local offer; the caller sends it over signaling.
  Future<SdpDescription> startOffer({bool iceRestart = false}) async {
    _ensureUsable();
    if (_negotiating) {
      throw StateError('Negotiation already in progress.');
    }
    _negotiating = true;
    try {
      final offer = await _bounded(
        _port.createOffer(iceRestart: iceRestart),
        'create offer',
      );
      await _bounded(_port.setLocalDescription(offer), 'set local offer');
      return offer;
    } finally {
      _negotiating = false;
    }
  }

  /// Bounds a port operation with [operationTimeout].
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

  /// Handles a remote offer and produces the local answer.
  Future<SdpDescription> acceptOffer(SdpDescription remoteOffer) async {
    _ensureUsable();
    if (remoteOffer.type != 'offer') {
      throw ArgumentError.value(remoteOffer.type, 'remoteOffer.type');
    }
    await _applyRemoteDescription(remoteOffer);
    final answer = await _bounded(_port.createAnswer(), 'create answer');
    await _bounded(_port.setLocalDescription(answer), 'set local answer');
    return answer;
  }

  /// Applies the remote answer to a previously sent offer.
  Future<void> acceptAnswer(SdpDescription remoteAnswer) async {
    _ensureUsable();
    if (remoteAnswer.type != 'answer') {
      throw ArgumentError.value(remoteAnswer.type, 'remoteAnswer.type');
    }
    await _applyRemoteDescription(remoteAnswer);
  }

  Future<void> _applyRemoteDescription(SdpDescription description) async {
    await _bounded(
      _port.setRemoteDescription(description),
      'set remote description',
    );
    _remoteDescriptionSet = true;
    for (final candidate in _pendingRemoteCandidates) {
      await _bounded(
        _port.addRemoteCandidate(candidate),
        'apply buffered remote candidate',
      );
    }
    _pendingRemoteCandidates.clear();
  }

  /// Adds a trickled remote candidate; buffers it when it arrives before
  /// the remote description (a normal race over slow signaling).
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    _ensureUsable();
    if (!_remoteDescriptionSet) {
      _pendingRemoteCandidates.add(candidate);
      return;
    }
    await _bounded(_port.addRemoteCandidate(candidate), 'add remote candidate');
  }

  /// Performs a standards-based ICE restart (invoked by the reconnect
  /// policy in `call_core`). Returns the restart offer to send over
  /// signaling.
  Future<SdpDescription> restartIce() async {
    _ensureUsable();
    _policy.reset();
    return startOffer(iceRestart: true);
  }

  // ---------------------------------------------------------------------
  // Adaptation
  // ---------------------------------------------------------------------

  void _onStatus(PeerConnectionStatus status) {
    if (_eventsController.isClosed) return;
    _eventsController.add(MediaConnectionChanged(status));
    switch (status) {
      case PeerConnectionStatus.connected:
        _sampler.start();
      case PeerConnectionStatus.failed:
      case PeerConnectionStatus.closed:
        _sampler.stop();
      case PeerConnectionStatus.connecting:
      case PeerConnectionStatus.disconnected:
        break;
    }
  }

  Future<void> _onSample(RtcStatsSample sample) async {
    if (_eventsController.isClosed) return;
    _eventsController.add(MediaStatsUpdated(sample));

    final decision = _policy.onSample(sample);
    if (decision == null) return;

    final p = decision.parameters;
    try {
      await _port.setVideoSenderParameters(
        VideoSenderParameters(
          enabled: p.videoEnabled,
          maxBitrateBps: p.videoMaxBitrateBps,
          maxFramerate: p.videoMaxFramerate,
          scaleResolutionDownBy: p.videoScaleResolutionDownBy,
        ),
      );
      await _port.setAudioMaxBitrate(p.audioMaxBitrateBps);
      if (!_eventsController.isClosed) {
        _eventsController.add(MediaProfileChanged(decision));
      }
    } catch (_) {
      // Parameter application can fail transiently mid-renegotiation; the
      // next decision will retry. Never let it kill the sample loop.
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('Media engine has been disposed.');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _statusSubscription?.cancel();
    await _candidateSubscription?.cancel();
    await _sampleSubscription?.cancel();
    await _sampler.dispose();
    await _port.close();
    await _eventsController.close();
    await _outgoingCandidates.close();
  }
}
