/// Deterministic impaired-network simulator for the G5 matrix tests.
///
/// Produces the cumulative [RawRtcCounters] a platform WebRTC stats report
/// would expose, derived from a parameterized impairment model driven by a
/// seeded [Random]. Everything is synchronous and wall-clock free; the
/// tests advance time exclusively through `fake_async`.
library;

import 'dart:async';
import 'dart:math';

import 'package:media_webrtc/media_webrtc.dart';

/// Impairment applied to one sampling interval ("tick").
class ImpairmentParams {
  /// Probability in [0, 1] that any given packet of the tick is lost.
  final double lossRate;

  /// Nominal one-way jitter reported by the stats source, in milliseconds.
  final int jitterMs;

  /// Nominal round-trip time reported by the stats source, in milliseconds.
  final int rttMs;

  /// Congestion-controller bandwidth estimate surfaced to the sampler;
  /// `<= 0` models a platform that does not report one (mapped to null).
  final int availableOutgoingBitrateBps;

  const ImpairmentParams({
    required this.lossRate,
    required this.jitterMs,
    required this.rttMs,
    this.availableOutgoingBitrateBps = 0,
  });
}

/// Generates a cumulative counter stream under a mutable impairment model.
///
/// Each [nextCounters] call simulates one sampling interval: it draws a
/// Bernoulli loss outcome per packet from the seeded [Random] (so the loss
/// fraction concentrates near [ImpairmentParams.lossRate] while remaining
/// realistically noisy) and advances the cumulative counters exactly like a
/// live `RTCStatsReport` would.
class ImpairedNetworkSimulator {
  final Random _random;
  final int packetsPerTick;
  final int bytesPerPacket;

  /// Current impairment; the scenario driver reassigns it between ticks
  /// (e.g. to model recovery).
  ImpairmentParams params;

  int _packetsReceived = 0;
  int _packetsLost = 0;
  int _packetsSent = 0;
  int _bytesReceived = 0;
  int _bytesSent = 0;
  int _ticksGenerated = 0;

  ImpairedNetworkSimulator({
    required int seed,
    required this.params,
    this.packetsPerTick = 1000,
    this.bytesPerPacket = 160,
  }) : assert(packetsPerTick > 0),
       assert(bytesPerPacket > 0),
       _random = Random(seed);

  /// Number of sampling intervals generated so far.
  int get ticksGenerated => _ticksGenerated;

  RawRtcCounters nextCounters() {
    var delivered = 0;
    for (var i = 0; i < packetsPerTick; i++) {
      if (_random.nextDouble() >= params.lossRate) delivered++;
    }
    final lost = packetsPerTick - delivered;

    _packetsReceived += delivered;
    _packetsLost += lost;
    _packetsSent += packetsPerTick;
    _bytesReceived += delivered * bytesPerPacket;
    _bytesSent += packetsPerTick * bytesPerPacket;
    _ticksGenerated++;

    // +/-10% multiplicative noise keeps the timing metrics realistic while
    // staying far from the policy's decision thresholds.
    double noisyMs(int baseMs) => baseMs * (0.9 + 0.2 * _random.nextDouble());

    return RawRtcCounters(
      packetsReceived: _packetsReceived,
      packetsLost: _packetsLost,
      packetsSent: _packetsSent,
      bytesReceived: _bytesReceived,
      bytesSent: _bytesSent,
      jitterSeconds: noisyMs(params.jitterMs) / 1000,
      currentRoundTripTimeSeconds: noisyMs(params.rttMs) / 1000,
      availableOutgoingBitrateBps: params.availableOutgoingBitrateBps <= 0
          ? null
          : params.availableOutgoingBitrateBps.toDouble(),
    );
  }
}

/// [PeerConnectionPort] fake whose stats polls are answered by an
/// [ImpairedNetworkSimulator]. Negotiation calls succeed trivially; the
/// matrix tests only exercise the stats -> policy -> sender-parameter path.
class SimulatedPeerConnectionPort implements PeerConnectionPort {
  final ImpairedNetworkSimulator simulator;

  final _statusController = StreamController<PeerConnectionStatus>.broadcast();
  final _candidateController = StreamController<IceCandidate>.broadcast();

  /// Every video sender parameter set applied by the engine, in order.
  final List<VideoSenderParameters> appliedVideoParameters = [];

  /// Every audio max-bitrate applied by the engine, in order.
  final List<int> appliedAudioMaxBitrates = [];

  int statsPolls = 0;

  SimulatedPeerConnectionPort(this.simulator);

  void emitStatus(PeerConnectionStatus status) {
    _statusController.add(status);
  }

  @override
  Stream<PeerConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Stream<IceCandidate> get localCandidates => _candidateController.stream;

  @override
  Future<SdpDescription> createOffer({required bool iceRestart}) async =>
      SdpDescription(type: 'offer', sdp: 'v=0 offer');

  @override
  Future<SdpDescription> createAnswer() async =>
      SdpDescription(type: 'answer', sdp: 'v=0 answer');

  @override
  Future<void> setLocalDescription(SdpDescription description) async {}

  @override
  Future<void> setRemoteDescription(SdpDescription description) async {}

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {}

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {
    appliedVideoParameters.add(parameters);
  }

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {
    appliedAudioMaxBitrates.add(bitrateBps);
  }

  @override
  Future<RawRtcCounters?> readStatsCounters() async {
    statsPolls++;
    return simulator.nextCounters();
  }

  @override
  Future<void> close() async {}

  Future<void> disposeStreams() async {
    await _statusController.close();
    await _candidateController.close();
  }
}
