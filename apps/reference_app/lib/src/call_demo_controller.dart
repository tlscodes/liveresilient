/// Drives `CallScreen` with a simulated call lifecycle — no signaling, no
/// media session, no network. Real calls go through the dev entry point in
/// `main.dart` instead; this controller only produces the plain [CallPhase]
/// data the screen renders.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/foundation.dart';

import 'call_session.dart' show newSecureCallId;

class CallDemoController extends ChangeNotifier {
  /// Mints the id for each new call. Injectable so a test can assert what
  /// the controller asked for; production never overrides it.
  CallDemoController({this.mintCallId = newSecureCallId});

  final String Function() mintCallId;

  CallPhase phase = CallPhase.idle;
  int reconnectAttempt = 0;
  CallEndReason? endReason;
  bool audioOnly = false;

  /// Id of the call in progress, minted when it was placed; null when no
  /// call has been placed yet.
  ///
  /// This is also the border relay's session id, which is why it is drawn
  /// from the platform CSPRNG rather than counted up or derived from a
  /// room name — see [newSecureCallId].
  String? callId;

  Timer? _timer;

  bool get canCall =>
      phase == CallPhase.idle ||
      phase == CallPhase.ended ||
      phase == CallPhase.failed;

  bool get canHangUp =>
      phase == CallPhase.connecting ||
      phase == CallPhase.negotiating ||
      phase == CallPhase.connected ||
      phase == CallPhase.reconnecting;

  /// Simulates placing a call: connecting -> negotiating -> connected.
  void placeCall() {
    _timer?.cancel();
    endReason = null;
    audioOnly = false;
    // A fresh id per call, never reused: an id that outlived its call
    // would let anyone who saw it rejoin the next one on the relay.
    callId = mintCallId();
    phase = CallPhase.connecting;
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 250), () {
      phase = CallPhase.negotiating;
      notifyListeners();
      _timer = Timer(const Duration(milliseconds: 250), () {
        phase = CallPhase.connected;
        notifyListeners();
      });
    });
  }

  /// Simulates a graceful local hang-up: ending -> ended.
  void hangUp() {
    _timer?.cancel();
    phase = CallPhase.ending;
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 200), () {
      phase = CallPhase.ended;
      endReason = CallEndReason.localHangup;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
