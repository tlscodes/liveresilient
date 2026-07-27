/// The full desert scenario against the LIVE call state machine:
/// capacity collapses 500kbps -> 200bps -> recovers; the call must walk
/// lowRateVoice -> tokenVoice -> voiceNotes without ever failing, then
/// climb back to normal media.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/capacity_ladder_driver.dart';
import 'package:reference_app/src/degraded_mode_driver.dart';

class _FakeCall {
  final _states = StreamController<CallState>.broadcast(sync: true);
  var _sequence = 0;
  CallState _state = CallState(
    phase: CallPhase.idle,
    sequence: 0,
    changedAt: DateTime.utc(2026),
  );

  final List<DegradedMode?> modeLog = <DegradedMode?>[];

  void emitPhase(CallPhase phase, {DegradedMode? degradedMode}) {
    _state = CallState(
      phase: phase,
      sequence: ++_sequence,
      changedAt: DateTime.utc(2026),
      degradedMode: degradedMode,
    );
    _states.add(_state);
  }

  Future<void> enterDegradedMode(DegradedMode mode) async {
    modeLog.add(mode);
    emitPhase(CallPhase.degraded, degradedMode: mode);
  }

  Future<void> exitDegradedMode() async {
    modeLog.add(null);
    emitPhase(CallPhase.connected);
  }

  DegradableCallHandle get handle => DegradableCallHandle(
    states: _states.stream,
    stateOf: () => _state,
    enterDegradedMode: enterDegradedMode,
    exitDegradedMode: exitDegradedMode,
  );
}

void main() {
  test('desert collapse and recovery: call never fails, modes walk the '
      'ladder down and climb back with hysteresis', () {
    fakeAsync((async) {
      final call = _FakeCall();
      final capacity = StreamController<int>(sync: true);
      final driver = CapacityLadderDriver(
        call: call.handle,
        capacityBps: capacity.stream,
        ladder: OperatingLadder(climbAfter: 2),
      );
      call.emitPhase(CallPhase.connected);
      async.flushMicrotasks();

      // collapse: healthy -> narrowband -> token voice -> voice notes
      capacity.add(400000);
      async.flushMicrotasks();
      expect(call.modeLog, isEmpty, reason: 'audio/video handled by media');
      capacity.add(7000);
      async.flushMicrotasks();
      expect(call.modeLog.last, DegradedMode.lowRateVoice);
      capacity.add(1700);
      async.flushMicrotasks();
      expect(call.modeLog.last, DegradedMode.tokenVoice);
      capacity.add(900); // row0 sub-rung: same call mode, codec knob
      async.flushMicrotasks();
      expect(
        call.modeLog.last,
        DegradedMode.tokenVoice,
        reason: 'row0 stays tokenVoice — no extra user-visible mode',
      );
      capacity.add(200);
      async.flushMicrotasks();
      expect(call.modeLog.last, DegradedMode.voiceNotes);

      // call is still alive in a first-class phase, never failed
      expect(call._state.phase, CallPhase.degraded);

      // recovery: sustained big capacity climbs one rung per window
      for (var i = 0; i < 40; i++) {
        capacity.add(1000000);
        async.flushMicrotasks();
      }
      expect(call._state.phase, CallPhase.connected);
      expect(call.modeLog.last, isNull, reason: 'back to normal media');

      unawaited(driver.dispose());
      unawaited(capacity.close());
    });
  });

  test('capacity reports while the call is idle are ignored', () {
    fakeAsync((async) {
      final call = _FakeCall();
      final capacity = StreamController<int>(sync: true);
      final driver = CapacityLadderDriver(
        call: call.handle,
        capacityBps: capacity.stream,
      );
      capacity.add(200);
      async.flushMicrotasks();
      expect(call.modeLog, isEmpty);
      unawaited(driver.dispose());
      unawaited(capacity.close());
    });
  });
}
