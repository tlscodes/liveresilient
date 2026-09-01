/// Real [PeerConnectionPort] over the `flutter_webrtc` plugin.
///
/// This is the thin platform adapter the pure-Dart `media_webrtc` package
/// was designed around: it maps each port call 1:1 onto the plugin API and
/// carries ZERO policy logic (adaptation, sampling cadence, negotiation
/// serialization all live in `media_webrtc` / `call_core`).
///
/// Port-method -> flutter_webrtc mapping:
///
/// | PeerConnectionPort              | flutter_webrtc                        |
/// |---------------------------------|---------------------------------------|
/// | connectionStatus                | RTCPeerConnection.onConnectionState   |
/// | localCandidates                 | RTCPeerConnection.onIceCandidate      |
/// | createOffer(iceRestart)         | pc.createOffer (mandatory IceRestart) |
/// | createAnswer()                  | pc.createAnswer()                     |
/// | setLocalDescription             | pc.setLocalDescription               |
/// | setRemoteDescription            | pc.setRemoteDescription              |
/// | addRemoteCandidate              | pc.addCandidate                       |
/// | setVideoSenderParameters        | video RTCRtpSender.setParameters +    |
/// |                                 | MediaStreamTrack.enabled              |
/// | setAudioMaxBitrate              | audio RTCRtpSender.setParameters      |
/// | readStatsCounters               | pc.getStats() (standard stats)        |
/// | createDataChannel               | pc.createDataChannel (negotiated,     |
/// |                                 | binary) -> FlutterWebRtcDataChannel   |
/// | close                           | pc.close + pc.dispose + track stop    |
///
/// Stats-counter mapping (standard W3C stats passed through unmodified by
/// the darwin plugin's stats bridge; units verified against the
/// webrtc-stats spec, which `flutter_webrtc` does not rescale):
///
/// | RawRtcCounters field            | stats report source        | unit    |
/// |---------------------------------|----------------------------|---------|
/// | packetsReceived                 | sum inbound-rtp            | packets |
/// | packetsLost                     | sum inbound-rtp            | packets |
/// | packetsSent                     | sum outbound-rtp           | packets |
/// | bytesReceived                   | sum inbound-rtp            | bytes   |
/// | bytesSent                       | sum outbound-rtp           | bytes   |
/// | jitterSeconds                   | inbound-rtp `jitter`       | seconds |
/// |                                 | (audio preferred)          |         |
/// | currentRoundTripTimeSeconds     | selected candidate-pair    | seconds |
/// |                                 | `currentRoundTripTime`     |         |
/// | availableOutgoingBitrateBps     | selected candidate-pair    | bit/s   |
/// |                                 | `availableOutgoingBitrate` |         |
///
/// The selected candidate pair is resolved via the `transport` report's
/// `selectedCandidatePairId` when present, falling back to the
/// `candidate-pair` report flagged `selected`/`nominated`+`succeeded`.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc/media_webrtc.dart';

import 'flutter_webrtc_data_channel.dart';

/// [rtc.RTCDataChannelInit] whose [toMap] can express `maxRetransmits: 0`.
///
/// Upstream (webrtc_interface 1.5.1, rtc_data_channel.dart:20) emits the key
/// only `if (maxRetransmits > 0)`, so ZERO — the fully-unreliable setting the
/// fountain video lane's hard precondition requires — is silently dropped and
/// the platform builds a RELIABLE channel: SCTP then retransmits underneath
/// and rebuilds the exact loss-collapse that lane exists to escape. The
/// darwin plugin reads the `maxRetransmits` map key verbatim when present.
/// This override re-adds the key whenever the field was set (>= 0); it also
/// still sets the base field, so platforms that read the field rather than
/// the map stay correct. If upstream ever fixes the `> 0` filter this
/// becomes a harmless duplicate assignment, not a double emit.
final class RetransmitCapDataChannelInit extends rtc.RTCDataChannelInit {
  @override
  Map<String, dynamic> toMap() {
    final map = super.toMap();
    if (maxRetransmits >= 0) map['maxRetransmits'] = maxRetransmits;
    return map;
  }
}

final class FlutterWebRtcPeerConnectionPort implements PeerConnectionPort {
  FlutterWebRtcPeerConnectionPort._(
    this._pc,
    this._localStream, [
    this._opusPolicy,
  ]) {
    _pc.onConnectionState = (rtc.RTCPeerConnectionState state) {
      final mapped = mapConnectionState(state);
      if (mapped != null && !_statusController.isClosed) {
        _statusController.add(mapped);
      }
    };
    _pc.onIceCandidate = (rtc.RTCIceCandidate candidate) {
      final line = candidate.candidate;
      // A null/empty candidate line is the end-of-gathering marker; the
      // pure-Dart IceCandidate type requires a real candidate line.
      if (line == null || line.isEmpty) return;
      if (_candidatesController.isClosed) return;
      _candidatesController.add(
        IceCandidate(
          candidate: line,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
  }

  /// The config handed to `createPeerConnection`, as a pure function so it can
  /// be asserted in a unit test — `createPeerConnection` itself needs a device.
  static Map<String, dynamic> buildPeerConnectionConfig({
    List<Map<String, Object>> iceServers = const [],
    String iceTransportPolicy = 'all',
  }) => <String, dynamic>{
    'iceServers': iceServers,
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': iceTransportPolicy,
  };

  /// Creates the underlying [rtc.RTCPeerConnection], captures local media
  /// via `getUserMedia`, and adds the tracks as senders.
  ///
  /// The reference app is audio-first ([video] defaults to false); when no
  /// video sender exists, [setVideoSenderParameters] degrades to a no-op.
  ///
  /// [opusPolicy] applies the Opus fmtp knobs to every local description; null
  /// keeps the stack's own defaults.
  static Future<FlutterWebRtcPeerConnectionPort> create({
    List<Map<String, Object>> iceServers = const [],
    String iceTransportPolicy = 'all',
    OpusSdpPolicy? opusPolicy,
    bool audio = true,
    bool video = false,
  }) async {
    final pc = await rtc.createPeerConnection(
      buildPeerConnectionConfig(
        iceServers: iceServers,
        iceTransportPolicy: iceTransportPolicy,
      ),
    );
    rtc.MediaStream? stream;
    if (audio || video) {
      try {
        stream = await rtc.navigator.mediaDevices.getUserMedia(
          <String, dynamic>{'audio': audio, 'video': video},
        );
        for (final track in stream.getTracks()) {
          await pc.addTrack(track, stream);
        }
      } catch (_) {
        // getUserMedia succeeded but a later step (addTrack) failed: the
        // captured stream is a live camera/microphone handle and must be
        // released, not just the peer connection. Guarded in its own
        // try/catch so a failing stream cleanup cannot mask the original
        // error via rethrow below.
        try {
          final capturedStream = stream;
          if (capturedStream != null) {
            for (final track in capturedStream.getTracks()) {
              await track.stop();
            }
            await capturedStream.dispose();
          }
        } catch (_) {
          // Best-effort cleanup; the original failure is what gets rethrown.
        }
        await pc.close();
        await pc.dispose();
        rethrow;
      }
    }
    return FlutterWebRtcPeerConnectionPort._(pc, stream, opusPolicy);
  }

  final rtc.RTCPeerConnection _pc;
  final rtc.MediaStream? _localStream;

  /// Opus fmtp knobs applied to every local description. Null means the stack's
  /// own defaults, which is what every existing caller gets.
  final OpusSdpPolicy? _opusPolicy;

  final _statusController = StreamController<PeerConnectionStatus>.broadcast();
  final _candidatesController = StreamController<IceCandidate>.broadcast();
  bool _closed = false;

  @override
  Stream<PeerConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidatesController.stream;

  @override
  Future<SdpDescription> createOffer({required bool iceRestart}) async {
    _ensureOpen();
    // Passing no constraints keeps the plugin's defaults
    // (OfferToReceiveAudio/Video); an ICE restart adds the standard
    // mandatory `IceRestart` constraint on top of them.
    final description = iceRestart
        ? await _pc.createOffer(<String, dynamic>{
            'mandatory': <String, dynamic>{
              'OfferToReceiveAudio': true,
              'OfferToReceiveVideo': true,
              'IceRestart': true,
            },
            'optional': <dynamic>[],
          })
        : await _pc.createOffer();
    return _toSdpDescription(description, expectedType: 'offer');
  }

  @override
  Future<SdpDescription> createAnswer() async {
    _ensureOpen();
    final description = await _pc.createAnswer();
    return _toSdpDescription(description, expectedType: 'answer');
  }

  @override
  Future<void> setLocalDescription(SdpDescription description) async {
    _ensureOpen();
    // Safety net: descriptions normally arrive here already transformed by
    // _toSdpDescription (createOffer/createAnswer), and the transform is a
    // fixpoint, so re-application is a no-op. This catches descriptions a
    // caller constructed some other way. Remote descriptions are never
    // touched — what the far end sent is what the far end wants. A rollback
    // carries no SDP to edit.
    final policy = _opusPolicy;
    final sdp =
        (policy == null || policy.isNoop || description.type == 'rollback')
        ? description.sdp
        : applyOpusPolicy(description.sdp, policy);
    await _pc.setLocalDescription(
      rtc.RTCSessionDescription(sdp, description.type),
    );
  }

  @override
  Future<void> setRemoteDescription(SdpDescription description) async {
    _ensureOpen();
    await _pc.setRemoteDescription(
      rtc.RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    _ensureOpen();
    await _pc.addCandidate(
      rtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  /// Rolls the local description back to stable.
  ///
  /// NOT part of [PeerConnectionPort] — the pure contract's
  /// `SdpDescription` only admits offer/answer, so rollback (needed by
  /// `call_core`'s glare handling via `CallMediaSession.rollback`) is
  /// exposed as an adapter-side extra instead of changing the pure-Dart
  /// contract. The darwin plugin maps the `rollback` type string through
  /// `[RTCSessionDescription typeForString:]` to `RTCSdpTypeRollback`.
  Future<void> rollbackLocalDescription() async {
    _ensureOpen();
    await _pc.setLocalDescription(rtc.RTCSessionDescription('', 'rollback'));
  }

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {
    _ensureOpen();
    final sender = await _senderByKind('video');
    // Audio-only session: nothing to apply (documented no-op).
    if (sender == null) return;

    sender.track?.enabled = parameters.enabled;

    final rtpParameters = sender.parameters;
    final encodings = rtpParameters.encodings;
    if (encodings == null || encodings.isEmpty) {
      // Adding encodings that the platform did not report can fail native
      // setParameters (encoding-count changes are rejected); the track
      // enable/disable above still applies. Conservative no-op here.
      return;
    }
    for (final encoding in encodings) {
      encoding.active = parameters.enabled;
      encoding.maxBitrate = parameters.maxBitrateBps;
      encoding.maxFramerate = parameters.maxFramerate;
      encoding.scaleResolutionDownBy = parameters.scaleResolutionDownBy;
    }
    await sender.setParameters(rtpParameters);
  }

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {
    _ensureOpen();
    final sender = await _senderByKind('audio');
    if (sender == null) return;

    final rtpParameters = sender.parameters;
    final encodings = rtpParameters.encodings;
    if (encodings == null || encodings.isEmpty) return;
    for (final encoding in encodings) {
      encoding.maxBitrate = bitrateBps;
    }
    await sender.setParameters(rtpParameters);
  }

  @override
  Future<RawRtcCounters?> readStatsCounters() async {
    _ensureOpen();
    final reports = await _pc.getStats();
    return countersFromStats(reports);
  }

  @override
  Future<MediaDataChannel> createDataChannel(DataChannelConfig config) async {
    _ensureOpen();
    config.validate();
    final init = RetransmitCapDataChannelInit()
      ..negotiated = true
      ..id = config.negotiatedId
      ..ordered = config.ordered
      ..binaryType = 'binary';
    final cap = config.maxRetransmits;
    if (cap != null) init.maxRetransmits = cap;
    final channel = await _pc.createDataChannel(config.label, init);
    return FlutterWebRtcDataChannel(channel, config.label);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pc.onConnectionState = null;
    _pc.onIceCandidate = null;
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    await _pc.close();
    await _pc.dispose();
    await _statusController.close();
    await _candidatesController.close();
  }

  // -----------------------------------------------------------------------
  // Mapping helpers (static + visible for unit tests)
  // -----------------------------------------------------------------------

  /// Maps the plugin connection state onto the port's five-state enum.
  /// `RTCPeerConnectionStateNew` has no port equivalent (the engine only
  /// reacts to the five states) and maps to null (not emitted).
  static PeerConnectionStatus? mapConnectionState(
    rtc.RTCPeerConnectionState state,
  ) {
    switch (state) {
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew:
        return null;
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        return PeerConnectionStatus.connecting;
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return PeerConnectionStatus.connected;
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return PeerConnectionStatus.disconnected;
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return PeerConnectionStatus.failed;
      case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return PeerConnectionStatus.closed;
    }
  }

  /// Aggregates a standard stats report list into [RawRtcCounters].
  ///
  /// Returns null when the report contains no inbound-rtp and no
  /// outbound-rtp entries (peer connection not producing media stats yet),
  /// matching the [PeerConnectionPort.readStatsCounters] contract.
  static RawRtcCounters? countersFromStats(List<rtc.StatsReport> reports) {
    var packetsReceived = 0;
    var packetsLost = 0;
    var packetsSent = 0;
    var bytesReceived = 0;
    var bytesSent = 0;
    double? audioJitter;
    double? anyJitter;
    var sawInbound = false;
    var sawOutbound = false;

    String? selectedPairId;
    final candidatePairs = <String, Map<dynamic, dynamic>>{};
    Map<dynamic, dynamic>? flaggedSelectedPair;

    for (final report in reports) {
      final values = report.values;
      switch (report.type) {
        case 'inbound-rtp':
          sawInbound = true;
          packetsReceived += _asInt(values['packetsReceived']);
          packetsLost += _asInt(values['packetsLost']);
          bytesReceived += _asInt(values['bytesReceived']);
          final jitter = _asDoubleOrNull(values['jitter']);
          if (jitter != null) {
            anyJitter = jitter;
            final kind = values['kind'] ?? values['mediaType'];
            if (kind == 'audio') audioJitter = jitter;
          }
        case 'outbound-rtp':
          sawOutbound = true;
          packetsSent += _asInt(values['packetsSent']);
          bytesSent += _asInt(values['bytesSent']);
        case 'transport':
          final id = values['selectedCandidatePairId'];
          if (id is String && id.isNotEmpty) selectedPairId = id;
        case 'candidate-pair':
          candidatePairs[report.id] = values;
          final selected = values['selected'];
          final nominated = values['nominated'];
          final state = values['state'];
          if (selected == true || (nominated == true && state == 'succeeded')) {
            flaggedSelectedPair ??= values;
          }
      }
    }

    if (!sawInbound && !sawOutbound) return null;

    final selectedPair =
        (selectedPairId != null ? candidatePairs[selectedPairId] : null) ??
        flaggedSelectedPair;

    return RawRtcCounters(
      packetsReceived: packetsReceived,
      packetsLost: packetsLost,
      packetsSent: packetsSent,
      bytesReceived: bytesReceived,
      bytesSent: bytesSent,
      // Prefer the audio stream's jitter (a voice kit adapts on voice
      // quality first); fall back to any inbound jitter, then 0.
      jitterSeconds: audioJitter ?? anyJitter ?? 0.0,
      currentRoundTripTimeSeconds: selectedPair == null
          ? null
          : _asDoubleOrNull(selectedPair['currentRoundTripTime']),
      availableOutgoingBitrateBps: selectedPair == null
          ? null
          : _asDoubleOrNull(selectedPair['availableOutgoingBitrate']),
    );
  }

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

  Future<rtc.RTCRtpSender?> _senderByKind(String kind) async {
    final senders = await _pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == kind) return sender;
    }
    return null;
  }

  SdpDescription _toSdpDescription(
    rtc.RTCSessionDescription description, {
    required String expectedType,
  }) {
    final sdp = description.sdp;
    final type = description.type ?? expectedType;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('Platform returned an empty $expectedType SDP.');
    }
    // The Opus knobs are RECEIVE preferences: an encoder obeys the SDP it was
    // SENT, so the knobs only act if they travel inside the offer or answer
    // this port hands back for transmission. Applying them only at
    // setLocalDescription reaches no encoder on either side. Measured
    // 2026-08-06 (T2 `narrow`, 16 kbit/s): the transmitted offer carried no
    // ptime, both senders kept 20 ms packets, and header overhead alone
    // (320 bits x 50 pkt/s x 4 bridge crossings via the TURN hairpin) put
    // 47-89 kbit/s on a 16 kbit/s pipe — the adaptation ladder lowered the
    // PAYLOAD bitrate and the flood continued, because the flood was headers.
    final policy = _opusPolicy;
    final effective = (policy == null || policy.isNoop)
        ? sdp
        : applyOpusPolicy(sdp, policy);
    return SdpDescription(type: type, sdp: effective);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('FlutterWebRtcPeerConnectionPort has been closed.');
    }
  }

  /// Stats values cross a platform channel and may arrive as int, double,
  /// or (on some platforms) String — parse defensively.
  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static double? _asDoubleOrNull(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
