/// Survival-mode driver: the ladder floor and a flapping path flip the
/// LIVE call into its first-class degraded phase — never a failure — and
/// voice-note clips queue through the real reliable outbox while the
/// transport is down, delivering on recovery.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart' show MediaProfile;
import 'package:media_webrtc/media_webrtc.dart' as mw;
import 'package:messaging/messaging.dart';
import 'package:reference_app/src/survival_mode_driver.dart';

/// In-memory loopback data-channel port pair (mirrors loopback_port.dart's
/// pattern) so a REAL ReliableMessenger carries the clips.
class _MemoryPort implements DataChannelPort {
  final _incoming = StreamController<List<int>>.broadcast();
  _MemoryPort? peer;
  bool online = true;
  final List<List<int>> sent = <List<int>>[];

  @override
  Stream<List<int>> get inbound => _incoming.stream;

  @override
  Future<void> send(List<int> frame) async {
    sent.add(frame);
    if (online && peer != null && !peer!._incoming.isClosed) {
      peer!._incoming.add(frame);
    }
  }

  @override
  Future<void> close() async {
    await _incoming.close();
  }
}

/// Minimal fake for the DegradableCallHandle seams.
class _FakeCall {
  // Async (non-sync) so a listener reacting by emitting a new phase never
  // re-enters the controller mid-fire.
  final _states = StreamController<CallState>.broadcast();
  var _sequence = 0;
  CallState _state = CallState(
    phase: CallPhase.idle,
    sequence: 0,
    changedAt: DateTime.utc(2026),
  );

  final List<DegradedMode> enteredModes = <DegradedMode>[];
  int exits = 0;

  void emitPhase(
    CallPhase phase, {
    int reconnectAttempt = 0,
    DegradedMode? degradedMode,
  }) {
    _state = CallState(
      phase: phase,
      sequence: ++_sequence,
      changedAt: DateTime.utc(2026),
      reconnectAttempt: reconnectAttempt,
      degradedMode: degradedMode,
    );
    _states.add(_state);
  }

  Stream<CallState> get states => _states.stream;

  CallState get state => _state;

  Future<void> enterDegradedMode(DegradedMode mode) async {
    enteredModes.add(mode);
    emitPhase(CallPhase.degraded, degradedMode: mode);
  }

  Future<void> exitDegradedMode() async {
    exits++;
    emitPhase(CallPhase.connected);
  }

  DegradableCallHandle get handle => DegradableCallHandle(
    states: states,
    stateOf: () => state,
    enterDegradedMode: enterDegradedMode,
    exitDegradedMode: exitDegradedMode,
  );
}

void main() {
  test('ladder floor decision enters lowRateVoice mode; climbing off the '
      'floor exits it', () {
    fakeAsync((async) {
      final controller = _FakeCall();
      final decisions = StreamController<mw.MediaPolicyDecision>(sync: true);
      final driver = SurvivalModeDriver(
        call: controller.handle,
        adaptationDecisions: decisions.stream,
      );
      controller.emitPhase(CallPhase.connected);
      async.flushMicrotasks();

      decisions.add(
        const mw.MediaPolicyDecision(
          previous: MediaProfile.audioOnly,
          next: MediaProfile.lowRateVoice,
          reason: 'severe loss',
        ),
      );
      async.flushMicrotasks();
      expect(controller.enteredModes, [DegradedMode.lowRateVoice]);

      decisions.add(
        const mw.MediaPolicyDecision(
          previous: MediaProfile.lowRateVoice,
          next: MediaProfile.audioOnly,
          reason: 'sustained clean conditions',
        ),
      );
      async.flushMicrotasks();
      expect(controller.exits, 1);

      driver.dispose();
      decisions.close();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a flapping path (2 reconnect episodes in the window) enters '
      'voice-note mode on reconnect; clips queue through the REAL outbox '
      'while offline and deliver when the transport recovers; stability '
      'exits the mode', () {
    fakeAsync((async) {
      final controller = _FakeCall();
      final decisions = StreamController<mw.MediaPolicyDecision>(sync: true);

      final local = _MemoryPort();
      final remote = _MemoryPort();
      local.peer = remote;
      remote.peer = local;
      local.online = false; // Transport starts DOWN: clips must queue.

      final messenger = ReliableMessenger(local, peerId: 'caller-survival');
      final remoteMessenger = ReliableMessenger(remote, peerId: 'callee');
      final receiver = AttachmentReceiver();
      final received = <Attachment>[];
      receiver.completed.listen(received.add);
      remoteMessenger.incoming.listen((m) => receiver.offer(m.text));

      var clipCounter = 0;
      final driver = SurvivalModeDriver(
        call: controller.handle,
        adaptationDecisions: decisions.stream,
        recordClip: (length) async => List<int>.filled(64, ++clipCounter),
        messenger: () async => messenger,
        clipLength: const Duration(seconds: 5),
        stableFor: const Duration(seconds: 30),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(async.elapsed.inMilliseconds),
      );

      // Two reconnect episodes inside the window, then a successful
      // reconnect: the driver must flip the call into voice-note mode.
      controller.emitPhase(CallPhase.connected);
      controller.emitPhase(CallPhase.reconnecting, reconnectAttempt: 1);
      controller.emitPhase(CallPhase.connected);
      controller.emitPhase(CallPhase.reconnecting, reconnectAttempt: 1);
      controller.emitPhase(CallPhase.connected);
      async.flushMicrotasks();
      expect(controller.enteredModes, [DegradedMode.voiceNotes]);

      // Two clip periods while the transport is DOWN: clips are recorded
      // and enqueued (pending, unacked), not lost.
      async.elapse(const Duration(seconds: 10));
      expect(driver.queuedClips, 2);
      expect(messenger.pendingCount, greaterThan(0));
      expect(received, isEmpty, reason: 'transport is down');

      // Transport recovers: retransmission ticks deliver every queued
      // chunk and the remote reassembles complete clips.
      local.online = true;
      for (var i = 0; i < 40; i++) {
        async.elapse(const Duration(seconds: 1));
        unawaited(messenger.tick());
        async.flushMicrotasks();
      }
      expect(received, isNotEmpty, reason: 'queued clips must arrive');
      expect(received.first.contentType, 'audio/ogg');

      // 30s of stability with no new reconnect: mode exits.
      expect(controller.exits, greaterThanOrEqualTo(1));

      driver.dispose();
      messenger.close();
      remoteMessenger.close();
      receiver.close();
      decisions.close();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(async.pendingTimers, isEmpty);
    });
  });
}
