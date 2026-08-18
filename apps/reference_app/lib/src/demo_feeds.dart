/// Demo-labeled data sources for the standalone build.
///
/// HONESTY CONTRACT: everything in this file is synthetic and says so — the
/// diagnostics panel and gauge receive these streams together with a source
/// label ('synthetic demo profile'), so demo data never masquerades as radio
/// truth. On-device real wiring feeds the SAME seams from
/// `WebRtcPathChannel`'s measured RTCStats deltas (path_health_monitor.dart);
/// the widgets cannot tell the difference and never invent data themselves.
library;

import 'dart:async';
import 'dart:math' as math;

import 'ui/network_truth.dart';

/// Label shown by the diagnostics panel / gauge chip for these feeds.
const String demoQualitySourceLabel = 'synthetic demo profile';

/// Synthetic microphone envelope for the voice-note recorder UI: a smooth
/// speech-like amplitude in 0..1 at 20 Hz. Deterministic (pure function of
/// elapsed ticks) so goldens and widget tests can replay it.
Stream<double> syntheticAmplitudeSource() {
  int tick = 0;
  return Stream<double>.periodic(const Duration(milliseconds: 50), (_) {
    tick++;
    final t = tick / 20.0;
    // Two slow "syllable" waves plus a fast tremor, folded into 0..1.
    final syllable = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 0.9);
    final tremor = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 7.3);
    final v = 0.15 + 0.75 * (syllable * 0.7 + tremor * 0.3);
    return v.clamp(0.0, 1.0);
  });
}

/// Scripted network-quality profile: a loop that walks good → fair → poor →
/// recovery so the gauge, band chip and sparklines visibly live during a
/// demo. One reading per second; the script is a pure function of elapsed
/// seconds (deterministic, testable).
class DemoQualityFeed {
  DemoQualityFeed() {
    _controller = StreamController<CallQualityReading>.broadcast(
      onListen: _start,
      onCancel: _stopIfUnwatched,
    );
  }

  late final StreamController<CallQualityReading> _controller;
  Timer? _timer;
  int _seconds = 0;

  Stream<CallQualityReading> get stream => _controller.stream;

  /// Pure script: elapsed second → reading. 80-second loop with four acts.
  static CallQualityReading readingAt(int s) {
    final phase = s % 80;
    final int rtt;
    final double loss;
    final int rate;
    if (phase < 30) {
      // Act 1 — healthy: rtt 40-80ms, loss ~0-1%, ~900 kbps.
      rtt = 40 + ((math.sin(phase / 4.0) + 1) * 20).round();
      loss = 0.005 * (1 + math.sin(phase / 3.0)).abs();
      rate = 880000 + (phase % 5) * 8000;
    } else if (phase < 50) {
      // Act 2 — degrading: rtt climbs to ~450ms, loss to ~8%.
      final k = (phase - 30) / 20.0;
      rtt = (80 + 370 * k).round();
      loss = 0.01 + 0.07 * k;
      rate = (880000 * (1 - 0.6 * k)).round();
    } else if (phase < 62) {
      // Act 3 — hostile (the networks this stack was proven on): rtt ~900ms,
      // loss ~18%, rate near the survival floor.
      rtt = 820 + ((math.sin(phase.toDouble()) + 1) * 60).round();
      loss = 0.15 + 0.04 * (1 + math.sin(phase / 2.0)) / 2;
      rate = 22000 + (phase % 3) * 2500;
    } else {
      // Act 4 — recovery back toward healthy.
      final k = (phase - 62) / 18.0;
      rtt = (820 - 760 * k).round();
      loss = (0.17 * (1 - k)).clamp(0.0, 1.0);
      rate = (24000 + (880000 - 24000) * k).round();
    }
    return CallQualityReading(
      at: Duration(seconds: s),
      rttMs: rtt,
      lossFraction: double.parse(loss.toStringAsFixed(4)),
      bitrateBps: rate,
    );
  }

  void _start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _seconds++;
      if (!_controller.isClosed) _controller.add(readingAt(_seconds));
    });
  }

  void _stopIfUnwatched() {
    if (!_controller.hasListener) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _controller.close();
  }
}

/// A seeded [QualityHistory] so panels/goldens render populated sparklines
/// before the first live reading arrives.
QualityHistory seededDemoHistory({int seconds = 40}) {
  final h = QualityHistory();
  for (var s = 0; s < seconds; s++) {
    h.add(DemoQualityFeed.readingAt(s));
  }
  return h;
}
