/// Phase-2 record tests: (1) blind parameter recovery from arrival
/// gaps only, (2) planner calibration validated on the TRUE simulator,
/// (3) end-to-end RLNC transfer using the blind plan. All simulated,
/// all numbers measured in-run.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/blind_channel_estimator.dart';
import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:connection_orchestrator/src/gilbert_elliott_loss.dart';
import 'package:test/test.dart';

void main() {
  test('recovers Gilbert-Elliott parameters blindly from esi gaps', () {
    final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 3);
    final est = BlindChannelEstimator();
    for (var esi = 0; esi < 6000; esi++) {
      if (!ge.shouldDrop()) est.onReceivedEsi(esi);
    }
    final e = est.estimate();
    // ignore: avoid_print
    print(
      'blind estimate: $e (true p=0.04 r=0.1 gl=0.05 bl=0.95); '
      'mean burst est ${e.meanBurstLength.toStringAsFixed(1)} (true 10)',
    );
    expect(e.p, inInclusiveRange(0.02, 0.08), reason: 'p within 2x');
    expect(e.r, inInclusiveRange(0.05, 0.2), reason: 'r within 2x');
    expect(e.badLoss, greaterThan(0.8));
    expect(e.goodLoss, lessThan(0.15));
    expect(
      e.longRunLossRate,
      inInclusiveRange(0.25, 0.45),
      reason: 'true long-run loss is ~0.31',
    );
  });

  test('planner calibration: planned k reaches target on TRUE channel', () {
    final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 4);
    final est = BlindChannelEstimator();
    for (var esi = 0; esi < 6000; esi++) {
      if (!ge.shouldDrop()) est.onReceivedEsi(esi);
    }
    final plan = RedundancyPlanner(est.estimate());
    const blocks = 43; // one 2KB transfer
    final k = plan.planSendCount(blocks, targetSuccess: 0.99);
    var ok = 0;
    const trials = 300;
    final rng = Random(9);
    for (var t = 0; t < trials; t++) {
      final sim = GilbertElliottLossSimulator(
        p: 0.04,
        r: 0.1,
        seed: rng.nextInt(1 << 30),
      );
      var got = 0;
      for (var i = 0; i < k; i++) {
        if (!sim.shouldDrop()) got++;
      }
      if (got >= blocks) ok++;
    }
    final measured = ok / trials;
    // ignore: avoid_print
    print(
      'planner: k=$k for $blocks blocks @ target 0.99; '
      'measured success on true channel: ${measured.toStringAsFixed(3)}',
    );
    expect(
      measured,
      greaterThanOrEqualTo(0.97),
      reason: 'blind plan must hold within 2% of target',
    );
    expect(
      k,
      lessThan(blocks * 8),
      reason: 'plan must not be wastefully padded',
    );
  });

  test('end-to-end: RLNC + blind plan delivers a 2KB file open-loop', () {
    final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 5);
    final est = BlindChannelEstimator();
    for (var esi = 0; esi < 6000; esi++) {
      if (!ge.shouldDrop()) est.onReceivedEsi(esi);
    }
    final rng = Random(11);
    final data = Uint8List.fromList(
      List.generate(2048, (_) => rng.nextInt(256)),
    );
    final enc = RlncEncoder(data);
    final k = RedundancyPlanner(
      est.estimate(),
    ).planSendCount(enc.blockCount, targetSuccess: 0.995);
    var delivered = 0;
    final sim = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 77);
    final dec = RlncDecoder();
    for (var esi = 0; esi < k; esi++) {
      final d = enc.datagramAt(esi);
      if (!sim.shouldDrop()) {
        dec.addDatagram(d);
        delivered++;
      }
    }
    // ignore: avoid_print
    print(
      'end-to-end: sent k=$k, delivered=$delivered, '
      'N=${enc.blockCount}, complete=${dec.isComplete}',
    );
    expect(
      dec.isComplete,
      isTrue,
      reason: 'open-loop send of the planned k must suffice',
    );
    expect(dec.data, equals(data));
  });
}
