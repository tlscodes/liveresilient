/// Drives `CallScreen` with a simulated call lifecycle — no signaling, no
/// media session, no network. Real calls go through the dev entry point in
/// `main.dart` instead; this controller only produces the plain [CallPhase]
/// data the screen renders.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/foundation.dart';

class CallDemoController extends ChangeNotifier {
  CallPhase phase = CallPhase.idle;
  int reconnectAttempt = 0;
  CallEndReason? endReason;
  bool audioOnly = false;

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
