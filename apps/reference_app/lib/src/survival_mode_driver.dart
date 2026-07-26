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
import 'package:device_link/device_link.dart';
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
    Stream<bool>? pathFailingSoon,
    this.recordClip,
    this.messenger,
    this.fallbackStore,
    VoiceCodecBinding? tokenCodec,
    this.reconnectEpisodesToDegrade = 2,
    this.reconnectWindow = const Duration(seconds: 60),
    this.stableFor = const Duration(seconds: 30),
    this.clipLength = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _call = call,
       _now = now ?? DateTime.now {
    // Token-voice rung availability: resolved once up front (the codec
    // model either is or is not downloaded on this device); a late
    // install upgrades the NEXT degradation, never a running one.
    if (tokenCodec != null) {
      unawaited(tokenCodec.available.then((ok) {
        if (!_disposed) _tokenVoiceAvailable = ok;
      }).catchError((_) {}));
    }
    _stateSub = call.states.listen(_onState);
    _decisionSub = adaptationDecisions.listen(_onDecision);
    // Foresight input: the trend watch predicting the live path will fail
    // shortly. Entering voice-note mode BEFORE the drop means the first
    // clips ride a link that still half-works instead of a dead one.
    _foresightSub = pathFailingSoon?.listen(_onFailingSoon);
  }

  final DegradableCallHandle _call;
  final ClipRecorder? recordClip;
  final Future<ReliableMessenger> Function()? messenger;

  /// Last-resort durable queue for a clip whose send attempt failed (e.g.
  /// the outbox itself threw before the clip could be handed off). Off by
  /// default (null): with no store supplied, behavior is byte-identical to
  /// before this seam existed — a failed send is simply dropped, same as
  /// today. When supplied, a failed clip is offered here instead of lost,
  /// and flushed through the messenger the moment the call reconnects.
  final DtnBundleQueue? fallbackStore;
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
  StreamSubscription<bool>? _foresightSub;

  /// Pre-emptive degradations taken on a predicted failure (UI/tests).
  int foresightDegrades = 0;

  bool _tokenVoiceAvailable = false;

  /// The rung below live low-rate voice: a token-voice call when the
  /// device has the neural codec model, otherwise voice notes.
  DegradedMode get _floorMode => _tokenVoiceAvailable
      ? DegradedMode.tokenVoice
      : DegradedMode.voiceNotes;

  void _onFailingSoon(bool failingSoon) {
    if (_disposed || !failingSoon) return;
    final state = _call.stateOf();
    // Act only while live audio is actually at stake and not already
    // degraded — idempotent under a stream that repeats its verdict.
    if (state is ConnectedCallState && state.degradedMode == null) {
      foresightDegrades++;
      unawaited(_call.enterDegradedMode(_floorMode));
    }
  }

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
          unawaited(_call.enterDegradedMode(_floorMode));
        }
        _armStableTimer();
        unawaited(_flushFallback());
      case DegradedCallState(:final mode):
        if (mode == DegradedMode.voiceNotes) {
          _startClipLoop();
          _armStableTimer();
        } else {
          _stopClipLoop();
          // Token voice is still a flap-driven floor mode: it clears the
          // same way voice notes do, after a stable stretch.
          if (mode == DegradedMode.tokenVoice) _armStableTimer();
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
      final mode = _call.stateOf().degradedMode;
      if (mode == DegradedMode.voiceNotes ||
          mode == DegradedMode.tokenVoice) {
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
    List<int>? bytes;
    try {
      bytes = await recordClip!(clipLength);
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
      // The outbox send attempt itself failed (as opposed to being merely
      // queued for later retransmission) — the clip is otherwise lost. If
      // a fallback store was supplied, offer it there instead; it is
      // flushed through the messenger the next time the call reconnects.
      // Capture/enqueue failures must never kill the loop; the next
      // period retries with a fresh clip regardless.
      final store = fallbackStore;
      if (store != null && bytes != null && bytes.isNotEmpty) {
        try {
          store.offer(
            DtnBundle(
              id: 'voice-note-fallback-${_clipSeq++}',
              payload: bytes,
              priority: LinkMessagePriority.bulk,
              createdAtMs: _now().millisecondsSinceEpoch,
              lifetimeMs: const Duration(minutes: 10).inMilliseconds,
            ),
            nowMs: _now().millisecondsSinceEpoch,
          );
        } catch (_) {
          // Offer failures are swallowed too — nothing left to do.
        }
      }
    } finally {
      _recording = false;
    }
  }

  /// Flushes any bundles held in [fallbackStore] through the messenger now
  /// that the call is connected again. Fire-and-forget from [_onState]:
  /// never throws out, and never runs after [dispose].
  Future<void> _flushFallback() async {
    final store = fallbackStore;
    if (store == null || _disposed) return;
    if (store.pendingCount == 0) return;
    try {
      await store.flush((bundle) async {
        if (_disposed || messenger == null) return false;
        try {
          await sendAttachment(
            await messenger!(),
            Attachment(
              id: bundle.id,
              kind: MediaKind.file,
              contentType: 'audio/ogg',
              bytes: bundle.payload,
            ),
          );
          return true;
        } catch (_) {
          return false;
        }
      }, nowMs: _now().millisecondsSinceEpoch);
    } catch (_) {
      // Flush must never throw out of _onState.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopClipLoop();
    _stableTimer?.cancel();
    await _stateSub.cancel();
    await _decisionSub.cancel();
    await _foresightSub?.cancel();
  }
}
