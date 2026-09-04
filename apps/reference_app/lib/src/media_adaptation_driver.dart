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
import 'dart:math';

import 'package:media_webrtc/media_webrtc.dart';

/// Drives [AdaptiveMediaPolicy] from live stats and applies its decisions.
class MediaAdaptationDriver {
  MediaAdaptationDriver({
    required this._port,
    AdaptiveMediaPolicy? policy,
    Duration statsInterval = const Duration(seconds: 2),
    int Function()? nowMs,
    this.audioCeilingBps,
    OpusWireBudget? initialWireBudget,
    int concurrentStreams = 2,
    this.onRenegotiateWirePolicy,
    this.renegotiationMinInterval = const Duration(seconds: 20),
  }) : _policy = policy ?? AdaptiveMediaPolicy(),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _concurrentStreams = concurrentStreams,
       _reevaluator = OpusPolicyReevaluator(
         initialPolicy: initialWireBudget ?? OpusWireBudget.unconstrained,
         concurrentStreams: concurrentStreams,
       ) {
    _sampler = RtcStatsSampler(
      reader: () async => _port()?.readStatsCounters(),
      interval: statsInterval,
      nowMs: nowMs,
    );
    _subscription = _sampler.samples.listen(_onSample);
    _initialPtimeMs = _reevaluator.policy.ptimeMs;
  }

  final PeerConnectionPort? Function() _port;

  /// Link-derived audio ceiling (`OpusWireBudget.opusRateBps`): every rung's
  /// audio bitrate is capped here so the ladder can never re-saturate a
  /// link whose capacity is known. Null = unknown link, rungs apply as-is.
  final int? audioCeilingBps;
  final AdaptiveMediaPolicy _policy;

  /// Renegotiates the call with [policy]'s packet time — the caller updates
  /// the port's Opus SDP policy and drives the controller's recovery seam
  /// (a fresh offer/answer carries the new ptime, and the far side's
  /// encoder obeys the SDP it was sent). Null = rate changes only.
  final Future<void> Function(OpusWireBudget policy)? onRenegotiateWirePolicy;

  /// Floor between two renegotiations (each one is a reconnect cycle).
  final Duration renegotiationMinInterval;

  final int Function() _nowMs;
  final int _concurrentStreams;

  /// MID-CALL WIRE POLICY (raised 2026-09-04, app-journey rig). The app
  /// never knows the link when a call starts, so it negotiates the ladder's
  /// default: 32 kbit/s Opus at 20 ms packets. On a 32 kbit/s link the
  /// HEADERS of 50 packets/s (~16 kbit/s per direction) plus payload
  /// oversubscribed the pipe before a single chat byte was sent: 1.9 s
  /// round trips, 16-20 % loss, survival mode — and the ladder's bitrate
  /// cuts could not help, because the flood was packets, not bits.
  /// media_webrtc's [OpusPolicyReevaluator] answers the mid-call question
  /// (rate follows every sample; ptime only after a dwell) and had no
  /// caller. Now every stats sample's available-outgoing estimate feeds
  /// it: a rate change is an encoder parameter (applied here), a ptime
  /// change is a renegotiation ([onRenegotiateWirePolicy]).
  final OpusPolicyReevaluator _reevaluator;

  /// The packet time the call was negotiated with. Captured in the
  /// constructor, not lazily: the re-evaluator's policy has already moved
  /// to the admitted one by the time a renegotiation is judged against it.
  late final int _initialPtimeMs;
  final _wireDecisions = StreamController<OpusPolicyDecision>.broadcast();
  int? _wireCeilingBps;
  int? _negotiatedPtimeMs;
  int? _lastRenegotiationMs;
  int? _lastAppliedAudioBps;
  late final RtcStatsSampler _sampler;
  late final StreamSubscription<RtcStatsSample> _subscription;
  final _decisions = StreamController<MediaPolicyDecision>.broadcast();

  bool _applying = false;
  RtcStatsSample? _queued;
  bool _disposed = false;

  /// Every applied profile change, in order.
  Stream<MediaPolicyDecision> get decisions => _decisions.stream;

  /// Every wire-policy verdict, one per sample that carried an estimate.
  Stream<OpusPolicyDecision> get wireDecisions => _wireDecisions.stream;

  /// The Opus wire policy in force (rate and packet time).
  OpusWireBudget get wirePolicy => _reevaluator.policy;

  /// The tighter of the setup-time ceiling and the live wire policy's rate.
  int? get _effectiveCeilingBps {
    final fixed = audioCeilingBps;
    final wire = _wireCeilingBps;
    if (fixed == null) return wire;
    if (wire == null) return fixed;
    return min(fixed, wire);
  }

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
      await _reevaluateWire(sample);
      await _applyDecisionFor(sample);
      while (true) {
        final queued = _queued;
        if (queued == null) break;
        _queued = null;
        await _reevaluateWire(queued);
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
      final ceiling = _effectiveCeilingBps;
      final audioBps = ceiling != null && ceiling < p.audioMaxBitrateBps
          ? ceiling
          : p.audioMaxBitrateBps;
      _lastAppliedAudioBps = audioBps;
      await port.setAudioMaxBitrate(audioBps);
      if (!_decisions.isClosed) {
        _decisions.add(decision);
      }
    } catch (_) {
      // Transient failures (mid-renegotiation, hung channel) must never
      // kill the sample loop; the next decision retries.
    }
  }

  /// The lowest round trip seen this call — the floor congestion is judged
  /// against. Forgotten slowly so a re-routed path can set a new floor.
  double? _minRttMs;

  /// CONGESTION GATE. The transport's estimate alone is not evidence: on an
  /// audio-only call over a clean link it sits near the send rate (~80
  /// kbit/s, nothing probes higher) and would re-fit every good call to a
  /// longer packet time. So a sample re-evaluates the wire policy only when
  /// the path itself shows the flood: loss at or over 5 %, or a round trip
  /// inflated past twice its floor (and by 300 ms). Clean samples feed
  /// nothing, and the dwell inside the re-evaluator still applies on top.
  bool _showsCongestion(RtcStatsSample sample) {
    final loss = sample.packetLossFraction;
    final rtt = sample.rttMs;
    if (rtt > 0) {
      final floor = _minRttMs;
      _minRttMs = floor == null
          ? rtt.toDouble()
          : min(rtt.toDouble(), floor * 1.001);
    }
    if (loss != null && loss >= 0.05) return true;
    final floor = _minRttMs;
    if (floor != null) {
      return rtt > max(floor * 2, floor + 300);
    }
    return false;
  }

  Future<void> _reevaluateWire(RtcStatsSample sample) async {
    final estimate = sample.availableOutgoingBitrateBps;
    if (estimate == null || estimate <= 0) return;
    if (!_showsCongestion(sample)) return;
    final OpusPolicyDecision decision;
    try {
      decision = _reevaluator.onBandwidthSample(estimate);
    } on StateError {
      return; // the estimator reported an unconstrained link
    }
    if (!_wireDecisions.isClosed) _wireDecisions.add(decision);
    switch (decision) {
      case OpusPolicySteady():
        break;
      case OpusPolicyChangePending(:final target):
        // The packet time waits for the dwell; the RATE the target fits is
        // an encoder parameter and costs nothing — bits drop now, packets
        // later.
        if (target is OpusPolicyPendingPtime) {
          await _applyWireCeiling(target.budget.opusRateBps);
        }
      case OpusPolicyRateChange(:final policy):
        await _applyWireCeiling(policy.opusRateBps);
      case OpusPolicyRenegotiationRequired(:final policy):
        await _applyWireCeiling(policy.opusRateBps);
        await _renegotiate(policy);
      case OpusPolicyBelowFloor(:final refusal):
        // Even the cheapest candidate does not fit the estimate. The
        // cheapest is still far better than the default flood: fit it to
        // the floor the refusal names and take it.
        final admission = OpusWireBudget.forBandwidth(
          refusal.minimumBandwidthBps,
          concurrentStreams: _concurrentStreams,
        );
        if (admission is OpusWireFitted) {
          await _applyWireCeiling(admission.budget.opusRateBps);
          await _renegotiate(admission.budget);
        }
    }
  }

  Future<void> _applyWireCeiling(int rateBps) async {
    _wireCeilingBps = rateBps;
    final port = _port();
    if (port == null) return;
    final profileBps = MediaProfileParameters.of(
      _policy.profile,
    ).audioMaxBitrateBps;
    final ceiling = _effectiveCeilingBps;
    final audioBps = ceiling != null && ceiling < profileBps
        ? ceiling
        : profileBps;
    if (audioBps == _lastAppliedAudioBps) return;
    _lastAppliedAudioBps = audioBps;
    try {
      await port.setAudioMaxBitrate(audioBps);
    } catch (_) {
      // A closed port mid-teardown: nothing to apply to.
    }
  }

  Future<void> _renegotiate(OpusWireBudget policy) async {
    final renegotiate = onRenegotiateWirePolicy;
    if (renegotiate == null || _disposed) return;
    if (_negotiatedPtimeMs == policy.ptimeMs) return;
    // Packet time only ever LENGTHENS mid-call: a shorter one buys bits
    // the flood already proved the link lacks, at the price of a reconnect.
    final current = _negotiatedPtimeMs ?? _initialPtimeMs;
    if (policy.ptimeMs <= current) return;
    final now = _nowMs();
    final last = _lastRenegotiationMs;
    if (last != null && now - last < renegotiationMinInterval.inMilliseconds) {
      return;
    }
    _negotiatedPtimeMs = policy.ptimeMs;
    _lastRenegotiationMs = now;
    try {
      await renegotiate(policy);
    } catch (_) {
      // The controller refused (ended, disposed): nothing to renegotiate.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop(); // Synchronously kill the poll timer before any await.
    await _subscription.cancel();
    await _sampler.dispose();
    await _decisions.close();
    await _wireDecisions.close();
  }
}
