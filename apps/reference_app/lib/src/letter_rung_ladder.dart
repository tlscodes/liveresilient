// Remembers, per network, which of the letter's three rungs (wss, https,
// the DNS valve) last actually delivered — so the next Send tries that
// rung alone before racing the other two. One JSON file, the same disk
// primitive and the same storage folder the intelligence hub's own
// brains already use (see device_bindings.dart's buildStorageDirectory),
// so the nightly loop can read this ledger later without a new storage
// seam. That loop is not rewritten here.
library;

import 'dart:io';

import 'package:connection_orchestrator/connection_orchestrator.dart'
    show NetworkAtlas;

import 'intelligence/device_bindings.dart' show buildStorageDirectory;
import 'intelligence/disk_json_storage.dart';

/// Splits a [NetworkNameResolver] label ("cellular:mci", "wifi:home",
/// "ethernet", "offline", "unresolved") into (networkType, operator).
/// Only cellular carries an operator name; every other type's second
/// field is null — a Wi-Fi SSID is not a carrier.
(String networkType, String? operatorName) splitNetworkLabel(String label) {
  final colon = label.indexOf(':');
  if (colon < 0) return (label, null);
  final type = label.substring(0, colon);
  final rest = label.substring(colon + 1);
  return (type, type == 'cellular' ? rest : null);
}

/// Where one attempt ended up.
enum LetterRungOutcome { delivered, queued }

/// One row: what rung carried — or failed to carry — a letter on a
/// network, and how long it took to find out.
class LetterRungAttempt {
  const LetterRungAttempt({
    required this.rung,
    required this.outcome,
    this.resolver,
    this.latencyMs,
  });

  /// A [ResilientLaneIds] value: wss, https or the DNS valve.
  final String rung;

  /// The DNS valve's winning transport label (`TxtProbeAnswer.label`), or
  /// null for wss/https and for a queued attempt with no winner.
  final String? resolver;

  /// Wall-clock time from picking [rung] to the verdict.
  final int? latencyMs;
  final LetterRungOutcome outcome;

  Map<String, Object?> toJson() => {
    'rung': rung,
    'resolver': resolver,
    'latencyMs': latencyMs,
    'outcome': outcome.name,
  };
}

/// Per-network memory of the letter's rung race: the last confirmed
/// winner (tried alone, first, next time) and a short history of every
/// attempt.
class LetterRungLadder {
  LetterRungLadder(this._storage, {this.maxHistoryPerNetwork = 20});

  /// Stores beside the intelligence hub's own files, so a build with no
  /// platform storage plugin still gets the SAME fallback folder
  /// `bootIntelligence` resolves to (see `letterQueueDirectory`, which
  /// mirrors the identical fallback for the same reason).
  factory LetterRungLadder.disk() {
    final factory =
        buildStorageDirectory() ??
        (() => Directory(
          '${Directory.systemTemp.path}/voice_call_kit_intelligence',
        ));
    return LetterRungLadder(
      DiskJsonStorage(
        directoryFactory: factory,
        fileName: 'letter_rung_ladder.json',
      ),
    );
  }

  final PersistentStorage _storage;
  final int maxHistoryPerNetwork;

  /// The rung that last DELIVERED a letter on [networkLabel], or null —
  /// a fresh network, or one where every past attempt queued.
  Future<String?> previousWinner(String networkLabel) async {
    final data = await _storage.load();
    final entry = data[networkLabel];
    return entry is Map ? entry['lastWinner'] as String? : null;
  }

  /// Appends [attempt] to [networkLabel]'s history and, only when it
  /// delivered, updates the stored winner. A queued attempt is recorded
  /// but never becomes the next Send's previous winner.
  Future<void> record(String networkLabel, LetterRungAttempt attempt) async {
    final data = await _storage.load();
    final raw = data[networkLabel];
    final entry = raw is Map
        ? Map<String, Object?>.from(raw)
        : <String, Object?>{};
    final history = entry['history'] is List
        ? List<Object?>.from(entry['history'] as List)
        : <Object?>[];
    history.add(attempt.toJson());
    if (history.length > maxHistoryPerNetwork) {
      history.removeRange(0, history.length - maxHistoryPerNetwork);
    }
    entry['history'] = history;
    if (attempt.outcome == LetterRungOutcome.delivered) {
      entry['lastWinner'] = attempt.rung;
    }
    data[networkLabel] = entry;
    await _storage.save(data);
  }
}

/// One level under [LetterRungLadder]: per-network memory of which of the
/// DNS valve's OWN resolvers actually wins, so a history-bearing network
/// races the previous winner and its strongest remaining competitor only
/// — "the rest, no" — instead of every candidate every time.
class DoorResolverLadder {
  DoorResolverLadder(this._storage);

  /// Same storage folder as [LetterRungLadder.disk], a sibling file.
  factory DoorResolverLadder.disk() {
    final factory =
        buildStorageDirectory() ??
        (() => Directory(
          '${Directory.systemTemp.path}/voice_call_kit_intelligence',
        ));
    return DoorResolverLadder(
      DiskJsonStorage(
        directoryFactory: factory,
        fileName: 'letter_door_resolvers.json',
      ),
    );
  }

  final PersistentStorage _storage;

  /// Chooses at most 2 of [all] to race when history exists: the
  /// previous winner (by [previousWinner]) and its strongest remaining
  /// competitor by wins/attempts — "the rest, no". Returns [all]
  /// unchanged when [previousWinner] is absent from today's candidates
  /// (the resolver set changed since); the caller checks separately
  /// whether [history] is empty at all (the empty-history case still
  /// races everything, unchanged).
  ///
  /// Generic and label-keyed only, so it needs no transport type here:
  /// [labelOf] is the one seam between this pure choice and whatever
  /// object the caller races.
  static List<T> narrow<T>(
    List<T> all,
    String Function(T) labelOf,
    Map<String, ({int wins, int attempts})> history,
    String? previousWinner,
  ) {
    final prevIndex = previousWinner == null
        ? -1
        : all.indexWhere((t) => labelOf(t) == previousWinner);
    if (prevIndex < 0) return all;
    double weight(int i) {
      final h = history[labelOf(all[i])];
      return (h == null || h.attempts == 0) ? -1 : h.wins / h.attempts;
    }

    var bestRival = -1;
    for (var i = 0; i < all.length; i++) {
      if (i == prevIndex) continue;
      if (bestRival == -1 || weight(i) > weight(bestRival)) bestRival = i;
    }
    return [all[prevIndex], if (bestRival >= 0) all[bestRival]];
  }

  /// wins/attempts per resolver label attempted so far on [networkLabel].
  /// Empty when nothing has been attempted — the caller's cue to race
  /// every candidate, same as today.
  Future<Map<String, ({int wins, int attempts})>> history(
    String networkLabel,
  ) async {
    final data = await _storage.load();
    final entry = data[networkLabel];
    if (entry is! Map) return const {};
    final resolvers = entry['resolvers'];
    if (resolvers is! Map) return const {};
    final result = <String, ({int wins, int attempts})>{};
    for (final key in resolvers.keys) {
      final counts = resolvers[key];
      if (counts is Map) {
        result[key as String] = (
          wins: counts['wins'] as int? ?? 0,
          attempts: counts['attempts'] as int? ?? 0,
        );
      }
    }
    return result;
  }

  /// The resolver that most recently won on [networkLabel], or null.
  Future<String?> previousWinner(String networkLabel) async {
    final data = await _storage.load();
    final entry = data[networkLabel];
    return entry is Map ? entry['lastWinner'] as String? : null;
  }

  /// One probe round: [asked] is every resolver label actually raced;
  /// [winner] is the one the server logged first, or null when none
  /// reached it. A miss leaves the last recorded winner untouched — one
  /// bad round does not erase a resolver's whole track record.
  Future<void> record(
    String networkLabel, {
    required List<String> asked,
    String? winner,
  }) async {
    final data = await _storage.load();
    final raw = data[networkLabel];
    final entry = raw is Map
        ? Map<String, Object?>.from(raw)
        : <String, Object?>{};
    final rawResolvers = entry['resolvers'];
    final resolvers = rawResolvers is Map
        ? Map<String, Object?>.from(rawResolvers)
        : <String, Object?>{};
    for (final label in asked) {
      final rawCounts = resolvers[label];
      final counts = rawCounts is Map
          ? Map<String, Object?>.from(rawCounts)
          : <String, Object?>{'wins': 0, 'attempts': 0};
      counts['attempts'] = (counts['attempts'] as int? ?? 0) + 1;
      if (label == winner) {
        counts['wins'] = (counts['wins'] as int? ?? 0) + 1;
      }
      resolvers[label] = counts;
    }
    entry['resolvers'] = resolvers;
    if (winner != null) entry['lastWinner'] = winner;
    data[networkLabel] = entry;
    await _storage.save(data);
  }
}

/// Gates the once-per-install measurement below — separate from
/// [DeviceLinkConsent] (device_link package), which gates the mesh lane.
/// This is its own opt-in: a person may allow the one-time measurement
/// without ever granting nearby-connectivity access, and the reverse.
abstract interface class LetterMeasurementConsent {
  bool get granted;
}

/// One anonymous row, written at most once in the life of an install:
/// which rung (and, under the door, which resolver) carried the very
/// first letter, on which kind of network, how fast, and on which build.
/// No letter text, no person id — see the field list below.
class InstallLetterMeasurement {
  InstallLetterMeasurement(this._storage);

  /// Same storage folder as [LetterRungLadder.disk] and
  /// [DoorResolverLadder.disk], a sibling file.
  factory InstallLetterMeasurement.disk() {
    final factory =
        buildStorageDirectory() ??
        (() => Directory(
          '${Directory.systemTemp.path}/voice_call_kit_intelligence',
        ));
    return InstallLetterMeasurement(
      DiskJsonStorage(
        directoryFactory: factory,
        fileName: 'letter_install_measurement.json',
      ),
    );
  }

  final PersistentStorage _storage;

  Future<bool> alreadyRecorded() async {
    final data = await _storage.load();
    return data['recordedOnce'] == true;
  }

  /// Records the seven fields once, keyed by [NetworkAtlas.identityHash]
  /// of [networkLabel] — the same hash the call side already uses for
  /// [CallHistoryRecord.networkIdentityHash], so the two can be
  /// correlated without ever storing the raw label. A no-op when
  /// [consent] withholds it or a row is already on disk; a second
  /// install-lifetime Send never overwrites the first row.
  Future<void> recordOnce({
    required LetterMeasurementConsent? consent,
    required String networkLabel,
    required String operatorName,
    required String networkType,
    required String rung,
    String? resolver,
    int? rttMs,
    required bool delivered,
    String appVersion = 'reference v3',
  }) async {
    if (consent == null || !consent.granted) return;
    if (await alreadyRecorded()) return;
    final data = await _storage.load();
    final identityHash = NetworkAtlas.identityHash(networkLabel);
    data['recordedOnce'] = true;
    data[identityHash] = {
      'operator': operatorName,
      'networkType': networkType,
      'rung': rung,
      'resolver': resolver,
      'rttMs': rttMs,
      'outcome': delivered ? 'delivered' : 'queued',
      'appVersion': appVersion,
    };
    await _storage.save(data);
  }
}

/// Persisted, on-device opt-in for [InstallLetterMeasurement] — separate
/// from the mesh's `DeviceLinkConsent` (device_link package). Defaults
/// to false; [disk]/[load] read the saved value once, at boot, because
/// [granted] itself stays a plain synchronous getter, the interface's
/// own contract.
class PersistedMeasurementConsent implements LetterMeasurementConsent {
  PersistedMeasurementConsent(this._storage, {this._granted = false});

  final PersistentStorage _storage;
  bool _granted;

  @override
  bool get granted => _granted;

  /// Reads the persisted value (false when nothing was ever saved).
  static Future<PersistedMeasurementConsent> load(
    PersistentStorage storage,
  ) async {
    final data = await storage.load();
    return PersistedMeasurementConsent(
      storage,
      granted: data['granted'] == true,
    );
  }

  /// Same storage folder as [InstallLetterMeasurement.disk], a sibling
  /// file.
  static Future<PersistedMeasurementConsent> disk() {
    final factory =
        buildStorageDirectory() ??
        (() => Directory(
          '${Directory.systemTemp.path}/voice_call_kit_intelligence',
        ));
    return load(
      DiskJsonStorage(
        directoryFactory: factory,
        fileName: 'letter_measurement_consent.json',
      ),
    );
  }

  /// Updates the in-memory flag immediately; the disk write follows in
  /// the background, so the very next Send already sees the new value.
  Future<void> setGranted(bool value) async {
    _granted = value;
    await _storage.save({'granted': value});
  }
}
