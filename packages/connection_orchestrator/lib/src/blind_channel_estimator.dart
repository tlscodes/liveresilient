/// Blind channel estimation + predictive redundancy planning — the
/// phase-2 upgrade from "survives the hostile channel" to "models it".
///
/// The receiver sees which ESIs arrived; the gaps between them are a
/// binary loss sequence. From that sequence alone (no probes, no
/// feedback), [BlindChannelEstimator] fits a 2-state Gilbert-Elliott
/// model with a small fixed-point EM (Baum-Welch) pass: states G/B,
/// transition p (G->B) and r (B->G), loss rates in each state.
///
/// [RedundancyPlanner] then answers the sender-side question: "how many
/// datagrams must I send so a generation of m blocks decodes with
/// probability >= target?" It Monte-Carlo-walks the ESTIMATED chain
/// (deterministic seed — reproducible), so the plan degrades gracefully
/// with estimate quality. The tests validate BOTH: parameter recovery
/// against the true simulator, and planner calibration measured on the
/// TRUE channel.
///
/// No feedback is introduced anywhere: estimates live on the receiver;
/// a real deployment ships them on the existing DTN back-channel
/// out-of-band and stale estimates only cost overhead, never
/// correctness (the code is rateless).
library;

import 'dart:typed_data';

class GilbertElliottEstimate {
  GilbertElliottEstimate(this.p, this.r, this.goodLoss, this.badLoss);

  /// P(G->B) per datagram.
  final double p;

  /// P(B->G) per datagram; mean burst length = 1/r.
  final double r;
  final double goodLoss;
  final double badLoss;

  double get meanBurstLength => r > 0 ? 1 / r : double.infinity;
  double get stationaryBad => (p + r) > 0 ? p / (p + r) : 0;
  double get longRunLossRate =>
      stationaryBad * badLoss + (1 - stationaryBad) * goodLoss;

  @override
  String toString() =>
      'GE(p=${p.toStringAsFixed(4)}, r=${r.toStringAsFixed(4)}, '
      'gl=${goodLoss.toStringAsFixed(3)}, bl=${badLoss.toStringAsFixed(3)})';
}

class BlindChannelEstimator {
  final List<bool> _lost = <bool>[];
  int _lastEsi = -1;

  int get sampleCount => _lost.length;

  /// Feed the ESI of each datagram that ARRIVED (in send order).
  /// Gaps become loss samples; the arrival itself a success sample.
  void onReceivedEsi(int esi) {
    if (esi <= _lastEsi) return; // reordered duplicate — already counted
    for (var missing = _lastEsi + 1; missing < esi; missing++) {
      _lost.add(true);
    }
    _lost.add(false);
    _lastEsi = esi;
  }

  /// EM fit (Baum-Welch, [iterations] passes) of the 2-state model.
  GilbertElliottEstimate estimate({int iterations = 15}) {
    final o = _lost;
    final t = o.length;
    if (t < 50) {
      // Too little signal: fall back to the memoryless estimate.
      final f = o.isEmpty ? 0.5 : o.where((x) => x).length / o.length;
      return GilbertElliottEstimate(0.01, 0.1, f, f);
    }
    var p = 0.05, r = 0.15, lg = 0.05, lb = 0.9;
    for (var it = 0; it < iterations; it++) {
      // Forward-backward with scaling.
      final alphaG = Float64List(t), alphaB = Float64List(t);
      final betaG = Float64List(t), betaB = Float64List(t);
      final scale = Float64List(t);
      double eg(int i) => o[i] ? lg : 1 - lg;
      double eb(int i) => o[i] ? lb : 1 - lb;
      final piB = p / (p + r);
      alphaG[0] = (1 - piB) * eg(0);
      alphaB[0] = piB * eb(0);
      scale[0] = alphaG[0] + alphaB[0];
      alphaG[0] /= scale[0];
      alphaB[0] /= scale[0];
      for (var i = 1; i < t; i++) {
        alphaG[i] = (alphaG[i - 1] * (1 - p) + alphaB[i - 1] * r) * eg(i);
        alphaB[i] = (alphaG[i - 1] * p + alphaB[i - 1] * (1 - r)) * eb(i);
        scale[i] = alphaG[i] + alphaB[i];
        if (scale[i] == 0) scale[i] = 1e-300;
        alphaG[i] /= scale[i];
        alphaB[i] /= scale[i];
      }
      betaG[t - 1] = 1;
      betaB[t - 1] = 1;
      for (var i = t - 2; i >= 0; i--) {
        final bg = betaG[i + 1] * eg(i + 1);
        final bb = betaB[i + 1] * eb(i + 1);
        betaG[i] = ((1 - p) * bg + p * bb) / scale[i + 1];
        betaB[i] = (r * bg + (1 - r) * bb) / scale[i + 1];
      }
      // Accumulate expected transitions and emissions.
      var nGB = 0.0, nG = 0.0, nBG = 0.0, nB = 0.0;
      var lossG = 0.0, occG = 0.0, lossB = 0.0, occB = 0.0;
      for (var i = 0; i < t; i++) {
        final gG = alphaG[i] * betaG[i];
        final gB = alphaB[i] * betaB[i];
        final z = gG + gB;
        final wG = z > 0 ? gG / z : 0.5;
        final wB = 1 - wG;
        occG += wG;
        occB += wB;
        if (o[i]) {
          lossG += wG;
          lossB += wB;
        }
        if (i + 1 < t) {
          final bg = betaG[i + 1] * eg(i + 1) / scale[i + 1];
          final bb = betaB[i + 1] * eb(i + 1) / scale[i + 1];
          final xGG = alphaG[i] * (1 - p) * bg;
          final xGB = alphaG[i] * p * bb;
          final xBG = alphaB[i] * r * bg;
          final xBB = alphaB[i] * (1 - r) * bb;
          final zz = xGG + xGB + xBG + xBB;
          if (zz > 0) {
            nGB += xGB / zz;
            nG += (xGG + xGB) / zz;
            nBG += xBG / zz;
            nB += (xBG + xBB) / zz;
          }
        }
      }
      p = (nG > 0 ? nGB / nG : p).clamp(1e-4, 0.5);
      r = (nB > 0 ? nBG / nB : r).clamp(1e-4, 0.9);
      lg = (occG > 0 ? lossG / occG : lg).clamp(0.0, 0.49);
      lb = (occB > 0 ? lossB / occB : lb).clamp(0.51, 1.0);
    }
    return GilbertElliottEstimate(p, r, lg, lb);
  }
}

class RedundancyPlanner {
  RedundancyPlanner(this.estimate);

  final GilbertElliottEstimate estimate;

  /// Smallest send count k such that, walking the ESTIMATED chain,
  /// P(at least [blocks] arrivals among k sends) >= [targetSuccess].
  /// Deterministic Monte-Carlo (seeded) so plans are reproducible.
  int planSendCount(
    int blocks, {
    double targetSuccess = 0.99,
    int trials = 400,
    int seed = 1,
  }) {
    var k = (blocks / (1 - estimate.longRunLossRate)).ceil();
    final kMax = blocks * 60;
    while (k < kMax) {
      var ok = 0;
      var s = seed;
      int next() {
        s ^= (s << 13) & 0xFFFFFFFF;
        s ^= s >> 17;
        s ^= (s << 5) & 0xFFFFFFFF;
        return s;
      }

      double u() => next() / 4294967296.0;
      for (var tr = 0; tr < trials; tr++) {
        var bad = u() < estimate.stationaryBad;
        var got = 0;
        for (var i = 0; i < k && got < blocks; i++) {
          final lossP = bad ? estimate.badLoss : estimate.goodLoss;
          if (u() >= lossP) got++;
          bad = bad ? (u() >= estimate.r) : (u() < estimate.p);
        }
        if (got >= blocks) ok++;
      }
      if (ok / trials >= targetSuccess) return k;
      k = (k * 1.08).ceil() + 1;
    }
    return kMax;
  }
}
