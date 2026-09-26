// One measurement card per letter: a single JSONL line written when the
// letter's outcome is known (sentLive, queued, notDelivered). Counts and
// ids only — never letter text, payload bytes or wire bytes. Every card
// carries `lab: true`: this is lab telemetry, not a real-network claim.
//
// The app's courier (source "phone") and the rig peer (source "mac" or
// "phone") both build the card here, so the field order is one list and
// both writers produce byte-identical key order.
import 'dart:convert';
import 'dart:io';

import 'intelligence/device_bindings.dart' show buildStorageDirectory;

/// The three outcome words a card may carry. The fabric's
/// `queuedForLater` and the app's `queued` read "queued"; `sentLive` and
/// the app's `arrived` read "sentLive"; anything else is "notDelivered".
String normalizeLetterOutcome(String name) => switch (name) {
  'sentLive' || 'arrived' => 'sentLive',
  'queuedForLater' || 'queued' => 'queued',
  _ => 'notDelivered',
};

class LetterCard {
  const LetterCard({
    required this.at,
    required this.source,
    required this.bytes,
    required this.outcome,
    this.session,
    this.bestLane,
    this.resolvers = const <String>[],
    this.winner,
    this.rung,
  });

  static const String event = 'letter_card';
  static const int version = 1;

  final DateTime at;

  /// "mac" or "phone".
  final String source;
  final String? session;
  final int bytes;

  /// Already normalized: see [normalizeLetterOutcome].
  final String outcome;
  final String? bestLane;

  /// The resolver labels actually raced for this letter, [] when none.
  final List<String> resolvers;
  final String? winner;
  final String? rung;

  /// Key order is part of the schema — both writers depend on it.
  Map<String, Object?> toJson() => <String, Object?>{
    'event': event,
    'v': version,
    'at': at.toUtc().toIso8601String(),
    'source': source,
    'session': session,
    'bytes': bytes,
    'outcome': outcome,
    'best_lane': bestLane,
    'resolvers': List<String>.of(resolvers),
    'winner': winner,
    'rung': rung,
    'lab': true,
  };
}

/// Where a card goes. The app wires [LetterCardLog]; tests record.
abstract interface class LetterCardSink {
  Future<void> append(LetterCard card);
}

/// Best-effort on-device appender: one `jsonEncode(card)` line per card
/// in `letter_cards.jsonl`, beside the brains' files. Never throws — disk
/// trouble must never break a Send.
class LetterCardLog implements LetterCardSink {
  LetterCardLog(this._directoryFactory, {this.fileName = 'letter_cards.jsonl'});

  /// The brains' Documents home on a phone ([buildStorageDirectory]), and
  /// the same system-temp folder they fall back to elsewhere — the
  /// convention letterQueueDirectory() already follows.
  factory LetterCardLog.disk() => LetterCardLog(
    () =>
        buildStorageDirectory()?.call() ??
        Directory('${Directory.systemTemp.path}/voice_call_kit_intelligence'),
  );

  final Directory Function() _directoryFactory;
  final String fileName;

  @override
  Future<void> append(LetterCard card) async {
    try {
      final dir = _directoryFactory();
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await File('${dir.path}/$fileName').writeAsString(
        '${jsonEncode(card.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Telemetry is best effort: a failed append is dropped silently.
    }
  }
}
