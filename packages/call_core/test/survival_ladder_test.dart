/// The dying-bandwidth scenario: capacity collapses from 500 kbps to
/// 200 bps and recovers; the ladder must never be without an active
/// rung, walk one step at a time, and climb back without flapping.
library;

import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

void main() {
  test('budget table is strictly decreasing best-to-last', () {
    final values = [
      for (final r in SurvivalRung.values) survivalRungMinBps[r]!
    ];
    for (var i = 1; i < values.length; i++) {
      expect(values[i], lessThan(values[i - 1]));
    }
    expect(values.last, 0, reason: 'last rung must work at zero budget');
  });

  test('dying link: every capacity level maps to SOME rung, down to '
      '200 bps and even 0', () {
    for (final bps in [500000, 100000, 20000, 5000, 1500, 800, 200, 0]) {
      expect(() => rungForCapacity(bps), returnsNormally);
    }
    expect(rungForCapacity(200), SurvivalRung.textOnly);
    expect(rungForCapacity(800), SurvivalRung.voiceNotes);
    expect(rungForCapacity(1000), SurvivalRung.tokenVoiceRow0);
    expect(rungForCapacity(1600), SurvivalRung.tokenVoiceFull);
    expect(rungForCapacity(0), SurvivalRung.textOnly);
  });

  test('gradual death 500kbps -> 200bps: rung always active, transitions '
      'pass through every intermediate step in order', () {
    final ladder = SurvivalLadder();
    final seen = <SurvivalRung>[ladder.current];
    for (final bps in [400000, 120000, 20000, 5000, 1500, 1000, 500, 200]) {
      seen.add(ladder.report(bps));
    }
    expect(seen.last, SurvivalRung.textOnly);
    // The walked path covers every rung between start and floor, in order.
    final indices = [for (final r in seen) r.index];
    for (var i = 1; i < indices.length; i++) {
      expect(indices[i] - indices[i - 1], inInclusiveRange(0, 7));
      expect(indices[i], greaterThanOrEqualTo(indices[i - 1]));
    }
  });

  test('sudden total collapse still walks through each rung (layers can '
      'react), ending at textOnly', () {
    final ladder = SurvivalLadder();
    ladder.report(0);
    expect(ladder.current, SurvivalRung.textOnly);
    // 7 downward steps happened, not one jump.
    expect(ladder.transitions, SurvivalRung.values.length - 1);
  });

  test('at 200 bps the conversation continues in textOnly; at 1000 bps '
      'the token-voice row0 rung carries LIVE voice', () {
    final ladder = SurvivalLadder();
    ladder.report(1000);
    expect(ladder.current, SurvivalRung.tokenVoiceRow0);
    ladder.report(200);
    expect(ladder.current, SurvivalRung.textOnly);
  });

  test('recovery climbs exactly one rung per sustained window, with '
      'headroom, and never flaps at a boundary', () {
    final ladder = SurvivalLadder(climbAfter: 3);
    ladder.report(200); // collapse to textOnly
    final t0 = ladder.transitions;

    // capacity exactly at voiceNotes minimum: no headroom -> no climb
    for (var i = 0; i < 10; i++) {
      ladder.report(300);
    }
    expect(ladder.current, SurvivalRung.textOnly);

    // solid 1 kbps: climb to voiceNotes after 3 reports, then row0 …
    for (var i = 0; i < 3; i++) {
      ladder.report(1200);
    }
    expect(ladder.current, SurvivalRung.voiceNotes);
    for (var i = 0; i < 3; i++) {
      ladder.report(1200);
    }
    expect(ladder.current, SurvivalRung.tokenVoiceRow0);
    // …but 1200 bps has no headroom for tokenVoiceFull (needs 2000):
    for (var i = 0; i < 10; i++) {
      ladder.report(1200);
    }
    expect(ladder.current, SurvivalRung.tokenVoiceRow0);
    expect(ladder.transitions - t0, 2, reason: 'no flapping');

    // full recovery climbs one rung per window up to fullVideo
    for (var i = 0; i < 30; i++) {
      ladder.report(1000000);
    }
    expect(ladder.current, SurvivalRung.fullVideo);
  });

  test('flapping capacity around a boundary does not oscillate rungs', () {
    final ladder = SurvivalLadder(climbAfter: 3);
    ladder.report(900); // tokenVoiceRow0
    final before = ladder.transitions;
    // alternate 900/1900: 1900 has no 1.25x headroom for full (2000)
    for (var i = 0; i < 20; i++) {
      ladder.report(i.isEven ? 1900 : 900);
    }
    expect(ladder.current, SurvivalRung.tokenVoiceRow0);
    expect(ladder.transitions, before, reason: 'zero extra transitions');
  });
}
