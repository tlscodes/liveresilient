/// Token-voice lane in the LIVE app: entering DegradedMode.tokenVoice
/// starts pumping mic PCM through the codec into queued blocks; the far
/// end plays them; leaving the mode stops the lane cleanly.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/degraded_mode_driver.dart';
import 'package:reference_app/src/token_voice_lane.dart';

class _FakeCall {
  final _states = StreamController<CallState>.broadcast(sync: true);
  var _sequence = 0;
  CallState _state = CallState(
    phase: CallPhase.idle,
    sequence: 0,
    changedAt: DateTime.utc(2026),
  );

  void emitPhase(CallPhase phase, {DegradedMode? degradedMode}) {
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
    enterDegradedMode: (m) async =>
        emitPhase(CallPhase.degraded, degradedMode: m),
    exitDegradedMode: () async => emitPhase(CallPhase.connected),
  );
}

void main() {
  test('entering tokenVoice starts the lane; PCM becomes blocks, far end '
      'plays them; exiting stops the lane', () async {
    final call = _FakeCall();
    final mic = StreamController<List<double>>(sync: true);
    final played = <List<double>>[];
    final near = TokenVoiceLane(
      call: call.handle,
      codec: SimulatedVoiceCodecBinding(installed: true),
      queue: DtnBundleQueue(),
      microphone: mic.stream,
      speaker: played.add,
      framesPerBlock: 5,
    );
    // far end shares the codec model; its own lane just receives here
    final far = TokenVoiceLane(
      call: call.handle,
      codec: SimulatedVoiceCodecBinding(installed: true),
      queue: DtnBundleQueue(),
      microphone: const Stream.empty(),
      speaker: played.add,
    );

    call.emitPhase(CallPhase.degraded, degradedMode: DegradedMode.tokenVoice);
    await Future<void>.delayed(Duration.zero);
    expect(near.active, isTrue);
    expect(far.active, isTrue);

    // 10 codec frames of audio -> 2 blocks of 5
    mic.add(List<double>.filled(160 * 10, 0.25));
    await Future<void>.delayed(Duration.zero);
    expect(near.blocksSent, 2);

    // deliver the queued bundles straight into the far lane
    near.onForward = (bundle) async {
      await far.onRemoteBlock(bundle.payload);
      return true;
    };
    await near.queue.flush((b) async {
      await far.onRemoteBlock(b.payload);
      return true;
    }, nowMs: 0);
    expect(far.blocksPlayed, 2);
    expect(played, hasLength(2));
    expect(
      played.first.length,
      160 * 5,
      reason: 'frame-aligned PCM at the speaker',
    );

    // leaving the mode stops the lane and clears buffers
    call.emitPhase(CallPhase.connected);
    await Future<void>.delayed(Duration.zero);
    expect(near.active, isFalse);
    mic.add(List<double>.filled(160 * 10, 0.5));
    await Future<void>.delayed(Duration.zero);
    expect(near.blocksSent, 2, reason: 'no blocks while inactive');

    await near.dispose();
    await far.dispose();
    await mic.close();
  });

  test(
    'codec not installed: lane refuses to activate (ladder guard)',
    () async {
      final call = _FakeCall();
      final lane = TokenVoiceLane(
        call: call.handle,
        codec: SimulatedVoiceCodecBinding(),
        queue: DtnBundleQueue(),
        microphone: const Stream.empty(),
        speaker: (_) {},
      );
      call.emitPhase(CallPhase.degraded, degradedMode: DegradedMode.tokenVoice);
      await Future<void>.delayed(Duration.zero);
      expect(lane.active, isFalse);
      await lane.dispose();
    },
  );
}
