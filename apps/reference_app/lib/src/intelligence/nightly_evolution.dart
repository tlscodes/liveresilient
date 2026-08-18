/// The app-side champion/challenger loop («هوشمندی v4» pillar 3): the
/// replay benchmark as a permanent, self-run habit instead of a dev tool.
///
/// [runNightlyEvolution] trains a CLONE of the live brains on the
/// device's own call history and, ONLY on a measured score rise,
/// stages the trained clone as `generations/candidate.json`; the
/// champion generation on disk is never mutated. [applyStagedGeneration]
/// runs at boot BEFORE the hub loads: it moves the previous brains to
/// `generations/prev.json` (rollback stays one file-copy away) and
/// installs the candidate into the live brain files. Every round —
/// promoted or not — appends its [GenerationDecision] to
/// `generations/promotion_log.json`, capped, so "what changed and why"
/// is inspectable forever.
///
/// Power discipline: the loop runs only when the injected [powerGate]
/// says the device is charging / battery-rich. A null gate means the
/// platform probe is not bound (demo/test build): the loop then runs
/// only when invoked explicitly with `force: true` — silence, not a
/// guess. On a real device bind battery_plus here, one closure:
///
///   powerGate: () async {
///     final s = await battery.batteryState;
///     return s == BatteryState.charging || s == BatteryState.full ||
///         (await battery.batteryLevel) >= 80;
///   }
library;

import 'dart:convert';
import 'dart:io';

import 'package:connection_orchestrator/connection_orchestrator.dart';

import 'intelligence_hub.dart';

/// 50: promotion-log entries kept — one nightly round per day is ~7
/// weeks of history, journal-ring sized, never unbounded.
const int _logCap = 50;

/// 3: default training epochs per round — enough for the rise to show
/// (the corpus benchmark plateaus by epoch 3-4), cheap enough for a
/// nightly charge window.
const int _defaultEpochs = 3;

File _candidateFile(Directory dir) =>
    File('${dir.path}/generations/candidate.json');
File _prevFile(Directory dir) => File('${dir.path}/generations/prev.json');
File _logFile(Directory dir) =>
    File('${dir.path}/generations/promotion_log.json');

Map<String, Object?> _brainSnapshot(IntelligenceHub hub) => {
  'atlas': hub.atlas.toJson(),
  'laneChoice': hub.laneChoice.toJson(),
  'calibrator': hub.calibrator.toJson(),
};

void _appendLog(Directory dir, GenerationDecision decision) {
  final file = _logFile(dir);
  file.parent.createSync(recursive: true);
  List<Object?> entries = [];
  try {
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) entries = List.of(decoded);
    }
  } catch (_) {
    entries = []; // Corrupt log restarts; decisions are advisory history.
  }
  entries.add(decision.toJson());
  if (entries.length > _logCap) {
    entries = entries.sublist(entries.length - _logCap);
  }
  // Atomic like DiskJsonStorage: tmp beside the target, then rename.
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync(jsonEncode(entries), flush: true);
  tmp.renameSync(file.path);
}

/// The staged-candidate + log view, for the narrator and tests.
List<GenerationDecision> readPromotionLog(Directory intelligenceDir) {
  final file = _logFile(intelligenceDir);
  try {
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) return const [];
    return [
      for (final raw in decoded)
        if (GenerationDecision.fromJson(raw) != null)
          GenerationDecision.fromJson(raw)!,
    ];
  } catch (_) {
    return const [];
  }
}

/// One champion/challenger round over the device's own history.
///
/// Returns the decision, or null when the power gate held it back.
/// The live hub brains are never mutated — the challenger is a JSON
/// clone, and promotion only stages files for the next boot.
Future<GenerationDecision?> runNightlyEvolution({
  required IntelligenceHub hub,
  required Directory intelligenceDir,
  Future<bool> Function()? powerGate,
  bool force = false,
  int epochs = _defaultEpochs,
  int Function()? nowMs,
}) async {
  final now = nowMs ?? () => DateTime.now().millisecondsSinceEpoch;
  if (!force) {
    // Null gate = no platform probe bound: never run implicitly.
    if (powerGate == null || !await powerGate()) return null;
  }

  final championJson = _brainSnapshot(hub);
  var syntheticMs = 0;
  final challenger = BrainSet.fromJson(
    championJson,
    journal: MeasurementJournal(nowMs: () => syntheticMs++),
  );
  final replay = CallHistoryReplay(records: hub.history.records);
  // Epoch 0 measures the champion's knowledge walking in (and is the
  // clone's first training pass); the last epoch measures the trained
  // challenger. Strict rise promotes, anything else rolls back.
  var championScore = 0.0;
  var challengerScore = 0.0;
  for (var epoch = 0; epoch < (epochs < 1 ? 1 : epochs); epoch++) {
    final score = replay.scoreEpoch(challenger);
    if (epoch == 0) championScore = score;
    challengerScore = score;
  }
  final decision = decideGeneration(
    championScore: championScore,
    challengerScore: challengerScore,
    scoredCount: replay.lastScoredCount,
    nowMs: now(),
  );
  if (decision.promoted) {
    final candidate = _candidateFile(intelligenceDir);
    candidate.parent.createSync(recursive: true);
    final tmp = File('${candidate.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({
        'atlas': challenger.atlas.toJson(),
        'laneChoice': challenger.laneChoice.toJson(),
        'calibrator': challenger.calibrator.toJson(),
        'decision': decision.toJson(),
      }),
      flush: true,
    );
    tmp.renameSync(candidate.path);
  }
  _appendLog(intelligenceDir, decision);
  return decision;
}

/// Installs a staged candidate generation, if one exists — called at
/// boot BEFORE the hub loads its brain files. The outgoing champion is
/// archived whole to `generations/prev.json` first, so rollback is one
/// file-copy, and the candidate file is consumed (deleted) so a crashy
/// generation cannot install itself twice.
///
/// Returns true when a candidate was installed.
Future<bool> applyStagedGeneration(Directory intelligenceDir) async {
  final candidate = _candidateFile(intelligenceDir);
  try {
    if (!candidate.existsSync()) return false;
    final decoded = jsonDecode(candidate.readAsStringSync());
    if (decoded is! Map) {
      candidate.deleteSync();
      return false;
    }
    // Brain-section -> live file name, matching bootIntelligence's
    // DiskJsonStorage wiring exactly.
    const fileBySection = {
      'atlas': 'network_atlas.json',
      'laneChoice': 'lane_choice.json',
      'calibrator': 'budget_calibrator.json',
    };
    // Archive the outgoing champion whole (missing live files archive
    // as empty sections — a fresh install has nothing to keep).
    final prev = <String, Object?>{};
    for (final entry in fileBySection.entries) {
      final live = File('${intelligenceDir.path}/${entry.value}');
      if (live.existsSync()) {
        try {
          prev[entry.key] = jsonDecode(live.readAsStringSync());
        } catch (_) {
          // A corrupt live file archives as absent.
        }
      }
    }
    final prevFile = _prevFile(intelligenceDir)
      ..parent.createSync(recursive: true);
    final prevTmp = File('${prevFile.path}.tmp');
    prevTmp.writeAsStringSync(jsonEncode(prev), flush: true);
    prevTmp.renameSync(prevFile.path);
    // Install the candidate's sections into the live files.
    for (final entry in fileBySection.entries) {
      final section = decoded[entry.key];
      if (section is! Map) continue;
      final live = File('${intelligenceDir.path}/${entry.value}');
      final tmp = File('${live.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(section), flush: true);
      tmp.renameSync(live.path);
    }
    candidate.deleteSync();
    return true;
  } catch (_) {
    // A malformed candidate must never block boot; consume it so it
    // cannot wedge every later launch either.
    try {
      if (candidate.existsSync()) candidate.deleteSync();
    } catch (_) {}
    return false;
  }
}
