/// TrendMonitor v2: multi-channel evidence, grounded verdicts, and the
/// joint loss+rtt failingSoon trigger — with v1 score-only behavior pinned
/// unchanged.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  group('TrendMonitor v2 · score-only behavior matches v1', () {
    test('fewer than 3 samples is unknown, with literal grounds', () {
      final t = TrendMonitor();
      t.observe('net', 0.8, nowMs: 0);
      t.observe('net', 0.7, nowMs: 1000);
      expect(t.verdict('net'), TrendVerdict.unknown);
      final detail = t.verdictDetail('net');
      expect(detail.verdict, TrendVerdict.unknown);
      expect(detail.grounds, contains('fewer than 3 score samples (2)'));
    });

    test('flat trajectory is steady, steep slide is failingSoon', () {
      final t = TrendMonitor(horizonMs: 10000, floor: 0.2);
      for (var i = 0; i < 5; i++) {
        t.observe('flat', 0.8, nowMs: i * 1000);
        t.observe('sliding', 0.8 - i * 0.06, nowMs: i * 1000);
      }
      expect(t.verdict('flat'), TrendVerdict.steady);
      expect(t.verdict('sliding'), TrendVerdict.failingSoon);
      expect(t.projectedScore('sliding')!, lessThan(0.2));
    });

    test('gentle decline is slipping, not failingSoon', () {
      final t = TrendMonitor(horizonMs: 5000, floor: 0.2);
      for (var i = 0; i < 6; i++) {
        t.observe('lane', 0.9 - i * 0.02, nowMs: i * 1000);
      }
      expect(t.verdict('lane'), TrendVerdict.slipping);
    });

    test('verdict() delegates to verdictDetail()', () {
      final t = TrendMonitor();
      for (var i = 0; i < 5; i++) {
        t.observe('a', 0.8, nowMs: i * 1000);
        t.observe('b', 0.8 - i * 0.06, nowMs: i * 1000);
        t.observe('c', 0.9 - i * 0.02, nowMs: i * 1000);
      }
      t.observe('d', 0.5, nowMs: 0);
      for (final lane in ['a', 'b', 'c', 'd', 'never-seen']) {
        expect(t.verdict(lane), t.verdictDetail(lane).verdict);
      }
    });
  });

  group('TrendMonitor v2 · joint loss+rtt trigger', () {
    test('loss and rtt climbing together fire failingSoon while the same '
        'scores alone say steady', () {
      final joint = TrendMonitor();
      final scoreOnly = TrendMonitor();
      for (var i = 0; i < 4; i++) {
        // Score is flat and healthy; loss climbs 0.03/s, rtt 60ms/s.
        joint.observe(
          'net',
          0.8,
          nowMs: i * 1000,
          lossFraction: 0.10 + i * 0.03,
          rttMs: 100.0 + i * 60,
        );
        scoreOnly.observe('net', 0.8, nowMs: i * 1000);
      }
      expect(scoreOnly.verdict('net'), TrendVerdict.steady);
      final detail = joint.verdictDetail('net');
      expect(detail.verdict, TrendVerdict.failingSoon);
      expect(joint.verdict('net'), TrendVerdict.failingSoon);
      expect(detail.grounds, contains('lossSlopePerSec'));
      expect(detail.grounds, contains('rttInflationPerSec'));
    });

    test('loss climbing alone does not fire the joint trigger', () {
      final t = TrendMonitor();
      for (var i = 0; i < 4; i++) {
        t.observe('net', 0.8, nowMs: i * 1000, lossFraction: 0.10 + i * 0.03);
      }
      expect(t.verdict('net'), TrendVerdict.steady);
    });

    test('joint trigger needs 3 samples on both optional channels', () {
      final t = TrendMonitor();
      // Loss gets 4 samples, rtt only 2 — the joint trigger must not fire.
      for (var i = 0; i < 4; i++) {
        t.observe(
          'net',
          0.8,
          nowMs: i * 1000,
          lossFraction: 0.10 + i * 0.03,
          rttMs: i < 2 ? 100.0 + i * 60 : null,
        );
      }
      expect(t.evidence('net').rttInflationPerSec, isNull);
      expect(t.verdict('net'), TrendVerdict.steady);
    });
  });

  group('TrendMonitor v2 · evidence', () {
    test('slopes match hand-computed values on a fixed 4-sample series', () {
      final t = TrendMonitor();
      // Perfectly linear series at 0,1000,2000,3000 ms:
      //   score 0.9→0.6 = -0.1/s   loss 0.10→0.19 = +0.03/s
      //   rtt 100→280 = +60ms/s    deliveryRate 1.0→0.7 = -0.1/s
      final scores = [0.9, 0.8, 0.7, 0.6];
      final losses = [0.10, 0.13, 0.16, 0.19];
      final rtts = [100.0, 160.0, 220.0, 280.0];
      final rates = [1.0, 0.9, 0.8, 0.7];
      for (var i = 0; i < 4; i++) {
        t.observe(
          'net',
          scores[i],
          nowMs: i * 1000,
          lossFraction: losses[i],
          rttMs: rtts[i],
          deliveryRate: rates[i],
        );
      }
      final e = t.evidence('net');
      expect(e.scoreSlopePerSec!, closeTo(-0.1, 1e-9));
      // Projection: last score 0.6 + (-0.1/s * 10s default horizon) = -0.4.
      expect(e.projectedScore!, closeTo(-0.4, 1e-8));
      expect(e.lossSlopePerSec!, closeTo(0.03, 1e-9));
      expect(e.rttInflationPerSec!, closeTo(60.0, 1e-9));
      expect(e.deliveryRateSlopePerSec!, closeTo(-0.1, 1e-9));
      expect(e.sampleCount, 4);
      expect(e.windowMs, 3000);
    });

    test('channels never observed report null slopes', () {
      final t = TrendMonitor();
      for (var i = 0; i < 4; i++) {
        t.observe('net', 0.8, nowMs: i * 1000);
      }
      final e = t.evidence('net');
      expect(e.scoreSlopePerSec, isNotNull);
      expect(e.lossSlopePerSec, isNull);
      expect(e.rttInflationPerSec, isNull);
      expect(e.deliveryRateSlopePerSec, isNull);
    });

    test('an unknown lane reports empty evidence, not a crash', () {
      final t = TrendMonitor();
      final e = t.evidence('never-seen');
      expect(e.sampleCount, 0);
      expect(e.windowMs, 0);
      expect(e.scoreSlopePerSec, isNull);
      expect(e.projectedScore, isNull);
    });
  });

  group('TrendMonitor v2 · grounds carry the deciding numbers', () {
    test('projection grounds name the projected score and the floor', () {
      final t = TrendMonitor(horizonMs: 10000, floor: 0.2);
      // Slope -0.01/s from 0.27: last sample 0.24, projected 0.24-0.10=0.14.
      final scores = [0.27, 0.26, 0.25, 0.24];
      for (var i = 0; i < 4; i++) {
        t.observe('net', scores[i], nowMs: i * 1000);
      }
      final detail = t.verdictDetail('net');
      expect(detail.verdict, TrendVerdict.failingSoon);
      expect(detail.grounds, contains('projectedScore 0.14'));
      expect(detail.grounds, contains('floor 0.2'));
    });

    test('joint trigger grounds name both slopes and both thresholds', () {
      final t = TrendMonitor();
      for (var i = 0; i < 4; i++) {
        t.observe(
          'net',
          0.8,
          nowMs: i * 1000,
          lossFraction: 0.10 + i * 0.03,
          rttMs: 100.0 + i * 60,
        );
      }
      final detail = t.verdictDetail('net');
      expect(detail.verdict, TrendVerdict.failingSoon);
      expect(detail.grounds, contains('lossSlopePerSec 0.03'));
      expect(detail.grounds, contains('>= 0.02'));
      expect(detail.grounds, contains('rttInflationPerSec 60'));
      expect(detail.grounds, contains('>= 50'));
      expect(detail.evidence.lossSlopePerSec!, closeTo(0.03, 1e-9));
      expect(detail.evidence.rttInflationPerSec!, closeTo(60.0, 1e-9));
    });

    test('slipping grounds name the score slope and the threshold', () {
      final t = TrendMonitor(horizonMs: 5000, floor: 0.2);
      for (var i = 0; i < 6; i++) {
        t.observe('lane', 0.9 - i * 0.02, nowMs: i * 1000);
      }
      final detail = t.verdictDetail('lane');
      expect(detail.verdict, TrendVerdict.slipping);
      expect(detail.grounds, contains('scoreSlopePerSec -0.02'));
      expect(detail.grounds, contains('slipSlopePerSec -0.01'));
    });
  });
}
