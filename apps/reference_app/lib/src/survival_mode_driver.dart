/// Closes the "call that never fails" loop: watches the live session's two
/// existing signals — the media-adaptation ladder position and the
/// controller's reconnect episodes — and drives the controller's
/// first-class survival phase ([CallPhase.degraded]) from them:
///
/// - ladder lands on [MediaProfile.lowRateVoice] → the call is marked
///   degraded in [DegradedMode.lowRateVoice]; climbing back off the floor
///   clears it.
/// - a flapping path (>= [reconnectEpisodesToDegrade] reconnect episodes
///   inside [reconnectWindow]) → after the next successful reconnect the
///   call is marked [DegradedMode.voiceNotes]: short recorded clips are
///   queued as ordinary attachments through the EXISTING reliable outbox,
///   which retransmits them whenever the transport is briefly alive. A
///   stretch of [stableFor] without further reconnects clears the mode.
///
/// Capture is a SEAM ([recordClip]): real microphone capture is
/// device-specific, so production injects the platform recorder while tests
/// (and CI) inject a synthetic clip source. This driver contains no
/// platform code.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:messaging/messaging.dart';

/// Records one voice clip of at most [length]; returns encoded audio bytes,
/// or null when capture is unavailable (no permission, no mic).
typedef ClipRecorder = Future<List<int>?> Function(Duration length);

/// The slice of `CallController` this driver drives — kept as seams
/// because `CallController` is a final class (tests inject fakes here,
/// production passes the controller's own members).
class DegradableCallHandle {
  DegradableCallHandle({
    required this.states,
    required this.stateOf,
    required this.enterDegradedMode,
    required this.exitDegradedMode,
  });

  /// Production wiring from a live [CallController].
  DegradableCallHandle.of(CallController controller)
    : this(
        states: controller.states,
        stateOf: () => controller.state,
        enterDegradedMode: controller.enterDegradedMode,
        exitDegradedMode: controller.exitDegradedMode,
      );

  final Stream<CallState> states;
  final CallState Function() stateOf;
  final Future<void> Function(DegradedMode mode) enterDegradedMode;
  final Future<void> Function() exitDegradedMode;
}

class SurvivalModeDriver {
  SurvivalModeDriver({
    required DegradableCallHandle call,
    required Stream<MediaPolicyDecision> adaptationDecisions,
    this.recordClip,
    this.messenger,
    this.reconnectEpisodesToDegrade = 2,
    this.reconnectWindow = const Duration(seconds: 60),
    this.stableFor = const Duration(seconds: 30),
    this.clipLength = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _call = call,
       _now = now ?? DateTime.now {
    _stateSub = call.states.listen(_onState);
    _decisionSub = adaptationDecisions.listen(_onDecision);
  }

  final DegradableCallHandle _call;
  final ClipRecorder? recordClip;
  final Future<ReliableMessenger> Function()? messenger;
  final DateTime Function() _now;

  /// Reconnect episodes inside [reconnectWindow] that mark the path as
  /// flapping (voice-note territory rather than live audio).
  final int reconnectEpisodesToDegrade;
  final Duration reconnectWindow;

  /// Connected time without a new reconnect episode after which the
  /// voice-note mode is cleared.
  final Duration stableFor;
  final Duration clipLength;

  late final StreamSubscription<CallState> _stateSub;
  late final StreamSubscription<MediaPolicyDecision> _decisionSub;

  final List<DateTime> _reconnectEpisodes = <DateTime>[];
  Timer? _stableTimer;
  Timer? _clipTimer;
  bool _recording = false;
  bool _disposed = false;
  int _clipSeq = 0;

  /// Voice-note clips queued so far (for UI badges and tests).
  int get queuedClips => _clipSeq;

  void _onState(CallState state) {
    if (_disposed) return;
    switch (state) {
      case ReconnectingCallState(:final reconnectAttempt):
        if (reconnectAttempt == 1) {
          // Edge of a NEW episode (attempt numbers restart per episode).
          _reconnectEpisodes.add(_now());
        }
        _stableTimer?.cancel();
      case ConnectedCallState():
        _pruneEpisodes();
        if (_reconnectEpisodes.length >= reconnectEpisodesToDegrade) {
          unawaited(_call.enterDegradedMode(DegradedMode.voiceNotes));
        }
        _armStableTimer();
      case DegradedCallState(:final mode):
        if (mode == DegradedMode.voiceNotes) {
          _startClipLoop();
          _armStableTimer();
        } else {
          _stopClipLoop();
        }
      case IdleCallState() ||
          ConnectingCallState() ||
          NegotiatingCallState() ||
          EndingCallState() ||
          EndedCallState() ||
          FailedCallState():
        _stopClipLoop();
        _stableTimer?.cancel();
    }
  }

  void _onDecision(MediaPolicyDecision decision) {
    if (_disposed) return;
    if (decision.next == MediaProfile.lowRateVoice) {
      unawaited(_call.enterDegradedMode(DegradedMode.lowRateVoice));
    } else if (decision.previous == MediaProfile.lowRateVoice &&
        _call.stateOf().degradedMode == DegradedMode.lowRateVoice) {
      unawaited(_call.exitDegradedMode());
    }
  }

  void _pruneEpisodes() {
    final cutoff = _now().subtract(reconnectWindow);
    _reconnectEpisodes.removeWhere((t) => t.isBefore(cutoff));
  }

  void _armStableTimer() {
    _stableTimer?.cancel();
    _stableTimer = Timer(stableFor, () {
      if (_disposed) return;
      _reconnectEpisodes.clear();
      if (_call.stateOf().degradedMode == DegradedMode.voiceNotes) {
        unawaited(_call.exitDegradedMode());
      }
    });
  }

  void _startClipLoop() {
    if (_clipTimer != null || recordClip == null || messenger == null) {
      return;
    }
    _clipTimer = Timer.periodic(clipLength, (_) => _captureOne());
  }

  void _stopClipLoop() {
    _clipTimer?.cancel();
    _clipTimer = null;
  }

  Future<void> _captureOne() async {
    if (_recording || _disposed) return;
    _recording = true;
    try {
      final bytes = await recordClip!(clipLength);
      if (bytes == null || bytes.isEmpty || _disposed) return;
      // Rides the existing reliable outbox: chunked, acked, retransmitted
      // on tick — so the clip goes out whenever the transport is alive,
      // now or after the next reconnect.
      await sendAttachment(
        await messenger!(),
        Attachment(
          id: 'voice-note-${_clipSeq++}',
          kind: MediaKind.file,
          contentType: 'audio/ogg',
          bytes: bytes,
        ),
      );
    } catch (_) {
      // Capture/enqueue failures must never kill the loop; the next
      // period retries with a fresh clip.
    } finally {
      _recording = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopClipLoop();
    _stableTimer?.cancel();
    await _stateSub.cancel();
    await _decisionSub.cancel();
  }
}
