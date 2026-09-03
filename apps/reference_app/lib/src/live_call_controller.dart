/// Drives `CallScreen` from a REAL session: `placeCall` opens a
/// [CallSessionHandle] through an injected opener, holds it, mirrors its
/// [CallController]'s states into the plain fields the screen renders, and
/// disposes it exactly once when the call ends — however it ends.
///
/// This replaces `CallDemoController` on the app's call tab. The demo
/// controller still exists for tests and previews; it changes a phase enum
/// on a timer and touches no network, which is exactly what the screen must
/// NOT be driven by when a person is deciding, on a bad link, whether to keep
/// talking.
///
/// Ownership rules, all of which the tests in `live_call_wiring_test.dart`
/// pin:
///  * the handle is disposed exactly once, by [_teardown], which swaps the
///    fields to null BEFORE awaiting anything — a second entrant finds
///    nothing and returns;
///  * the states subscription is cancelled BEFORE the handle is disposed,
///    because `CallController.dispose` on a live call emits
///    `ended(disposed)` synchronously and would overwrite the real reason;
///  * every mutation after an `await` is guarded by a generation token, so
///    a hang-up that lands while the opener is still in flight disposes the
///    late handle and can never resurrect the call.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/foundation.dart';

import 'call_session.dart' show CallSessionHandle, newSecureCallId;
import 'ui/network_truth.dart' show CallQualityReading;

/// Opens one session for [callId] in [role], or returns null when no session
/// could be built (the documented contract of `devConnectToLocalRelay` for a
/// relay that is not running). A thrown error is also a failure to open; the
/// controller keeps it for display.
typedef SessionOpener =
    Future<CallSessionHandle?> Function({
      required String callId,
      required CallRole role,
    });

/// The relay's accepted alphabet, bounded. App-minted keys are 22 characters
/// of unpadded base64url (see [newSecureCallId]); a hand-typed key from the
/// other side is accepted in the same alphabet so a peer's key pairs.
final RegExp _callKeyPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Returns the trimmed key when it can name a relay session, null otherwise.
String? validateCallKey(String raw) {
  final key = raw.trim();
  return _callKeyPattern.hasMatch(key) ? key : null;
}

class LiveCallController extends ChangeNotifier {
  LiveCallController({required this.open, this.mintCallId = newSecureCallId});

  /// Builds the session. Injected so widget tests supply fakes; production
  /// passes the dev relay entry point from `main.dart`.
  final SessionOpener open;

  /// Mints the id for each placed call. Same seam and same rule as the demo
  /// controller: a fresh id per call, never reused.
  final String Function() mintCallId;

  CallPhase phase = CallPhase.idle;
  int reconnectAttempt = 0;
  CallEndReason? endReason;
  DegradedMode? degradedMode;

  /// Id of the call in progress or the last one; null before any call.
  String? callId;

  /// Which side of the call this instance is: initiator for a placed call,
  /// receiver for a joined one; null before any call.
  CallRole? role;

  /// Why the session could not be opened or why the call failed, kept for
  /// display. Distinguishes "relay down" (opener returned null) from "bad
  /// signed manifest" (opener threw) — both are [CallEndReason
  /// .signalingFailure] on the phase axis.
  Object? error;

  CallSessionHandle? _handle;
  StreamSubscription<CallState>? _states;
  int _generation = 0;
  bool _disposed = false;

  /// The live session, while one exists; null otherwise. `main.dart` derives
  /// the charted readings from this, so the chart source and its label flip
  /// with teardown and there is nothing to keep in lock-step by hand.
  CallSessionHandle? get handle => _handle;

  /// Measured readings from the live path, null when no session is open.
  Stream<CallQualityReading>? get qualityReadings => _handle?.qualityReadings;

  /// True while a real session exists. The session builder captures audio
  /// only (`call_session.dart`, `audio: true, video: false`), so the screen's
  /// audio-only chip is truthful exactly when a session is held.
  bool get audioOnly => _handle != null;

  bool get canCall =>
      phase == CallPhase.idle ||
      phase == CallPhase.ended ||
      phase == CallPhase.failed;

  bool get canHangUp =>
      phase == CallPhase.connecting ||
      phase == CallPhase.negotiating ||
      phase == CallPhase.connected ||
      phase == CallPhase.degraded ||
      phase == CallPhase.reconnecting;

  /// Places a new call as the initiator under a freshly minted key.
  void placeCall() => unawaited(_open(mintCallId(), CallRole.initiator));

  /// Joins the call identified by [callKey] as the receiver.
  ///
  /// Throws [ArgumentError] for a key the relay would not accept, BEFORE any
  /// state changes — an invalid key never leaves idle.
  void joinCall(String callKey) {
    final key = validateCallKey(callKey);
    if (key == null) {
      throw ArgumentError.value(callKey, 'callKey', 'not a valid call key');
    }
    unawaited(_open(key, CallRole.receiver));
  }

  Future<void> _open(String id, CallRole callRole) async {
    if (!canCall || _disposed) return;
    // 1. Claim this attempt. Every await below re-checks the claim.
    final generation = ++_generation;
    callId = id;
    role = callRole;
    endReason = null;
    error = null;
    reconnectAttempt = 0;
    degradedMode = null;
    // 2. Synchronous: the screen shows "Connecting…" before any await, so
    //    a tap is acknowledged on the next frame, not when the relay answers.
    phase = CallPhase.connecting;
    _notify();

    CallSessionHandle? opened;
    try {
      opened = await open(callId: id, role: callRole);
    } on Object catch (e) {
      if (generation == _generation) _fail(CallEndReason.signalingFailure, e);
      return;
    }
    if (opened == null) {
      if (generation == _generation) {
        _fail(CallEndReason.signalingFailure, null);
      }
      return;
    }
    if (generation != _generation || _disposed) {
      // Hung up or disposed while the opener was in flight: the late handle
      // is ours to close, once, here — it is never stored, so no path can
      // start it or mirror its states.
      await opened.dispose();
      return;
    }
    _handle = opened;
    // Subscribe BEFORE start: `states` is a sync broadcast stream with no
    // replay, so a subscription made after start() would miss `connecting`.
    _states = opened.controller.states.listen(
      _onState,
      onError: (Object e, StackTrace _) {
        if (generation == _generation) error ??= e;
      },
    );
    _notify(); // qualityReadings now exists: the chart flips to live.
    unawaited(
      opened.controller.start().catchError((Object e) {
        // Only StateError can surface here (double start, or start after a
        // dispose that raced this opener); every other failure routes into
        // the controller's own recovery loop and reaches us via states.
        if (generation == _generation && identical(_handle, opened)) {
          _fail(CallEndReason.signalingFailure, e);
          unawaited(_teardown());
        }
      }),
    );
  }

  /// Ends the call from this side. With a live session the controller runs
  /// `ending -> ended(localHangup)` and the terminal state disposes the
  /// handle; while the opener is still in flight the attempt is abandoned
  /// and the late handle is disposed when it arrives.
  Future<void> hangUp() async {
    if (!canHangUp) return;
    final live = _handle;
    if (live == null) {
      _generation++;
      _fail(CallEndReason.localHangup, null, asEnded: true);
      return;
    }
    try {
      await live.controller.hangUp();
    } on StateError {
      // The controller was disposed under us (teardown raced the tap); the
      // terminal state has already been mirrored.
    }
  }

  void _onState(CallState state) {
    phase = state.phase;
    reconnectAttempt = state.reconnectAttempt;
    endReason = state.endReason;
    degradedMode = state is DegradedCallState ? state.mode : null;
    error ??= state.error;
    if (state.isTerminal) {
      // Fields already mirror the terminal state; the handle is released.
      unawaited(_teardown());
    }
    _notify();
  }

  void _fail(CallEndReason why, Object? cause, {bool asEnded = false}) {
    phase = asEnded ? CallPhase.ended : CallPhase.failed;
    endReason = why;
    error = cause;
    reconnectAttempt = 0;
    degradedMode = null;
    _notify();
  }

  /// Exactly-once release: swap the fields to null first, then cancel the
  /// subscription, then dispose the handle. A second entrant finds null.
  ///
  /// The cancel is detached, not awaited: `states` is a sync broadcast
  /// stream, so cancellation completes synchronously and the returned future
  /// is the SDK's shared root-zone `_nullFuture` — awaiting it under
  /// fake_async parks this function forever and the handle is never
  /// disposed (measured 2026-08-07 in call_core's teardown; same trap).
  Future<void> _teardown() async {
    final handle = _handle;
    final subscription = _states;
    _handle = null;
    _states = null;
    if (handle == null) return;
    unawaited(subscription?.cancel());
    await handle.dispose();
    _notify(); // qualityReadings is null now: the chart falls back, labelled.
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_teardown());
    super.dispose();
  }
}
