/// Drives the live call from the survival ladder: capacity reports walk
/// [SurvivalLadder]; rungs at or below the real-time-media floor map to
/// the controller's first-class degraded modes, so the call NEVER drops
/// — it only gets thinner, and climbs back when the link recovers.
///
/// Mapping (ladder rung -> call mode):
/// - fullVideo / reducedVideo / audioOnly -> normal media (no degraded
///   mode; the media adaptation layer handles quality within the rung);
/// - lowRateVoice        -> DegradedMode.lowRateVoice;
/// - tokenVoiceFull/Row0 -> DegradedMode.tokenVoice (row selection is a
///   codec knob inside the token lane, not a separate call mode);
/// - voiceNotes / textOnly -> DegradedMode.voiceNotes (half-duplex
///   drops; text captions ride the same outbox at textOnly).
library;

import 'dart:async';

import 'package:call_core/call_core.dart';

import 'survival_mode_driver.dart' show DegradableCallHandle;

class CapacityLadderDriver {
  CapacityLadderDriver({
    required this.call,
    required Stream<int> capacityBps,
    SurvivalLadder? ladder,
  }) : ladder = ladder ?? SurvivalLadder() {
    _sub = capacityBps.listen(_onCapacity);
  }

  final DegradableCallHandle call;
  final SurvivalLadder ladder;
  late final StreamSubscription<int> _sub;
  bool _disposed = false;

  /// Mode transitions applied (telemetry / tests).
  int modeChanges = 0;

  static DegradedMode? _modeFor(SurvivalRung rung) => switch (rung) {
        SurvivalRung.fullVideo ||
        SurvivalRung.reducedVideo ||
        SurvivalRung.audioOnly =>
          null,
        SurvivalRung.lowRateVoice => DegradedMode.lowRateVoice,
        SurvivalRung.tokenVoiceFull ||
        SurvivalRung.tokenVoiceRow0 =>
          DegradedMode.tokenVoice,
        SurvivalRung.voiceNotes ||
        SurvivalRung.textOnly =>
          DegradedMode.voiceNotes,
      };

  void _onCapacity(int bps) {
    if (_disposed) return;
    final state = call.stateOf();
    // Only steer while the call is live (connected or already degraded).
    final live = state is ConnectedCallState || state is DegradedCallState;
    if (!live) return;
    final rung = ladder.report(bps);
    final wanted = _modeFor(rung);
    final current = state.degradedMode;
    if (wanted == current) return;
    modeChanges++;
    if (wanted == null) {
      unawaited(call.exitDegradedMode());
    } else {
      unawaited(call.enterDegradedMode(wanted));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub.cancel();
  }
}
