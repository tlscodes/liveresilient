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

import 'intelligence/device_bindings.dart' show intelligenceStorageDirectory;

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
    this.reason,
    this.action,
  });

  static const String event = 'letter_card';
  static const int version = 3;

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

  /// One word for WHY this run's [rung] was what it was, from the ladder's
  /// own fabric predicate (letter_status_ladder.dart). Null on a writer
  /// with no ladder (the rig peer), exactly like [rung].
  final String? reason;

  /// One word for what the send DID: "send" (delivered live on the chosen
  /// lane), "queue" (parked in the queue), "hold" (neither — gave up or
  /// not delivered without a park). Null on a writer with no delivery
  /// state (the rig peer), exactly like [rung].
  final String? action;

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
    'reason': reason,
    'action': action,
    'lab': true,
  };
}

/// Where a card goes. The app wires [LetterCardLog]; tests record.
abstract interface class LetterCardSink {
  Future<void> append(LetterCard card);
}

/// Best-effort on-device appender: one `jsonEncode(card)` line per card
/// in `letter_cards.jsonl`, in the one folder every intelligence file
/// shares (see `intelligenceStorageDirectory`) — on iOS the OS-backed
/// Documents home, system temp elsewhere. Never throws — disk trouble must
/// never break a Send.
class LetterCardLog implements LetterCardSink {
  LetterCardLog(this._directoryFactory, {this.fileName = 'letter_cards.jsonl'});

  factory LetterCardLog.disk() => LetterCardLog(intelligenceStorageDirectory);

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
