/// Offline replay benchmark — the aliveness gate for the learning brains.
///
/// Replays the T2 rig's recorded history (`tools/t2/replay_corpus/*.json`
/// plus every row of `tools/t2/h2_results.tsv`) through the four learning
/// components and scores each epoch. The three persistent brains
/// ([NetworkAtlas], [LaneChoicePolicy], [BudgetCalibrator]) carry their
/// state across epochs, so an epoch trained on prior passes must predict
/// better than epoch 0 — that measured rise is the aliveness gate.
///
/// Honesty notes, stated up front:
/// - The trendLeadTime component measures the DETECTOR ([TrendMonitor],
///   rebuilt fresh per run because trend state is per-call by design), so
///   it is epoch-constant. It anchors the report; it cannot rise.
/// - The laneChoiceRegret best-choice map uses the package's own Laplace
///   (s+1)/(n+2) success estimate (the [LaneChoicePolicy] convention:
///   an untried scheme keeps its 0.5 prior). With a plain empirical
///   argmax an untried scheme could never be "best", which contradicts
///   the policy's own learning limit and turns the metric into a
///   measurement of that convention clash instead of learning.
/// - Fully deterministic: no randomness, no wall-clock reads; time is a
///   synthetic counter injected by this library's caller or derived from
///   recorded timestamps.
library;

import 'budget_calibrator.dart';
import 'lane_choice_policy.dart';
import 'lane_experience.dart' show DeliveryContext;
import 'measurement_journal.dart';
import 'network_atlas.dart';
import 'trend_monitor.dart';

/// One timeline event from a recorded rig run.
class ReplayEvent {
  const ReplayEvent({
    required this.tS,
    required this.kind,
    required this.name,
    this.role,
    this.detail,
  });

  /// Seconds from the run's capture start.
  final double tS;

  /// Event family: 'pcStatus', 'phase', 'localCand', 'signal', … Unknown
  /// kinds are carried but ignored by the scoring.
  final String kind;

  /// Event name inside its family (for pcStatus: 'connected',
  /// 'disconnected', 'failed', 'connecting').
  final String name;

  /// Which endpoint reported it, when recorded.
  final String? role;

  /// Free-text payload, when recorded.
  final String? detail;

  /// Null when the map is not event-shaped (missing t_s/kind/name).
  static ReplayEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t_s'];
    final kind = json['kind'];
    final name = json['name'];
    if (t is! num || kind is! String || name is! String) return null;
    final role = json['role'];
    final detail = json['detail'];
    return ReplayEvent(
      tS: t.toDouble(),
      kind: kind,
      name: name,
      role: role is String ? role : null,
      detail: detail is String ? detail : null,
    );
  }
}

/// One parsed row of `h2_results.tsv` — one recorded test outcome.
///
/// Both row shapes of the file are accepted: the 15-column shape
/// (columns date profile test verdict rtt_ms loss_pct packets elapsed_ms
/// connect_ms ack_p50 ack_p95 ack_loss recovery_ms alive note — order
/// verified against the corpus copy of row 2026-08-09T22:18:44Z, whose
/// tsvRow names every field) and the early 9-column shape (the same
/// first 8 columns plus note), which lacks the connect/recovery/alive
/// columns. Old rows still train the condition brains: all history
/// feeds the brains.
class TsvOutcome {
  const TsvOutcome({
    required this.date,
    required this.profile,
    required this.test,
    required this.verdict,
    required this.note,
    this.rttMs,
    this.lossPct,
    this.connectMs,
    this.recoveryMs,
    this.alive,
  });

  /// ISO-8601 UTC timestamp string; lexicographic order is time order.
  final String date;

  /// The rig's shaped profile name ('clean', 'loss60', 'extreme', …).
  final String profile;

  /// Test file the row came from.
  final String test;

  /// 'PASS', 'PASS/STRESS', 'FAIL', 'FAIL/STRESS', 'TOOLING/NO-ATTACH', …
  final String verdict;

  /// Free-text tail of the row.
  final String note;

  /// Measured round-trip in ms; null when the column was '-' or absent.
  final double? rttMs;

  /// Measured loss in percent (0..100); null when unmeasured.
  final double? lossPct;

  /// Measured connect time in ms; null when unmeasured.
  final double? connectMs;

  /// Measured recovery time in ms; null when unmeasured.
  final double? recoveryMs;

  /// 'True' / 'False' from the alive column; null when absent.
  final String? alive;

  /// Loss as a 0..1 fraction, the unit the brains train on.
  double? get lossFraction {
    final pct = lossPct;
    // 100: percent-to-fraction conversion.
    return pct == null ? null : pct / 100.0;
  }

  /// Success per the benchmark contract: verdict starts with PASS
  /// (covers 'PASS' and 'PASS/STRESS').
  bool get success => verdict.startsWith('PASS');

  static double? _num(String cell) =>
      cell == '-' ? null : double.tryParse(cell);

  /// Null for the header row and any row with an unknown column count.
  static TsvOutcome? fromTsvColumns(List<String> cols) {
    if (cols.isEmpty || cols.first == 'date') return null;
    // 15: the current row shape; 9: the early shape (both described in
    // the class doc). Anything else is not a data row.
    if (cols.length == 15) {
      return TsvOutcome(
        date: cols[0],
        profile: cols[1],
        test: cols[2],
        verdict: cols[3],
        rttMs: _num(cols[4]),
        lossPct: _num(cols[5]),
        // Column 8 = connect_ms, 12 = recovery_ms, 13 = alive: order
        // verified against the corpus tsvRow copy (see class doc).
        connectMs: _num(cols[8]),
        recoveryMs: _num(cols[12]),
        alive: cols[13] == '-' ? null : cols[13],
        note: cols[14],
      );
    }
    if (cols.length == 9) {
      return TsvOutcome(
        date: cols[0],
        profile: cols[1],
        test: cols[2],
        verdict: cols[3],
        rttMs: _num(cols[4]),
        lossPct: _num(cols[5]),
        note: cols[8],
      );
    }
    return null;
  }

  /// Parses the whole tsv text; header and malformed rows are skipped.
  static List<TsvOutcome> parseTable(String tsvText) {
    final out = <TsvOutcome>[];
    for (final line in tsvText.split('\n')) {
      if (line.isEmpty) continue;
      final row = fromTsvColumns(line.split('\t'));
      if (row != null) out.add(row);
    }
    return out;
  }
}

/// One recorded rig run: the tsv row it belongs to, its event timeline,
/// its per-second packet counts, and its summary text.
class ReplayRun {
  const ReplayRun({
    required this.runDir,
    required this.capturedUtc,
    required this.row,
    required this.events,
    required this.packetsBySecond,
    required this.summariesText,
  });

  /// Rig-side directory the capture came from; stable sort tiebreak.
  final String runDir;

  /// ISO-8601 UTC capture timestamp.
  final String capturedUtc;

  /// The tsv row embedded in the capture.
  final TsvOutcome row;

  /// Timeline events, in file order.
  final List<ReplayEvent> events;

  /// second -> packets seen that second; empty when no capture exists.
  final Map<int, int> packetsBySecond;

  /// All summary blocks (SLA/MSG/VID) joined, for lane-choice inference.
  final String summariesText;

  /// Hour of day (0..23) parsed from [capturedUtc]; null when malformed.
  int? get capturedHour {
    // 11..13: the hour digits of an ISO-8601 'YYYY-MM-DDTHH:MM:SSZ'.
    if (capturedUtc.length < 13) return null;
    return int.tryParse(capturedUtc.substring(11, 13));
  }

  /// Null when the map is not a corpus run (e.g. the corpus index file,
  /// which has no tsvRow).
  static ReplayRun? fromJson(Map<String, Object?> json) {
    final rawRow = json['tsvRow'];
    if (rawRow is! Map) return null;
    final cells = <String, String>{
      for (final e in rawRow.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
    String cell(String key) => cells[key] ?? '-';
    final row = TsvOutcome(
      date: cell('date'),
      profile: cell('profile'),
      test: cell('test'),
      verdict: cell('verdict'),
      rttMs: TsvOutcome._num(cell('rtt_ms')),
      lossPct: TsvOutcome._num(cell('loss_pct')),
      connectMs: TsvOutcome._num(cell('connect_ms')),
      recoveryMs: TsvOutcome._num(cell('recovery_ms')),
      alive: cell('alive') == '-' ? null : cell('alive'),
      note: cell('note'),
    );
    final events = <ReplayEvent>[];
    final rawEvents = json['events'];
    if (rawEvents is List) {
      for (final e in rawEvents) {
        final parsed = ReplayEvent.fromJson(e);
        if (parsed != null) events.add(parsed);
      }
    }
    final packets = <int, int>{};
    final rawSeries = json['packetSeries'];
    if (rawSeries is Map) {
      for (final e in rawSeries.entries) {
        final key = e.key;
        final value = e.value;
        if (key is! String || value is! Map) continue;
        final sec = int.tryParse(key);
        final count = value['packets'];
        if (sec == null || count is! num) continue;
        packets[sec] = count.toInt();
      }
    }
    final summaryParts = <String>[];
    final rawSummaries = json['summaries'];
    if (rawSummaries is Map) {
      for (final v in rawSummaries.values) {
        summaryParts.add('$v');
      }
    }
    final runDir = json['runDir'];
    final capturedUtc = json['capturedUtc'];
    return ReplayRun(
      runDir: runDir is String ? runDir : '',
      capturedUtc: capturedUtc is String ? capturedUtc : '',
      row: row,
      events: events,
      packetsBySecond: packets,
      summariesText: summaryParts.join('\n'),
    );
  }
}

/// The learning brains one benchmark epoch trains and scores.
///
/// Three brains persist across epochs and serialize ([atlas],
/// [laneChoice], [calibrator]). The trend monitor is deliberately NOT a
/// field holding state: trend state is per-call, never persisted, so the
/// set carries a factory that builds a fresh monitor per replayed run.
class BrainSet {
  BrainSet({
    required this.atlas,
    required this.laneChoice,
    required this.calibrator,
    required this.journal,
    this.newTrendMonitor = TrendMonitor.new,
  });

  /// Persistent brain 1: per-network physics memory.
  final NetworkAtlas atlas;

  /// Persistent brain 2: arq-vs-fountain choice memory.
  final LaneChoicePolicy laneChoice;

  /// Persistent brain 3: connect-budget correction memory.
  final BudgetCalibrator calibrator;

  /// Citation log: every whatChanged line cites an id recorded here.
  final MeasurementJournal journal;

  /// Builds the fresh-per-run trend detector (see class doc).
  final TrendMonitor Function() newTrendMonitor;

  /// Serializes the three persistent brains only.
  Map<String, Object?> toJson() => {
    'atlas': atlas.toJson(),
    'laneChoice': laneChoice.toJson(),
    'calibrator': calibrator.toJson(),
  };

  /// Restores the three persistent brains; a malformed section restores
  /// as a fresh brain, matching each brain's own corrupt-file contract.
  factory BrainSet.fromJson(
    Map<String, Object?> json, {
    required MeasurementJournal journal,
    TrendMonitor Function() newTrendMonitor = TrendMonitor.new,
  }) {
    final rawAtlas = json['atlas'];
    final rawLane = json['laneChoice'];
    final rawCalibrator = json['calibrator'];
    return BrainSet(
      atlas: rawAtlas is Map<String, Object?>
          ? NetworkAtlas.fromJson(rawAtlas)
          : NetworkAtlas(),
      laneChoice: rawLane is Map<String, Object?>
          ? LaneChoicePolicy.fromJson(rawLane)
          : LaneChoicePolicy(),
      calibrator: rawCalibrator is Map<String, Object?>
          ? BudgetCalibrator.fromJson(rawCalibrator)
          : BudgetCalibrator(),
      journal: journal,
      newTrendMonitor: newTrendMonitor,
    );
  }
}

/// One component's epoch result: the raw score and the same score
/// normalized by the component's epoch-0 raw value.
class ComponentScore {
  const ComponentScore({required this.raw, required this.normalized});

  /// The component's own scale (each component doc states it).
  final double raw;

  /// raw / epoch0Raw, so epoch 0 is exactly 1.0.
  final double normalized;

  Map<String, Object?> toJson() => {'raw': raw, 'normalized': normalized};
}

/// Everything one epoch produced.
class EpochReport {
  const EpochReport({
    required this.epoch,
    required this.trendLeadTime,
    required this.laneChoiceRegret,
    required this.calibrator,
    required this.atlas,
    required this.score,
    required this.whatChanged,
    required this.notes,
  });

  /// 0-based epoch index within one [ReplayBenchmark] instance.
  final int epoch;

  /// Detector component (epoch-constant; see library doc).
  final ComponentScore trendLeadTime;

  /// Lane-choice agreement with the Laplace best-choice map.
  final ComponentScore laneChoiceRegret;

  /// Connect-budget relative-error score.
  final ComponentScore calibrator;

  /// Network-physics prediction score.
  final ComponentScore atlas;

  /// Mean of the four normalized components; the aliveness number.
  final double score;

  /// Human-readable before->after lines; each cites a journal id.
  final List<String> whatChanged;

  /// Standing honesty notes about what the components do and don't
  /// measure.
  final List<String> notes;

  Map<String, Object?> toJson() => {
    'epoch': epoch,
    'trendLeadTime': trendLeadTime.toJson(),
    'laneChoiceRegret': laneChoiceRegret.toJson(),
    'calibrator': calibrator.toJson(),
    'atlas': atlas.toJson(),
    'score': score,
    'whatChanged': whatChanged,
    'notes': notes,
  };
}

/// A tsv outcome with the derived facts the scoring loop needs.
class _ScoredRow {
  _ScoredRow({
    required this.outcome,
    required this.index,
    required this.cellKey,
    required this.choice,
    required this.hour,
    this.budgetMs,
  });

  final TsvOutcome outcome;

  /// Position in the fixed sorted replay order (cited in whatChanged).
  final int index;

  /// '<lossBand>|<rttBand>' with 'x' for a missing condition — the same
  /// band vocabulary as [LaneChoicePolicy] via [DeliveryContext].
  final String cellKey;

  /// Inferred actual scheme: 'fountain' or 'arq'.
  final String choice;

  /// Hour of day for the atlas (capture hour when a corpus run matches
  /// this row's date, else the row's own timestamp hour).
  final int hour;

  /// Static per-profile budget, when the profile has one.
  final double? budgetMs;
}

/// Success/attempt counter behind the best-choice map.
class _ChoiceTally {
  int successes = 0;
  int attempts = 0;

  /// Laplace (s+1)/(n+2): the [LaneChoicePolicy] estimator convention —
  /// an untried scheme scores 0.5 (see library doc honesty note).
  double get laplace => (successes + 1) / (attempts + 2);
}

/// Replays recorded history through a [BrainSet] and scores each epoch.
///
/// Deterministic: runs and outcomes are replayed in a fixed sorted order
/// (runs by capturedUtc then runDir, outcomes by date then input index),
/// and all time is synthetic.
class ReplayBenchmark {
  ReplayBenchmark({
    required List<ReplayRun> runs,
    required List<TsvOutcome> outcomes,
  }) : _runs = List.of(runs) {
    _runs.sort((a, b) {
      final byCaptured = a.capturedUtc.compareTo(b.capturedUtc);
      return byCaptured != 0 ? byCaptured : a.runDir.compareTo(b.runDir);
    });
    final indexed = List.generate(outcomes.length, (i) => (i, outcomes[i]));
    indexed.sort((a, b) {
      final byDate = a.$2.date.compareTo(b.$2.date);
      return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
    });
    final summariesByDate = <String, String>{
      for (final run in _runs) run.row.date: run.summariesText,
    };
    final hourByDate = <String, int>{
      for (final run in _runs)
        if (run.capturedHour != null) run.row.date: run.capturedHour!,
    };
    final budgets = _medianPassConnectByProfile(indexed);
    for (var i = 0; i < indexed.length; i++) {
      final outcome = indexed[i].$2;
      _rows.add(
        _ScoredRow(
          outcome: outcome,
          index: i,
          cellKey: _cellKey(outcome.lossFraction, outcome.rttMs),
          choice: _inferChoice(outcome, summariesByDate[outcome.date] ?? ''),
          hour: hourByDate[outcome.date] ?? _dateHour(outcome.date),
          budgetMs: budgets[outcome.profile],
        ),
      );
    }
    _bestChoiceByCell.addAll(_buildBestChoiceMap(_rows));
  }

  final List<ReplayRun> _runs;
  final List<_ScoredRow> _rows = [];

  /// cell -> 'arq'|'fountain'. Built once: replaying the same table k
  /// times multiplies every tally by k, which never moves an argmax, so
  /// "all data seen so far across epochs" equals the single-pass map.
  final Map<String, String> _bestChoiceByCell = {};

  /// Epoch-0 raw component values; normalization denominator.
  List<double>? _baselineRaw;

  int _epochsRun = 0;

  /// Synthetic clock for atlas.record: +1 per record. Only relative
  /// order matters (identity eviction), and 8 rig identities never reach
  /// the atlas's 64-identity cap, so restarting at 0 per benchmark
  /// instance cannot change any score.
  int _syntheticMs = 0;

  static String _cellKey(double? lossFraction, double? rttMs) {
    final lossPart = (lossFraction != null && lossFraction.isFinite)
        ? DeliveryContext.lossBand(lossFraction)
        : 'x';
    final rttPart = (rttMs != null && rttMs.isFinite)
        ? DeliveryContext.rttBand(rttMs)
        : 'x';
    return '$lossPart|$rttPart';
  }

  /// The benchmark contract: a row whose note, test name, or matched
  /// summaries mention fountain or datagram carried the fountain scheme;
  /// every other row carried plain arq.
  static String _inferChoice(TsvOutcome outcome, String summaries) {
    final haystack = '${outcome.note} ${outcome.test} $summaries'.toLowerCase();
    return haystack.contains('fountain') || haystack.contains('datagram')
        ? 'fountain'
        : 'arq';
  }

  static int _dateHour(String date) {
    // 11..13: hour digits of ISO-8601; 0 when the field is malformed.
    if (date.length < 13) return 0;
    return int.tryParse(date.substring(11, 13)) ?? 0;
  }

  /// Per-profile static budget: median connect_ms over the profile's
  /// PASS rows, computed once over the whole table — the deterministic
  /// stand-in for the app's budget model.
  static Map<String, double> _medianPassConnectByProfile(
    List<(int, TsvOutcome)> indexed,
  ) {
    final byProfile = <String, List<double>>{};
    for (final (_, outcome) in indexed) {
      final connect = outcome.connectMs;
      if (connect == null || !outcome.success) continue;
      byProfile.putIfAbsent(outcome.profile, () => []).add(connect);
    }
    final budgets = <String, double>{};
    for (final e in byProfile.entries) {
      final sorted = List.of(e.value)..sort();
      final n = sorted.length;
      // Even count: mean of the two middle values (standard median).
      budgets[e.key] = n.isOdd
          ? sorted[n ~/ 2]
          : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
    }
    return budgets;
  }

  static Map<String, String> _buildBestChoiceMap(List<_ScoredRow> rows) {
    final tallies = <String, Map<String, _ChoiceTally>>{};
    for (final row in rows) {
      final cell = tallies.putIfAbsent(
        row.cellKey,
        () => {'arq': _ChoiceTally(), 'fountain': _ChoiceTally()},
      );
      final tally = cell[row.choice]!;
      tally.attempts += 1;
      if (row.outcome.success) tally.successes += 1;
    }
    return {
      for (final e in tallies.entries)
        // Strict > : a tie goes to arq, the policy's own tie rule (the
        // plain scheme costs less, so it needs no edge).
        e.key: e.value['fountain']!.laplace > e.value['arq']!.laplace
            ? 'fountain'
            : 'arq',
    };
  }

  /// Runs one epoch: every component predicts BEFORE it trains, row by
  /// row, so the score measures what the brains knew walking in plus
  /// what they learn mid-pass — and the persistent brains carry that
  /// experience into the next epoch.
  EpochReport runEpoch(BrainSet brains) {
    final whatChanged = <String>[];
    final trendRaw = _scoreTrendLeadTime(brains);
    final laneRaw = _scoreLaneChoice(brains, whatChanged);
    final calibratorRaw = _scoreCalibrator(brains, whatChanged);
    final atlasRaw = _scoreAtlas(brains, whatChanged);

    final raw = [trendRaw, laneRaw, calibratorRaw, atlasRaw];
    final baseline = _baselineRaw ??= List.of(raw);
    final normalized = <double>[
      for (var i = 0; i < raw.length; i++) _normalize(raw[i], baseline[i]),
    ];
    // 4: the number of components in the mean.
    final score = normalized.reduce((a, b) => a + b) / 4;

    final epoch = _epochsRun;
    _epochsRun += 1;
    return EpochReport(
      epoch: epoch,
      trendLeadTime: ComponentScore(raw: trendRaw, normalized: normalized[0]),
      laneChoiceRegret: ComponentScore(raw: laneRaw, normalized: normalized[1]),
      calibrator: ComponentScore(raw: calibratorRaw, normalized: normalized[2]),
      atlas: ComponentScore(raw: atlasRaw, normalized: normalized[3]),
      score: score,
      whatChanged: whatChanged,
      notes: const [
        'trendLeadTime measures the fresh-per-run detector; it has no '
            'persistent brain, so it is epoch-constant by design.',
        'laneChoiceRegret best-choice map uses the package Laplace '
            '(s+1)/(n+2) success estimate; an untried scheme keeps its '
            '0.5 prior (LaneChoicePolicy convention).',
      ],
    );
  }

  /// raw/baseline; a zero baseline maps raw 0 to 1.0 (unchanged) and a
  /// positive raw to 1.0 + raw (any gain over a zero epoch 0 counts as
  /// gain), keeping epoch 0 exactly 1.0 in every case.
  static double _normalize(double raw, double baseline) {
    if (baseline == 0) return raw == 0 ? 1.0 : 1.0 + raw;
    return raw / baseline;
  }

  // ---- component 1: trend lead time (detector, epoch-constant) ----

  /// Replays each disconnecting run's packet series through a fresh
  /// [TrendMonitor]. A hit is a first failingSoon verdict 2..30 s before
  /// the first post-connect disconnect (2 s = enough lead to pre-warm a
  /// lane, 30 s = beyond it the warning is noise); a false alarm is a
  /// first failingSoon with no disconnect in the 30 s after it. Score =
  /// hitRate - 0.25 * falseAlarmRate, floored at 0 (0.25: one false
  /// alarm costs a quarter hit, the benchmark's stated penalty).
  double _scoreTrendLeadTime(BrainSet brains) {
    var eligible = 0;
    var hits = 0;
    var falseAlarms = 0;
    for (final run in _runs) {
      if (run.packetsBySecond.isEmpty) continue;
      double? connectedAt;
      double? failedAt;
      for (final event in run.events) {
        if (event.kind != 'pcStatus') continue;
        if (event.name == 'connected') {
          connectedAt ??= event.tS;
        } else if (event.name == 'disconnected' || event.name == 'failed') {
          if (connectedAt != null) {
            failedAt = event.tS;
            break;
          }
        }
      }
      if (failedAt == null) continue;
      var maxPackets = 0;
      for (final count in run.packetsBySecond.values) {
        if (count > maxPackets) maxPackets = count;
      }
      if (maxPackets == 0) continue;
      eligible += 1;

      final seconds = run.packetsBySecond.keys.toList()..sort();
      final monitor = brains.newTrendMonitor();
      // 'replay' — the single lane id this offline replay feeds.
      const laneId = 'replay';
      double? warnedAt;
      for (var sec = seconds.first; sec <= seconds.last; sec++) {
        // A second missing from the capture saw zero packets.
        final packets = run.packetsBySecond[sec] ?? 0;
        monitor.observe(
          laneId,
          // Delivery proxy: packets normalized by the run's own maximum.
          packets / maxPackets,
          // 1000: seconds to the monitor's millisecond clock.
          nowMs: sec * 1000,
          lossFraction: run.row.lossFraction,
          rttMs: run.row.rttMs,
        );
        if (monitor.verdict(laneId) == TrendVerdict.failingSoon) {
          warnedAt = sec.toDouble();
          break;
        }
      }
      if (warnedAt == null) continue;
      final lead = failedAt - warnedAt;
      // 2..30 s: the pre-warm-to-noise lead window (doc above).
      if (lead >= 2 && lead <= 30) hits += 1;
      final anyDisconnectSoon = run.events.any(
        (e) =>
            e.kind == 'pcStatus' &&
            (e.name == 'disconnected' || e.name == 'failed') &&
            e.tS > warnedAt! &&
            // 30 s: the same noise horizon bounds "soon".
            e.tS <= warnedAt + 30,
      );
      if (!anyDisconnectSoon) falseAlarms += 1;
    }
    if (eligible == 0) return 0;
    final hitRate = hits / eligible;
    final falseAlarmRate = falseAlarms / eligible;
    // 0.25: false-alarm penalty weight (doc above). Floor at 0.
    final score = hitRate - 0.25 * falseAlarmRate;
    return score < 0 ? 0 : score;
  }

  // ---- component 2: lane-choice agreement ----

  double _scoreLaneChoice(BrainSet brains, List<String> whatChanged) {
    if (_rows.isEmpty) return 0;
    var matches = 0;
    for (final row in _rows) {
      final before = brains.laneChoice
          .decide(
            lossFraction: row.outcome.lossFraction,
            rttMs: row.outcome.rttMs,
          )
          .choice;
      if (before == _bestChoiceByCell[row.cellKey]) matches += 1;
      brains.laneChoice.record(
        choice: row.choice,
        lossFraction: row.outcome.lossFraction,
        rttMs: row.outcome.rttMs,
        success: row.outcome.success,
      );
      final after = brains.laneChoice
          .decide(
            lossFraction: row.outcome.lossFraction,
            rttMs: row.outcome.rttMs,
          )
          .choice;
      if (after != before) {
        final ref = brains.journal.add(
          kind: 'lane_choice_flip',
          value: row.index.toDouble(),
          unit: 'row',
          context: 'cell ${row.cellKey} $before->$after',
        );
        whatChanged.add(
          "laneChoice cell '${row.cellKey}' $before->$after "
          'after row ${row.index} [$ref]',
        );
      }
    }
    return matches / _rows.length;
  }

  // ---- component 3: budget calibrator ----

  double _scoreCalibrator(BrainSet brains, List<String> whatChanged) {
    var errorSum = 0.0;
    var count = 0;
    for (final row in _rows) {
      final actual = row.outcome.connectMs;
      final budget = row.budgetMs;
      if (actual == null || actual <= 0 || budget == null) continue;
      final lossFraction = row.outcome.lossFraction;
      final rttMs = row.outcome.rttMs;
      final before = brains.calibrator.correction(
        lossFraction: lossFraction,
        rttMs: rttMs,
      );
      final corrected = budget * before;
      errorSum += (corrected - actual).abs() / actual;
      count += 1;
      brains.calibrator.observe(
        predictedMs: budget,
        actualMs: actual,
        lossFraction: lossFraction,
        rttMs: rttMs,
      );
      final after = brains.calibrator.correction(
        lossFraction: lossFraction,
        rttMs: rttMs,
      );
      // Report a line only when the correction moves at 2-decimal
      // resolution — finer motion is EWMA jitter, not a story.
      if (before.toStringAsFixed(2) != after.toStringAsFixed(2)) {
        final ref = brains.journal.add(
          kind: 'calibrator_correction',
          value: after,
          unit: 'ratio',
          context: 'cell ${row.cellKey}',
        );
        whatChanged.add(
          "calibrator cell '${row.cellKey}' correction "
          '${before.toStringAsFixed(2)}->${after.toStringAsFixed(2)} '
          'after row ${row.index} [$ref]',
        );
      }
    }
    if (count == 0) return 0;
    // 1/(1+meanError): 1.0 at zero error, falling toward 0.
    return 1 / (1 + errorSum / count);
  }

  // ---- component 4: network atlas ----

  double _scoreAtlas(BrainSet brains, List<String> whatChanged) {
    if (_rows.isEmpty) return 0;
    final startForecast = _forecastSnapshot(brains);
    var lossErrorSum = 0.0;
    var lossCount = 0;
    var rttErrorSum = 0.0;
    var rttCount = 0;
    for (final row in _rows) {
      // The rig's shaped profile IS the network identity for this corpus.
      final label = 'rig-${row.outcome.profile}';
      final forecast = brains.atlas.forecast(
        networkLabel: label,
        hourOfDay: row.hour,
      );
      final lossActualPct = row.outcome.lossPct;
      if (lossActualPct != null) {
        // No knowledge = predict a clean link (0 loss); the error then
        // measures exactly what the atlas has not yet learned. 100:
        // fraction to percent.
        final lossPredPct = (forecast?.expectedLossFraction ?? 0.0) * 100;
        lossErrorSum += (lossPredPct - lossActualPct).abs();
        lossCount += 1;
      }
      final rttActual = row.outcome.rttMs;
      if (rttActual != null) {
        final rttPred = forecast?.expectedRttMs ?? 0.0;
        rttErrorSum += (rttPred - rttActual).abs();
        rttCount += 1;
      }
      brains.atlas.record(
        networkLabel: label,
        nowMs: _syntheticMs++,
        hourOfDay: row.hour,
        lossFraction: row.outcome.lossFraction,
        rttMs: row.outcome.rttMs,
      );
    }
    _reportAtlasShifts(brains, startForecast, whatChanged);
    final meanLoss = lossCount == 0 ? 0.0 : lossErrorSum / lossCount;
    final meanRtt = rttCount == 0 ? 0.0 : rttErrorSum / rttCount;
    // 10 pp loss and 500 ms rtt = one error unit each, from the rig's
    // profile spreads (loss profiles are 10s of pp apart; the extreme
    // profile's rtt class is ~500 ms above the clean ones).
    return 1 / (1 + meanLoss / 10 + meanRtt / 500);
  }

  /// (label, hour) -> (lossPct, rttMs) forecast, for shift reporting.
  Map<String, (double, double)> _forecastSnapshot(BrainSet brains) {
    final snapshot = <String, (double, double)>{};
    for (final row in _rows) {
      final label = 'rig-${row.outcome.profile}';
      final key = '$label|h${row.hour}';
      if (snapshot.containsKey(key)) continue;
      final forecast = brains.atlas.forecast(
        networkLabel: label,
        hourOfDay: row.hour,
      );
      snapshot[key] = (
        (forecast?.expectedLossFraction ?? 0.0) * 100,
        forecast?.expectedRttMs ?? 0.0,
      );
    }
    return snapshot;
  }

  void _reportAtlasShifts(
    BrainSet brains,
    Map<String, (double, double)> start,
    List<String> whatChanged,
  ) {
    final end = _forecastSnapshot(brains);
    for (final e in start.entries) {
      final after = end[e.key];
      if (after == null) continue;
      final (lossBefore, rttBefore) = e.value;
      final (lossAfter, rttAfter) = after;
      // 1-decimal resolution: below 0.1 pp / 0.1 ms a shift is noise.
      final moved =
          lossBefore.toStringAsFixed(1) != lossAfter.toStringAsFixed(1) ||
          rttBefore.toStringAsFixed(1) != rttAfter.toStringAsFixed(1);
      if (!moved) continue;
      final ref = brains.journal.add(
        kind: 'atlas_forecast_shift',
        value: lossAfter - lossBefore,
        unit: 'pp',
        context: e.key,
      );
      whatChanged.add(
        "atlas '${e.key}' loss ${lossBefore.toStringAsFixed(1)}->"
        '${lossAfter.toStringAsFixed(1)}pp rtt '
        '${rttBefore.toStringAsFixed(1)}->'
        '${rttAfter.toStringAsFixed(1)}ms over this epoch [$ref]',
      );
    }
  }
}
