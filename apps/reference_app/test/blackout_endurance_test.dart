/// The blackout endurance scenario — the harshest simulated network this
/// stack can face, end to end and all layers at once:
///
///   stage 1  healthy 400 kbps
///   stage 2  1/100 collapse -> 4 kbps      (narrowband voice)
///   stage 3  1.5 kbps, 90% lossy pulses    (token voice, queue holds)
///   stage 4  300 bps                        (voice notes)
///   stage 5  TOTAL darkness, 0 bps, 60 s    (nothing moves, nothing dies)
///   stage 6  faint 1 kbps pulses            (row0 token voice, drain)
///   stage 7  full recovery                  (climb back to normal media)
///
/// Must hold: the call NEVER fails; the ladder always has a rung; every
/// token block produced in stages 3-6 is eventually played, bit-exact
/// and in order; codec state never diverges; no rung flapping.
library;

import 'dart:async';
import 'dart:math';

import 'package:call_core/call_core.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
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
  bool everFailed = false;

  void emitPhase(CallPhase phase, {DegradedMode? degradedMode}) {
    if (phase == CallPhase.failed) everFailed = true;
    _state = CallState(
      phase: phase,
      sequence: ++_sequence,
      changedAt: DateTime.utc(2026),
      degradedMode: degradedMode,
    );
    _states.add(_state);
  }

  DegradableCallHandle get handle => DegradableCallHandle(
    states: _states.stream,
    stateOf: () => _state,
    enterDegradedMode: (m) async {
      modeLog.add(m);
      emitPhase(CallPhase.degraded, degradedMode: m);
    },
    exitDegradedMode: () async {
      modeLog.add(null);
      emitPhase(CallPhase.connected);
    },
  );
}

void main() {
  test(
    'blackout endurance: 1/100 collapse to total darkness and back — '
    'call never fails, every block survives, no divergence, no flap',
    () async {
      final call = _FakeCall();
      final capacity = StreamController<int>(sync: true);
      final ladder = OperatingLadder(climbAfter: 2);
      final driver = CapacityLadderDriver(
        call: call.handle,
        capacityBps: capacity.stream,
        ladder: ladder,
      );

      // token lane plumbing (sender on our side, receiver = far end)
      final rng = Random(2026);
      final queue = DtnBundleQueue();
      final sender = TokenVoiceSender(
        nRows: 2,
        queue: queue,
        blockLifetime: const Duration(minutes: 10),
      );
      final receiver = TokenVoiceReceiver(nRows: 2);
      final produced = <List<List<int>>>[];
      var nowMs = 0;

      List<List<int>> speech(int frames) => [
        for (var i = 0; i < frames; i++) [rng.nextInt(1024), rng.nextInt(1024)],
      ];

      void produceBlock() {
        final block = speech(25);
        produced.add(block);
        sender.sendBlock(block, nowMs: nowMs);
      }

      // a pulse where only [survivors] of queued bundles get through
      Future<void> lossyPulse(double surviveP) async {
        await queue.flush((bundle) async {
          if (rng.nextDouble() > surviveP) return false; // lost this pulse
          receiver.offer(bundle.payload);
          return true;
        }, nowMs: nowMs);
      }

      // ---- stage 1: healthy
      call.emitPhase(CallPhase.connected);
      capacity.add(650000);
      expect(call.modeLog, isEmpty);

      // ---- stage 2: exact 1/100 collapse (650k -> 6.5k)
      capacity.add(6500);
      expect(call.modeLog.last, DegradedMode.lowRateVoice);

      // ---- stage 3: 1.5 kbps with 90% loss — token voice under fire
      capacity.add(1500);
      expect(call.modeLog.last, DegradedMode.tokenVoice);
      for (var s = 0; s < 20; s++) {
        produceBlock();
        await lossyPulse(0.1); // 90% of attempts fail; queue must hold
        nowMs += 1000;
      }
      expect(
        queue.pendingCount,
        greaterThan(0),
        reason: 'undelivered blocks are HELD, not lost',
      );

      // ---- stage 4: 300 bps — half-duplex territory
      capacity.add(300);
      expect(call.modeLog.last, DegradedMode.voiceNotes);

      // ---- stage 5: total darkness, 60 s — nothing moves, nothing dies
      capacity.add(0);
      expect(ladder.current, OperatingRung.textOnly);
      final heldBefore = queue.pendingCount;
      for (var s = 0; s < 60; s++) {
        if (s % 10 == 0) produceBlock(); // speaker keeps talking into DTN
        nowMs += 1000;
      }
      expect(queue.pendingCount, greaterThan(heldBefore));
      expect(call.everFailed, isFalse, reason: 'darkness is a MODE, not death');

      // ---- stage 6: faint 1 kbps pulses — drain through row0 rung
      for (var s = 0; s < 4; s++) {
        capacity.add(1100);
      }
      expect(ladder.current, OperatingRung.tokenVoiceRow0);
      expect(call.modeLog.last, DegradedMode.tokenVoice);
      while (queue.pendingCount > 0) {
        await lossyPulse(0.5);
        nowMs += 1000;
      }

      // every block produced under fire arrived, bit-exact, in order
      expect(receiver.played, equals(produced));
      expect(sender.epochRestarts, 0, reason: 'lifetime outlasted the dark');

      // ---- stage 7: full recovery, climb all the way back
      for (var s = 0; s < 30; s++) {
        capacity.add(1000000);
      }
      expect(ladder.current, OperatingRung.fullVideo);
      expect(call.modeLog.last, isNull, reason: 'normal media restored');
      expect(call.everFailed, isFalse);

      // sanity on flap: transitions = down-walks + bounded climbs, small
      expect(ladder.transitions, lessThan(25));

      await driver.dispose();
      await capacity.close();
    },
  );
}
