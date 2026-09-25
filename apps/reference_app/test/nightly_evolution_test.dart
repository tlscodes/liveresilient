/// Pins the app-side champion/challenger loop («هوشمندی v4» pillar 3):
/// the power gate holds silently, a measured rise stages a candidate
/// generation and the NEXT boot wakes up with the promoted brains (prev
/// archived, candidate consumed), a vacuous round stages nothing but is
/// logged, and a corrupt candidate never blocks boot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/intelligence/intelligence_boot.dart';
import 'package:reference_app/src/intelligence/nightly_evolution.dart';
import 'package:reference_app/src/letter_rung_ladder.dart';

CallHistoryRecord _call({required int connectMs, required String network}) =>
    CallHistoryRecord(
      startedUtcMs: 1,
      connectMs: connectMs,
      recoveries: 0,
      dropsToFloor: 0,
      networkIdentityHash: network,
      endReason: 'hangup',
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nightly_evo_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<IntelligenceStack> boot() =>
      bootIntelligence(storageDirFactory: () => tempDir, nowMs: () => 1000);

  /// Three networks, each 100ms then 200ms: epoch 1 scores 2/3 with a
  /// fresh calibrator, the trained clone scores 1.0 — a strict rise
  /// (hand-verified in the package's brain_generations_test).
  void feedRisingHistory(IntelligenceStack stack) {
    for (final net in ['a', 'b', 'c']) {
      stack.hub.history.add(_call(connectMs: 100, network: net));
    }
    for (final net in ['a', 'b', 'c']) {
      stack.hub.history.add(_call(connectMs: 200, network: net));
    }
  }

  test('power gate holds: no run, no candidate, no log entry', () async {
    final stack = await boot();
    feedRisingHistory(stack);
    final decision = await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      powerGate: () async => false,
      nowMs: () => 7,
    );
    expect(decision, isNull);
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isFalse,
    );
    expect(readPromotionLog(tempDir), isEmpty);
    // A null gate (no platform probe bound) holds too, unless forced.
    final ungated = await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      nowMs: () => 8,
    );
    expect(ungated, isNull);
    await stack.dispose();
  });

  test('a measured rise stages a candidate and the next boot wakes up '
      'with the promoted brains', () async {
    final stack = await boot();
    feedRisingHistory(stack);
    // The live calibrator has no voice before the round.
    expect(stack.hub.calibrator.correction(), 1.0);
    final decision = (await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      powerGate: () async => true,
      nowMs: () => 7,
    ))!;
    expect(decision.promoted, isTrue);
    expect(decision.championScore, closeTo(2 / 3, 1e-12));
    expect(decision.challengerScore, closeTo(1.0, 1e-12));
    expect(decision.scoredCount, 3);
    // Staged, logged — and the LIVE brains were not touched.
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isTrue,
    );
    expect(stack.hub.calibrator.correction(), 1.0);
    final log = readPromotionLog(tempDir);
    expect(log.length, 1);
    expect(log.single.promoted, isTrue);
    await stack.dispose();

    // Next boot: candidate installed (consumed), prev archived, and the
    // promoted calibrator answers with its learned 2.0 correction.
    final reborn = await boot();
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isFalse,
    );
    expect(File('${tempDir.path}/generations/prev.json').existsSync(), isTrue);
    expect(reborn.hub.calibrator.correction(), 2.0);
    await reborn.dispose();
  });

  test("an empty door ladder never blocks a promotion decideGeneration "
      'already approved', () async {
    final stack = await boot();
    feedRisingHistory(stack);
    // Fresh file, nothing ever written to it: history() returns {}.
    final ladder = DoorResolverLadder(
      DiskJsonStorage(
        directoryFactory: () => tempDir,
        fileName: 'letter_door_resolvers.json',
      ),
    );
    final decision = (await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      powerGate: () async => true,
      nowMs: () => 7,
      doorResolverLadder: ladder,
    ))!;
    expect(decision.promoted, isTrue);
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isTrue,
    );
    await stack.dispose();
  });

  test('a dropped door win ratio withholds a candidate decideGeneration '
      'already approved', () async {
    final stack = await boot();
    feedRisingHistory(stack);
    final label = stack.hub.resolver.lastKnownLabel;

    // A prior round already promoted at ratio 0.8 for this network.
    File('${tempDir.path}/generations/ladder_ratio_at_promotion.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({label: 0.8}));

    // Today's door is doing much worse here: 2/10 = 0.2.
    final ladder = DoorResolverLadder(
      DiskJsonStorage(
        directoryFactory: () => tempDir,
        fileName: 'letter_door_resolvers.json',
      ),
    );
    for (var i = 0; i < 2; i++) {
      await ladder.record(label, asked: ['8.8.8.8'], winner: '8.8.8.8');
    }
    for (var i = 0; i < 8; i++) {
      await ladder.record(label, asked: ['8.8.8.8'], winner: null);
    }

    final decision = (await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      powerGate: () async => true,
      nowMs: () => 7,
      doorResolverLadder: ladder,
    ))!;

    // decideGeneration's own verdict is untouched by the second gate.
    expect(decision.promoted, isTrue);
    // The second gate withheld the file: no candidate this round.
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isFalse,
    );
    await stack.dispose();
  });

  test('a vacuous round stages nothing but is logged', () async {
    final stack = await boot();
    // One call per network: no budget pair anywhere, score is vacuous.
    stack.hub.history.add(_call(connectMs: 100, network: 'a'));
    stack.hub.history.add(_call(connectMs: 300, network: 'b'));
    final decision = (await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      force: true,
      nowMs: () => 7,
    ))!;
    expect(decision.promoted, isFalse);
    expect(decision.reason, contains('nothing measurable'));
    expect(
      File('${tempDir.path}/generations/candidate.json').existsSync(),
      isFalse,
    );
    expect(readPromotionLog(tempDir).length, 1);
    await stack.dispose();
  });

  test('a corrupt candidate is consumed and never blocks boot', () async {
    final candidate = File('${tempDir.path}/generations/candidate.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    final stack = await boot();
    expect(candidate.existsSync(), isFalse);
    expect(stack.hub.calibrator.correction(), 1.0);
    await stack.dispose();
  });

  test('promotion log entries round-trip through the file', () async {
    final stack = await boot();
    feedRisingHistory(stack);
    await runNightlyEvolution(
      hub: stack.hub,
      intelligenceDir: tempDir,
      force: true,
      nowMs: () => 7,
    );
    final raw = jsonDecode(
      File('${tempDir.path}/generations/promotion_log.json').readAsStringSync(),
    );
    expect(raw, isA<List<Object?>>());
    final restored = GenerationDecision.fromJson((raw as List).single)!;
    expect(restored.whenMs, 7);
    expect(restored.promoted, isTrue);
    await stack.dispose();
  });
}
