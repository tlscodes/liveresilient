/// The no-dropout survival ladder: one authoritative table mapping the
/// link's usable bit budget to an operating rung, and a controller that
/// walks that ladder so the call NEVER has no active mode — it only gets
/// thinner. Downward moves are immediate (survival first); upward moves
/// are hysteresis-gated one step at a time so a flapping link cannot
/// bounce the call between rungs.
library;

/// Every way the call can carry the conversation, best first. The list
/// deliberately has no "dead" entry: [textOnly] works at tens of bits
/// per second, so some rung is always available while any bits flow at
/// all; a link with zero capacity parks on [textOnly] with queued
/// delivery (store-and-forward) rather than a dropped call.
enum SurvivalRung {
  /// Full audio+video.
  fullVideo,

  /// Reduced-resolution video; audio protected.
  reducedVideo,

  /// Video off; full-quality audio.
  audioOnly,

  /// Narrowband real-time voice (~6 kbps class).
  lowRateVoice,

  /// Neural-token voice, both codebook rows (1.5 kbps raw ceiling,
  /// less as the per-contact dictionary warms).
  tokenVoiceFull,

  /// Neural-token voice, single codebook row (750 bps raw ceiling) —
  /// reduced fidelity, still a live full-duplex conversation.
  tokenVoiceRow0,

  /// Half-duplex recorded clips through the reliable outbox.
  voiceNotes,

  /// Text/caption fallback — the last drop of water.
  textOnly,
}

/// Minimum sustained bits-per-second a rung needs to operate. The
/// authoritative budget table of the ladder — change rungs HERE only.
const Map<SurvivalRung, int> survivalRungMinBps = {
  SurvivalRung.fullVideo: 500000,
  SurvivalRung.reducedVideo: 150000,
  SurvivalRung.audioOnly: 24000,
  SurvivalRung.lowRateVoice: 6000,
  SurvivalRung.tokenVoiceFull: 1600,
  SurvivalRung.tokenVoiceRow0: 850,
  SurvivalRung.voiceNotes: 300,
  SurvivalRung.textOnly: 0,
};

/// Picks the best rung a [capacityBps] budget can sustain.
SurvivalRung rungForCapacity(int capacityBps) {
  for (final rung in SurvivalRung.values) {
    if (capacityBps >= survivalRungMinBps[rung]!) return rung;
  }
  return SurvivalRung.textOnly; // unreachable: textOnly needs 0
}

/// Walks the ladder from capacity reports.
///
/// Contract (the tests pin all four):
/// - there is ALWAYS a current rung (never null, never "call failed");
/// - downgrades apply immediately, and step one rung at a time so every
///   layer sees each intermediate mode (a collapse walks down fast but
///   in order);
/// - upgrades need the capacity to hold for [climbAfter] consecutive
///   reports, then move exactly ONE rung — no jump from textOnly to
///   fullVideo on a single lucky probe;
/// - an upgrade also requires headroom: capacity must exceed the target
///   rung's budget by [headroomFactor] to avoid flapping at boundaries.
class SurvivalLadder {
  SurvivalLadder({
    this.climbAfter = 3,
    this.headroomFactor = 1.25,
    SurvivalRung initial = SurvivalRung.fullVideo,
  }) : _current = initial;

  final int climbAfter;
  final double headroomFactor;

  SurvivalRung _current;
  int _stableReports = 0;
  int _transitions = 0;

  SurvivalRung get current => _current;

  /// Total rung changes so far (flap metric for tests and telemetry).
  int get transitions => _transitions;

  /// Feed one capacity report; returns the rung after applying it.
  SurvivalRung report(int capacityBps) {
    final target = rungForCapacity(capacityBps);
    if (target.index > _current.index) {
      // Link got worse: step down immediately, one rung per report is
      // NOT enough in a collapse — walk down to the sustainable rung,
      // but through each intermediate step so every layer can react.
      while (_current.index < target.index) {
        _current = SurvivalRung.values[_current.index + 1];
        _transitions++;
      }
      _stableReports = 0;
      return _current;
    }
    if (target.index < _current.index) {
      // Link looks better: climb only after sustained proof + headroom.
      final oneUp = SurvivalRung.values[_current.index - 1];
      final needed = (survivalRungMinBps[oneUp]! * headroomFactor).ceil();
      if (capacityBps >= needed) {
        _stableReports++;
        if (_stableReports >= climbAfter) {
          _current = oneUp;
          _transitions++;
          _stableReports = 0;
        }
      } else {
        _stableReports = 0;
      }
      return _current;
    }
    _stableReports = 0;
    return _current;
  }
}
