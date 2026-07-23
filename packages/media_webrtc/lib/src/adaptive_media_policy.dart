/// Adaptive media quality policy.
///
/// Consumes smoothed [RtcStatsSample] values and recommends a
/// [MediaProfile] (video resolution / frame rate / bitrate tier, down to
/// audio-only) for the sender side. The engine applies recommendations via
/// standard `RTCRtpSender.setParameters` encodings — codec- and
/// platform-agnostic.
///
/// Design principles:
/// - **fast down, slow up**: quality drops as soon as sustained loss or
///   delay is detected, but recovers only after a hold-down period of clean
///   samples (prevents oscillation);
/// - **audio first**: under severe degradation, video is sacrificed
///   entirely before audio bitrate is reduced below the floor;
/// - deterministic and unit-testable: pure state machine over samples.
///
/// Designed from the v2 blueprint role (no v1 equivalent; the v1 kit had
/// no media layer).
library;

import 'rtc_stats_sampler.dart';

/// Ordered quality ladder, best first.
enum MediaProfile {
  /// 720p / 30fps class, ~1.7 Mbps video.
  high,

  /// 480p / 24fps class, ~800 kbps video.
  medium,

  /// 240p / 15fps class, ~300 kbps video.
  low,

  /// Thumbnail video, ~120 kbps: keeps presence while barely usable.
  minimal,

  /// Video disabled; all remaining budget protects audio.
  audioOnly,

  /// Survival floor: video disabled AND audio pinned to a narrowband
  /// mono budget (~6 kbps) so the call stays intelligible on links where
  /// even standard audio-only starves (2G-grade, congested satellite,
  /// heavily shaped hotspots).
  lowRateVoice,
}

/// Concrete sender parameters for a profile.
class MediaProfileParameters {
  final MediaProfile profile;
  final bool videoEnabled;
  final int videoMaxBitrateBps;
  final int videoMaxFramerate;

  /// Scale-down factor relative to the captured resolution
  /// (`scaleResolutionDownBy` in RTCRtpEncodingParameters).
  final double videoScaleResolutionDownBy;
  final int audioMaxBitrateBps;

  const MediaProfileParameters({
    required this.profile,
    required this.videoEnabled,
    required this.videoMaxBitrateBps,
    required this.videoMaxFramerate,
    required this.videoScaleResolutionDownBy,
    required this.audioMaxBitrateBps,
  });

  static const Map<MediaProfile, MediaProfileParameters> table = {
    MediaProfile.high: MediaProfileParameters(
      profile: MediaProfile.high,
      videoEnabled: true,
      videoMaxBitrateBps: 1700000,
      videoMaxFramerate: 30,
      videoScaleResolutionDownBy: 1.0,
      audioMaxBitrateBps: 32000,
    ),
    MediaProfile.medium: MediaProfileParameters(
      profile: MediaProfile.medium,
      videoEnabled: true,
      videoMaxBitrateBps: 800000,
      videoMaxFramerate: 24,
      videoScaleResolutionDownBy: 1.5,
      audioMaxBitrateBps: 32000,
    ),
    MediaProfile.low: MediaProfileParameters(
      profile: MediaProfile.low,
      videoEnabled: true,
      videoMaxBitrateBps: 300000,
      videoMaxFramerate: 15,
      videoScaleResolutionDownBy: 3.0,
      audioMaxBitrateBps: 24000,
    ),
    MediaProfile.minimal: MediaProfileParameters(
      profile: MediaProfile.minimal,
      videoEnabled: true,
      videoMaxBitrateBps: 120000,
      videoMaxFramerate: 10,
      videoScaleResolutionDownBy: 4.0,
      audioMaxBitrateBps: 16000,
    ),
    MediaProfile.audioOnly: MediaProfileParameters(
      profile: MediaProfile.audioOnly,
      videoEnabled: false,
      videoMaxBitrateBps: 0,
      videoMaxFramerate: 0,
      videoScaleResolutionDownBy: 1.0,
      audioMaxBitrateBps: 16000,
    ),
    MediaProfile.lowRateVoice: MediaProfileParameters(
      profile: MediaProfile.lowRateVoice,
      videoEnabled: false,
      videoMaxBitrateBps: 0,
      videoMaxFramerate: 0,
      videoScaleResolutionDownBy: 1.0,
      audioMaxBitrateBps: 6000,
    ),
  };

  static MediaProfileParameters of(MediaProfile profile) => table[profile]!;
}

class AdaptiveMediaPolicyConfig {
  /// Loss fraction above which a sample counts as "bad".
  final double lossDowngradeThreshold;

  /// Loss fraction that forces an immediate two-step downgrade.
  final double lossSevereThreshold;

  /// RTT above which a sample counts as "bad".
  final int rttDowngradeThresholdMs;

  /// Consecutive bad samples required to downgrade one step.
  final int badSamplesToDowngrade;

  /// Consecutive clean samples required to upgrade one step
  /// (slow-up hysteresis).
  final int cleanSamplesToUpgrade;

  /// A sample is "clean" only when loss is below this fraction.
  final double lossCleanThreshold;

  /// Upgrades additionally require the congestion controller's available
  /// outgoing bitrate (when reported) to exceed the target profile's video
  /// bitrate by this headroom factor.
  final double upgradeBandwidthHeadroom;

  AdaptiveMediaPolicyConfig({
    this.lossDowngradeThreshold = 0.05,
    this.lossSevereThreshold = 0.20,
    this.rttDowngradeThresholdMs = 600,
    this.badSamplesToDowngrade = 2,
    this.cleanSamplesToUpgrade = 8,
    this.lossCleanThreshold = 0.02,
    this.upgradeBandwidthHeadroom = 1.25,
  }) {
    _validate();
  }

  /// Validates thresholds/counts are within sane bounds and that the loss
  /// ladder is internally consistent: a sample must clear the "clean"
  /// threshold before it can clear the (higher) "downgrade" threshold,
  /// which in turn must not exceed the "severe" threshold — otherwise the
  /// state machine in [AdaptiveMediaPolicy] could classify a sample as both
  /// clean and bad, or skip the two-step severe downgrade entirely.
  void _validate() {
    if (lossDowngradeThreshold < 0 || lossDowngradeThreshold > 1) {
      throw RangeError.range(
        lossDowngradeThreshold,
        0,
        1,
        'lossDowngradeThreshold',
      );
    }
    if (lossSevereThreshold < 0 || lossSevereThreshold > 1) {
      throw RangeError.range(lossSevereThreshold, 0, 1, 'lossSevereThreshold');
    }
    if (lossCleanThreshold < 0 || lossCleanThreshold > 1) {
      throw RangeError.range(lossCleanThreshold, 0, 1, 'lossCleanThreshold');
    }
    if (rttDowngradeThresholdMs < 1) {
      throw RangeError.range(
        rttDowngradeThresholdMs,
        1,
        null,
        'rttDowngradeThresholdMs',
      );
    }
    if (badSamplesToDowngrade < 1) {
      throw RangeError.range(
        badSamplesToDowngrade,
        1,
        null,
        'badSamplesToDowngrade',
      );
    }
    if (cleanSamplesToUpgrade < 1) {
      throw RangeError.range(
        cleanSamplesToUpgrade,
        1,
        null,
        'cleanSamplesToUpgrade',
      );
    }
    if (upgradeBandwidthHeadroom <= 0) {
      throw ArgumentError.value(
        upgradeBandwidthHeadroom,
        'upgradeBandwidthHeadroom',
        'must be > 0',
      );
    }
    if (lossCleanThreshold >= lossDowngradeThreshold) {
      throw ArgumentError.value(
        lossCleanThreshold,
        'lossCleanThreshold',
        'must be < lossDowngradeThreshold',
      );
    }
    if (lossDowngradeThreshold > lossSevereThreshold) {
      throw ArgumentError.value(
        lossDowngradeThreshold,
        'lossDowngradeThreshold',
        'must be <= lossSevereThreshold',
      );
    }
  }
}

/// A recommendation emitted by the policy when the profile changes.
class MediaPolicyDecision {
  final MediaProfile previous;
  final MediaProfile next;
  final String reason;

  const MediaPolicyDecision({
    required this.previous,
    required this.next,
    required this.reason,
  });

  MediaProfileParameters get parameters => MediaProfileParameters.of(next);

  @override
  String toString() =>
      'MediaPolicyDecision(${previous.name} -> ${next.name}: $reason)';
}

class AdaptiveMediaPolicy {
  final AdaptiveMediaPolicyConfig config;

  MediaProfile _profile;
  int _consecutiveBad = 0;
  int _consecutiveClean = 0;

  AdaptiveMediaPolicy({
    MediaProfile initialProfile = MediaProfile.medium,
    AdaptiveMediaPolicyConfig? config,
  }) : config = config ?? AdaptiveMediaPolicyConfig(),
       _profile = initialProfile;

  MediaProfile get profile => _profile;

  /// Feeds one sample; returns a decision when the profile changed, null
  /// otherwise.
  MediaPolicyDecision? onSample(RtcStatsSample sample) {
    final severe = sample.packetLossFraction >= config.lossSevereThreshold;
    final bad =
        severe ||
        sample.packetLossFraction >= config.lossDowngradeThreshold ||
        sample.rttMs >= config.rttDowngradeThresholdMs;
    final clean =
        sample.packetLossFraction < config.lossCleanThreshold &&
        sample.rttMs < config.rttDowngradeThresholdMs;

    if (severe) {
      _consecutiveBad = 0;
      _consecutiveClean = 0;
      return _shift(
        steps: 2,
        reason:
            'severe loss '
            '${(sample.packetLossFraction * 100).toStringAsFixed(1)}%',
      );
    }

    if (bad) {
      _consecutiveClean = 0;
      _consecutiveBad++;
      if (_consecutiveBad >= config.badSamplesToDowngrade) {
        _consecutiveBad = 0;
        return _shift(
          steps: 1,
          reason:
              'sustained loss/delay '
              '(loss ${(sample.packetLossFraction * 100).toStringAsFixed(1)}%, '
              'rtt ${sample.rttMs}ms)',
        );
      }
      return null;
    }

    _consecutiveBad = 0;

    if (clean) {
      _consecutiveClean++;
      if (_consecutiveClean >= config.cleanSamplesToUpgrade &&
          _canUpgrade(sample)) {
        _consecutiveClean = 0;
        return _shift(steps: -1, reason: 'sustained clean conditions');
      }
    } else {
      _consecutiveClean = 0;
    }
    return null;
  }

  bool _canUpgrade(RtcStatsSample sample) {
    if (_profile == MediaProfile.high) return false;
    final target = MediaProfile.values[_profile.index - 1]; // One step better.
    final estimate = sample.availableOutgoingBitrateBps;
    if (estimate == null) return true; // No estimate: rely on hysteresis alone.
    // A measured value -- including a measured 0 -- is a real gate: zero
    // headroom must block the upgrade, not be treated as "no estimate".
    final required =
        MediaProfileParameters.of(target).videoMaxBitrateBps *
        config.upgradeBandwidthHeadroom;
    return estimate >= required;
  }

  /// Moves down the ladder for positive [steps], up for negative.
  MediaPolicyDecision? _shift({required int steps, required String reason}) {
    final targetIndex = (_profile.index + steps).clamp(
      0,
      MediaProfile.values.length - 1,
    );
    final target = MediaProfile.values[targetIndex];
    if (target == _profile) return null;
    final previous = _profile;
    _profile = target;
    return MediaPolicyDecision(
      previous: previous,
      next: target,
      reason: reason,
    );
  }

  /// Resets hysteresis state, e.g. after an ICE restart or path change.
  void reset({MediaProfile? profile}) {
    _consecutiveBad = 0;
    _consecutiveClean = 0;
    if (profile != null) _profile = profile;
  }
}
