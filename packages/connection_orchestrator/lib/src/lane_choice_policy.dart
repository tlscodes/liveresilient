/// Chooses between the two payload-carriage schemes — plain retransmission
/// ('arq') and fountain coding ('fountain') — from measured link
/// conditions, and learns per condition cell which one actually delivers.
///
/// While a cell has little evidence, a deterministic rule decides: switch
/// to fountain at and above the rig-proven loss threshold. Once the cell
/// has enough recorded outcomes, decayed Laplace success estimates take
/// over — so field reality can overrule the static rule, per cell.
/// Every decision is explainable: [LaneChoiceDecision] names its source
/// and carries the numbers that decided it. Deterministic; no wall-clock
/// reads, no randomness.
library;

import 'lane_experience.dart' show DeliveryContext;

/// One explainable choice: which scheme, decided by what, on how much
/// evidence.
class LaneChoiceDecision {
  const LaneChoiceDecision({
    required this.choice,
    required this.source,
    required this.grounds,
    required this.cellKey,
    required this.samples,
  });

  /// 'arq' or 'fountain'.
  final String choice;

  /// 'fallback-rule' (thin evidence in this cell) or 'learned'.
  final String source;

  /// Literal sentence with the deciding numbers.
  final String grounds;

  /// The condition cell decided in: '<lossBand>|<rttBand>', 'x' for a
  /// missing condition — same band helpers as [DeliveryContext.key].
  final String cellKey;

  /// Recorded outcomes in this cell (undecayed count).
  final int samples;

  @override
  String toString() => 'LaneChoiceDecision($grounds)';
}

class _ChoiceStats {
  double successes = 0;
  double failures = 0;

  double get attempts => successes + failures;

  /// Laplace-smoothed success probability: an untried choice starts at 0.5.
  double get probability => (successes + 1) / (attempts + 2);

  void record({required bool success, required double decay}) {
    successes *= decay;
    failures *= decay;
    if (success) {
      successes += 1;
    } else {
      failures += 1;
    }
  }
}

class _Cell {
  /// Undecayed observation count: the min-samples gate must not drift
  /// down as the decayed estimates age.
  int observations = 0;
  final _ChoiceStats arq = _ChoiceStats();
  final _ChoiceStats fountain = _ChoiceStats();
}

/// Per-condition-cell learned preference between 'arq' and 'fountain',
/// with a deterministic fallback rule while evidence is thin.
class LaneChoicePolicy {
  LaneChoicePolicy({
    // 0.30: the proven arq-to-fountain switch loss from the network rig
    // (RIG_GUIDE loss 0.2/0.3 sections); also the l2/l3 band edge.
    this.fallbackLossThreshold = 0.30,
    // 5: below this many outcomes a Laplace estimate is mostly prior.
    this.minSamplesPerCell = 5,
    // 0.98: matches the LaneExperience decay so both memories age alike.
    this.decay = 0.98,
  });

  /// Loss fraction at and above which the fallback rule picks fountain.
  final double fallbackLossThreshold;

  /// Total recorded outcomes a cell needs before learned estimates
  /// overrule the fallback rule.
  final int minSamplesPerCell;

  /// Applied to a cell's old counts on every new observation there.
  final double decay;

  final Map<String, _Cell> _cells = {};

  static String _cellKey(double? lossFraction, double? rttMs) {
    final lossPart = lossFraction == null
        ? 'x'
        : DeliveryContext.lossBand(lossFraction);
    final rttPart = rttMs == null ? 'x' : DeliveryContext.rttBand(rttMs);
    return '$lossPart|$rttPart';
  }

  /// Picks 'arq' or 'fountain' for the given measured conditions.
  LaneChoiceDecision decide({double? lossFraction, double? rttMs}) {
    final cellKey = _cellKey(lossFraction, rttMs);
    final cell = _cells[cellKey];
    final samples = cell?.observations ?? 0;

    if (cell == null || samples < minSamplesPerCell) {
      final overThreshold =
          lossFraction != null && lossFraction >= fallbackLossThreshold;
      final choice = overThreshold ? 'fountain' : 'arq';
      final lossClause = lossFraction == null
          ? 'lossFraction unknown'
          : 'lossFraction ${lossFraction.toStringAsFixed(2)} '
                '${overThreshold ? '>=' : '<'} fallbackLossThreshold '
                '${fallbackLossThreshold.toStringAsFixed(2)}';
      return LaneChoiceDecision(
        choice: choice,
        source: 'fallback-rule',
        grounds:
            'fallback-rule: $samples samples < minSamplesPerCell '
            '$minSamplesPerCell in cell $cellKey; $lossClause -> $choice',
        cellKey: cellKey,
        samples: samples,
      );
    }

    final arqP = cell.arq.probability;
    final fountainP = cell.fountain.probability;
    // Ties go to arq: the plain scheme costs less, so it needs no edge.
    final choice = fountainP > arqP ? 'fountain' : 'arq';
    final margin = (arqP - fountainP).abs();
    return LaneChoiceDecision(
      choice: choice,
      source: 'learned',
      grounds:
          'learned: arq p ${arqP.toStringAsFixed(2)} vs fountain p '
          '${fountainP.toStringAsFixed(2)}, margin '
          '${margin.toStringAsFixed(2)}, $samples samples in cell '
          '$cellKey -> $choice',
      cellKey: cellKey,
      samples: samples,
    );
  }

  /// Feeds one observed outcome back into the cell the conditions map to.
  void record({
    required String choice,
    required double? lossFraction,
    required double? rttMs,
    required bool success,
  }) {
    assert(
      choice == 'arq' || choice == 'fountain',
      "choice must be 'arq' or 'fountain', got '$choice'",
    );
    if (choice != 'arq' && choice != 'fountain') return;
    final cell = _cells.putIfAbsent(_cellKey(lossFraction, rttMs), _Cell.new);
    cell.observations += 1;
    (choice == 'fountain' ? cell.fountain : cell.arq).record(
      success: success,
      decay: decay,
    );
  }

  /// Serializes the learned cells so the app can persist them.
  Map<String, Object?> toJson() => {
    'cells': {
      for (final e in _cells.entries)
        e.key: {
          'n': e.value.observations,
          'arq': {'s': e.value.arq.successes, 'f': e.value.arq.failures},
          'fountain': {
            's': e.value.fountain.successes,
            'f': e.value.fountain.failures,
          },
        },
    },
  };

  /// Restores a serialized policy. Corrupt entries are skipped: a damaged
  /// file degrades to a fresh policy (fallback rule), never a crash.
  factory LaneChoicePolicy.fromJson(
    Map<String, Object?> json, {
    // Defaults repeat the generative constructor's rig-derived values.
    double fallbackLossThreshold = 0.30,
    int minSamplesPerCell = 5,
    double decay = 0.98,
  }) {
    final policy = LaneChoicePolicy(
      fallbackLossThreshold: fallbackLossThreshold,
      minSamplesPerCell: minSamplesPerCell,
      decay: decay,
    );
    final cells = json['cells'];
    if (cells is Map) {
      for (final entry in cells.entries) {
        final key = entry.key;
        final v = entry.value;
        if (key is! String || v is! Map) continue;
        final n = v['n'];
        // isFinite first: NaN passes `< 0` and then throws on toInt().
        if (n is! num || !n.toDouble().isFinite || n < 0) continue;
        final cell = _Cell()..observations = n.toInt();
        if (!_restoreStats(v['arq'], cell.arq)) continue;
        if (!_restoreStats(v['fountain'], cell.fountain)) continue;
        policy._cells[key] = cell;
      }
    }
    return policy;
  }

  static bool _restoreStats(Object? raw, _ChoiceStats into) {
    if (raw is! Map) return false;
    final s = raw['s'];
    final f = raw['f'];
    if (s is! num || f is! num) return false;
    if (!s.toDouble().isFinite || !f.toDouble().isFinite) return false;
    if (s < 0 || f < 0) return false;
    into.successes = s.toDouble();
    into.failures = f.toDouble();
    return true;
  }
}
