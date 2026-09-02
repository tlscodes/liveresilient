/// Closes the adaptive-quality loop ON THE LIVE CALL: samples the live
/// peer connection's RTC stats ([RtcStatsSampler]) into the tested
/// [AdaptiveMediaPolicy] ladder, and applies each decision through the
/// port's standard sender-parameter updates — so under rising loss/RTT the
/// session steps down bitrate → frame rate → resolution → audio-only, and
/// recovers (slow-up hysteresis) when conditions improve.
///
/// media_webrtc's own `WebRtcMediaEngine` already closes this loop for
/// engine-driven sessions, but the production call path drives the port
/// through call_core + call_media_adapter and bypasses the engine — this
/// driver is that path's adaptation half, mirroring the engine's
/// sample-coalescing rules.
library;

import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';

/// Drives [AdaptiveMediaPolicy] from live stats and applies its decisions.
class MediaAdaptationDriver {
  MediaAdaptationDriver({
    required this._port,
    AdaptiveMediaPolicy? policy,
    Duration statsInterval = const Duration(seconds: 2),
    int Function()? nowMs,
    this.audioCeilingBps,
  }) : _policy = policy ?? AdaptiveMediaPolicy() {
    _sampler = RtcStatsSampler(
      reader: () async => _port()?.readStatsCounters(),
      interval: statsInterval,
      nowMs: nowMs,
    );
    _subscription = _sampler.samples.listen(_onSample);
  }

  final PeerConnectionPort? Function() _port;

  /// Link-derived audio ceiling (`OpusWireBudget.opusRateBps`): every rung's
  /// audio bitrate is capped here so the ladder can never re-saturate a
  /// link whose capacity is known. Null = unknown link, rungs apply as-is.
  final int? audioCeilingBps;
  final AdaptiveMediaPolicy _policy;
  late final RtcStatsSampler _sampler;
  late final StreamSubscription<RtcStatsSample> _subscription;
  final _decisions = StreamController<MediaPolicyDecision>.broadcast();

  bool _applying = false;
  RtcStatsSample? _queued;
  bool _disposed = false;

  /// Every applied profile change, in order.
  Stream<MediaPolicyDecision> get decisions => _decisions.stream;

  /// The live stats behind those decisions: loss, round-trip time and
  /// throughput read from the peer connection, EWMA-smoothed by the sampler.
  ///
  /// Exposed so the UI can show what the ladder is reacting to. Until this
  /// existed the call screen's gauge was fed by a scripted demo profile while
  /// these real numbers were computed a stream away and discarded.
  Stream<RtcStatsSample> get samples => _sampler.samples;

  /// The ladder position the policy currently recommends.
  MediaProfile get profile => _policy.profile;

  /// Starts sampling. Called when the call enters its connected phase;
  /// hysteresis counters reset because a (re)connected call rides a fresh
  /// path — the profile itself is kept, so a call that degraded before a
  /// reconnect re-joins at the degraded level and earns its way back up.
  void start() {
    if (_disposed) return;
    _policy.reset();
    // Apply the link-derived ceiling BEFORE damage is measured: the lesson
    // of the 32 kbit/s row was that waiting for loss/RTT evidence means the
    // control plane is already starving. Fire-and-forget with the same
    // swallow rule as decisions — a transient failure must not kill start.
    final ceiling = audioCeilingBps;
    final port = _port();
    if (ceiling != null && port != null) {
      // ignore: discarded_futures
      port.setAudioMaxBitrate(ceiling).catchError((_) {});
    }
    _sampler.start();
  }

  /// Stops sampling (keeps the current profile for the next [start]).
  void stop() {
    _sampler.stop();
  }

  /// Immediately drops the sender to the survival floor — video off, audio
  /// at the lowRateVoice budget (capped by [audioCeilingBps]) — WITHOUT
  /// waiting for stats evidence.
  ///
  /// Called when the call enters recovery: the ICE-restart handshake must
  /// cross the same constrained pipe the still-flowing RTP occupies, and
  /// measured 2026-08-06 (T2 bandwidth/narrow/extreme rows) that contention
  /// starved the restart until the call died — connect and mid-call were
  /// already healthy, every death was in the recovery phase. The profile is
  /// deliberately kept low afterwards: a recovered call re-joins at the
  /// floor and earns its way back up through the ladder's own hysteresis.
  Future<void> applySurvivalFloor() async {
    if (_disposed) return;
    _policy.reset(profile: MediaProfile.lowRateVoice);
    final port = _port();
    if (port == null) return;
    final p = MediaProfileParameters.of(MediaProfile.lowRateVoice);
    try {
      await port.setVideoSenderParameters(
        VideoSenderParameters(
          enabled: p.videoEnabled,
          maxBitrateBps: p.videoMaxBitrateBps,
          maxFramerate: p.videoMaxFramerate,
          scaleResolutionDownBy: p.videoScaleResolutionDownBy,
        ),
      );
      final ceiling = audioCeilingBps;
      await port.setAudioMaxBitrate(
        ceiling != null && ceiling < p.audioMaxBitrateBps
            ? ceiling
            : p.audioMaxBitrateBps,
      );
    } catch (_) {
      // Same swallow rule as decisions: a transient port failure mid-
      // renegotiation must not kill recovery — the floor is best-effort.
    }
  }

  Future<void> _onSample(RtcStatsSample sample) async {
    if (_applying) {
      // Coalesce to the latest sample instead of letting two decisions'
      // port calls interleave (same rule as WebRtcMediaEngine).
      _queued = sample;
      return;
    }
    _applying = true;
    try {
      await _applyDecisionFor(sample);
      while (true) {
        final queued = _queued;
        if (queued == null) break;
        _queued = null;
        await _applyDecisionFor(queued);
      }
    } finally {
      _applying = false;
    }
  }

  Future<void> _applyDecisionFor(RtcStatsSample sample) async {
    final decision = _policy.onSample(sample);
    if (decision == null) return;
    final port = _port();
    if (port == null) return;
    final p = decision.parameters;
    try {
      await port.setVideoSenderParameters(
        VideoSenderParameters(
          enabled: p.videoEnabled,
          maxBitrateBps: p.videoMaxBitrateBps,
          maxFramerate: p.videoMaxFramerate,
          scaleResolutionDownBy: p.videoScaleResolutionDownBy,
        ),
      );
      final ceiling = audioCeilingBps;
      await port.setAudioMaxBitrate(
        ceiling != null && ceiling < p.audioMaxBitrateBps
            ? ceiling
            : p.audioMaxBitrateBps,
      );
      if (!_decisions.isClosed) {
        _decisions.add(decision);
      }
    } catch (_) {
      // Transient failures (mid-renegotiation, hung channel) must never
      // kill the sample loop; the next decision retries.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop(); // Synchronously kill the poll timer before any await.
    await _subscription.cancel();
    await _sampler.dispose();
    await _decisions.close();
  }
}
