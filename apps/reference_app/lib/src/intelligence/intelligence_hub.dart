/// The wiring loom: composes the learning models, their persistence, the
/// place resolver, and the assistant into one app-level unit with a
/// single lifecycle.
///
/// Restores all persisted brains from disk on start, autosaves them
/// debounced as they learn, feeds the fabric's place() from the cached
/// network label, and hands the UI the deterministic rule-based narrator
/// (the only assistant tier — user ruling 2026-08-10 retired the model
/// seam). Persisted brains («هوشمندی v3» wiring matrix):
/// [experience], [learner], [atlas], [laneChoice], [calibrator], plus the
/// [journal] evidence ring and the [history] of finished calls.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:on_device_assistant/on_device_assistant.dart';

import 'disk_json_storage.dart';
import 'network_name_resolver.dart';

/// One composed intelligence stack.
class IntelligenceHub {
  IntelligenceHub._({
    required this.experience,
    required this.learner,
    required this.atlas,
    required this.laneChoice,
    required this.calibrator,
    required this.journal,
    required this.history,
    required this.assistant,
    required this.resolver,
    required this._nowMs,
    required this._savers,
  });

  /// Restores persisted state and initializes the assistant tier.
  ///
  /// Every brain restores corrupt-safe: a damaged or missing file loads as
  /// `{}` ([PersistentStorage.load]'s contract) and each `fromJson`
  /// degrades that to a fresh brain, never a crash.
  static Future<IntelligenceHub> start({
    required PersistentStorage experienceStorage,
    required PersistentStorage learnerStorage,
    required PersistentStorage atlasStorage,
    required PersistentStorage laneChoiceStorage,
    required PersistentStorage calibratorStorage,
    required PersistentStorage journalStorage,
    required PersistentStorage historyStorage,
    required CachingNetworkResolver resolver,
    int Function()? nowMs,
  }) async {
    final clock = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
    final experience = LaneExperience.fromJson(await experienceStorage.load());
    final learner = MicroLearner.fromJson(await learnerStorage.load());
    final atlas = NetworkAtlas.fromJson(await atlasStorage.load());
    final laneChoice = LaneChoicePolicy.fromJson(
      await laneChoiceStorage.load(),
    );
    final calibrator = BudgetCalibrator.fromJson(
      await calibratorStorage.load(),
    );
    // 500 = MeasurementJournal's own default ring capacity (bounded memory,
    // far more than one call's narration cites) — stated here because the
    // wiring matrix pins it as the app-level contract.
    final journal = MeasurementJournal.fromJson(
      await journalStorage.load(),
      capacity: 500,
      nowMs: clock,
    );
    // CallHistoryStore serializes to a LIST; PersistentStorage stores maps,
    // so the list rides under one 'records' key both ways.
    final history = CallHistoryStore.fromJson(
      (await historyStorage.load())['records'],
    );
    final assistant = RuleBasedAssistant();
    await assistant.initialize();
    return IntelligenceHub._(
      experience: experience,
      learner: learner,
      atlas: atlas,
      laneChoice: laneChoice,
      calibrator: calibrator,
      journal: journal,
      history: history,
      assistant: assistant,
      resolver: resolver,
      nowMs: clock,
      // Order is the flush/dispose order; index 0/1 are the two savers
      // recordObservation/markExperienceDirty address by name below.
      savers: [
        DebouncedSaver(storage: experienceStorage, snapshot: experience.toJson),
        DebouncedSaver(storage: learnerStorage, snapshot: learner.toJson),
        DebouncedSaver(storage: atlasStorage, snapshot: atlas.toJson),
        DebouncedSaver(storage: laneChoiceStorage, snapshot: laneChoice.toJson),
        DebouncedSaver(storage: calibratorStorage, snapshot: calibrator.toJson),
        DebouncedSaver(storage: journalStorage, snapshot: journal.toJson),
        DebouncedSaver(
          storage: historyStorage,
          snapshot: () => {'records': history.toJson()},
        ),
      ],
    );
  }

  /// Persistent contextual delivery memory — pass to [ConnectionFabric].
  final LaneExperience experience;

  /// Persistent place-network map.
  final MicroLearner learner;

  /// Persistent per-network physics memory (hour-of-day bucketed,
  /// identity-hashed — raw labels never reach disk).
  final NetworkAtlas atlas;

  /// Persistent arq-vs-fountain preference, learned per condition cell.
  final LaneChoicePolicy laneChoice;

  /// Persistent personal correction on the deterministic connect budget.
  final BudgetCalibrator calibrator;

  /// Persistent evidence ring behind every narrated citation id.
  final MeasurementJournal journal;

  /// Persistent summaries of finished calls.
  final CallHistoryStore history;

  /// User-facing Persian narrator. Concretely typed so the director can
  /// wire [RuleBasedAssistant.setEvidenceSource] without a cast.
  final RuleBasedAssistant assistant;

  /// Feeds `ConnectionFabric(place: hub.placeResolver)`.
  final CachingNetworkResolver resolver;

  final int Function() _nowMs;
  final List<DebouncedSaver> _savers;

  DebouncedSaver get _experienceSaver => _savers[0];
  DebouncedSaver get _learnerSaver => _savers[1];
  DebouncedSaver get _atlasSaver => _savers[2];
  DebouncedSaver get _laneChoiceSaver => _savers[3];
  DebouncedSaver get _calibratorSaver => _savers[4];
  DebouncedSaver get _journalSaver => _savers[5];
  DebouncedSaver get _historySaver => _savers[6];

  /// Synchronous place label for the fabric's hot path.
  String placeResolver() => resolver.lastKnownLabel;

  /// Feed one observed sample into the long-term map (called from the
  /// path monitor's evaluation loop) and schedule persistence.
  void recordObservation({
    required double quality,
    required double slope,
    required int nowMs,
  }) {
    learner.observe(
      ConnectivityExperience(
        placeTag: resolver.lastKnownLabel,
        networkName: resolver.lastKnownLabel,
        quality: quality,
        slope: slope,
        atMs: nowMs,
      ),
    );
    _learnerSaver.markDirty();
  }

  /// Feed one delivery outcome into the carriage-scheme brain and log it
  /// as journal evidence. [choice] is 'arq' or 'fountain' — the scheme the
  /// send actually rode ([LaneChoicePolicy.record]'s vocabulary).
  void recordDelivery({
    required bool success,
    required String choice,
    double? lossFraction,
    double? rttMs,
  }) {
    laneChoice.record(
      choice: choice,
      lossFraction: lossFraction,
      rttMs: rttMs,
      success: success,
    );
    journal.add(
      kind: 'delivery.outcome',
      value: success ? 1.0 : 0.0,
      unit: 'bool',
      context: choice,
    );
    _laneChoiceSaver.markDirty();
    _journalSaver.markDirty();
  }

  /// Feed one finished call into the history, the budget calibrator, and
  /// the network atlas, and log the connect evidence to the journal.
  ///
  /// [predictedConnectMs] is what the session's budget model expected the
  /// connect to cost; [CallHistoryRecord.connectMs] is what it measured.
  void recordCallEnd(
    CallHistoryRecord record, {
    required double predictedConnectMs,
  }) {
    history.add(record);
    calibrator.observe(
      predictedMs: predictedConnectMs,
      actualMs: record.connectMs.toDouble(),
    );
    final now = _nowMs();
    final at = DateTime.fromMillisecondsSinceEpoch(now);
    atlas.record(
      networkLabel: resolver.lastKnownLabel,
      nowMs: now,
      hourOfDay: at.hour,
      // Monday 00 = 0 .. Sunday 23 = 167 (weekday is 1-based Monday).
      hourOfWeek: (at.weekday - 1) * 24 + at.hour,
    );
    journal.add(
      kind: 'call.connect_ms',
      value: record.connectMs.toDouble(),
      unit: 'ms',
      context: record.endReason,
    );
    journal.add(
      kind: 'call.recoveries',
      value: record.recoveries.toDouble(),
      unit: 'count',
      context: record.networkIdentityHash,
    );
    _historySaver.markDirty();
    _calibratorSaver.markDirty();
    _atlasSaver.markDirty();
    _journalSaver.markDirty();
  }

  /// Feed one observed network hop into the atlas's transition model
  /// («هوشمندی v4» pillar 4). Wired by boot to the resolver's
  /// onLabelChange, so every "left wifi:X, landed on cellular:Y" becomes
  /// pre-warm knowledge. Journal evidence carries only identity hashes.
  void noteNetworkChange({required String fromLabel, required String toLabel}) {
    atlas.recordTransition(fromLabel: fromLabel, toLabel: toLabel);
    journal.add(
      kind: 'network.transition',
      value: 1.0,
      unit: 'hop',
      context:
          '${NetworkAtlas.identityHash(fromLabel)}->'
          '${NetworkAtlas.identityHash(toLabel)}',
    );
    _atlasSaver.markDirty();
    _journalSaver.markDirty();
  }

  /// Call after deliveries so the contextual memory reaches disk too.
  void markExperienceDirty() => _experienceSaver.markDirty();

  /// Call after adding journal evidence outside the hub (the director's
  /// per-snapshot measurements) so the ring reaches disk too.
  void markJournalDirty() => _journalSaver.markDirty();

  /// Flush every brain (app pause) without tearing down.
  Future<void> flush() async {
    for (final saver in _savers) {
      await saver.flush();
    }
  }

  Future<void> dispose() async {
    for (final saver in _savers) {
      await saver.dispose();
    }
    await assistant.dispose();
  }
}
