import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  group('DeliveryPlanner · energy awareness', () {
    const planner = DeliveryPlanner();
    final ctx = DeliveryContext.at(9 * 3600 * 1000);

    PlannerLaneView lane(String id, double h, {int energy = 0}) =>
        PlannerLaneView(
          id: id,
          healthScore: h,
          learnedScore: h,
          costRank: 0,
          energyRank: energy,
        );

    test('normal battery: the hungrier radio still wins on health', () {
      final plan = planner.plan(
        lanes: [lane('hungry', 0.72, energy: 3), lane('frugal', 0.68)],
        context: ctx,
        urgent: false,
      );
      expect(plan.laneIds.first, 'hungry');
    });

    test('low battery: the frugal lane wins the near-tie', () {
      final plan = planner.plan(
        lanes: [lane('hungry', 0.72, energy: 3), lane('frugal', 0.68)],
        context: ctx,
        urgent: false,
        lowBattery: true,
      );
      expect(plan.laneIds.first, 'frugal');
    });

    test('low battery never blocks a clearly better lane', () {
      final plan = planner.plan(
        lanes: [lane('hungry', 0.9, energy: 2), lane('frugal', 0.3)],
        context: ctx,
        urgent: false,
        lowBattery: true,
      );
      expect(plan.laneIds.first, 'hungry');
    });
  });

  group('DeliveryLedger', () {
    test('records once, flags duplicates, bounded eviction', () {
      final ledger = DeliveryLedger(capacity: 3);
      expect(ledger.record('a'), isTrue);
      expect(ledger.record('a'), isFalse);
      expect(ledger.isDuplicate('a'), isTrue);
      ledger.record('b');
      ledger.record('c');
      ledger.record('d'); // evicts 'a'
      expect(ledger.count, 3);
      expect(ledger.isDuplicate('a'), isFalse);
      expect(ledger.isDuplicate('d'), isTrue);
    });

    test('survives serialize/restore', () {
      final ledger = DeliveryLedger()
        ..record('x')
        ..record('y');
      final reborn = DeliveryLedger()..restore(ledger.toJson());
      expect(reborn.isDuplicate('x'), isTrue);
      expect(reborn.isDuplicate('z'), isFalse);
    });
  });
}
