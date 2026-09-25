// Remembers, per network, which of the letter's three rungs (wss, https,
// the DNS valve) last actually delivered — so the next Send tries that
// rung alone before racing the other two. One JSON file, the same disk
// primitive and the same storage folder the intelligence hub's own
// brains already use (see device_bindings.dart's buildStorageDirectory),
// so the nightly loop can read this ledger later without a new storage
// seam. That loop is not rewritten here.
library;

import 'dart:io';

import 'intelligence/device_bindings.dart' show buildStorageDirectory;
import 'intelligence/disk_json_storage.dart';

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
