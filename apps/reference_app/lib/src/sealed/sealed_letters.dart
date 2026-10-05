// Sealed letters between installs that have pinned each other.
//
// Each install has one mailbox, named by its install id. To write, the
// sender seals the letter to the recipient's PINNED key and puts the box in
// the recipient's mailbox. The recipient reads its own mailbox, opens the
// box, checks that the key inside is the one it pinned for that install,
// and puts a short receipt — itself a sealed box — in the sender's mailbox.
//
// The sender keeps every letter until its receipt comes back and puts the
// box in again, with a growing pause, until it does. That one rule covers
// a door that is down, a relay that dropped the box, and a recipient who
// was away: the letter waits in the sender's queue until the path is up.
// The recipient may therefore see a letter twice; it shows it once and
// answers every copy with a receipt, because a second copy means the first
// receipt was lost.
//
// At rest nothing is in the clear: the queue holds the sealed box plus a
// copy sealed to this install's own key (so the sender can still read what
// it sent), and the inbox holds the boxes as they arrived.
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';

import '../intelligence/device_bindings.dart' show intelligenceStorageDirectory;
import '../intelligence/disk_json_storage.dart';
import '../peer_identity.dart';
import 'mailbox_door.dart';
import 'sealed_box.dart';

/// A letter this install wrote.
@immutable
class SealedSent {
  const SealedSent({
    required this.id,
    required this.to,
    required this.body,
    required this.at,
    required this.attempts,
    required this.deliveredAt,
  });

  final String id;
  final String to;
  final Uint8List body;
  final DateTime at;

  /// How many times the box was put in the recipient's mailbox.
  final int attempts;

  /// When the recipient's receipt arrived; null while the letter waits.
  final DateTime? deliveredAt;

  bool get delivered => deliveredAt != null;
  String get text => utf8.decode(body, allowMalformed: true);
}

/// A letter that opened on this install, from a pinned sender.
@immutable
class SealedReceived {
  const SealedReceived({
    required this.id,
    required this.from,
    required this.body,
    required this.sentAt,
    required this.receivedAt,
    required this.verified,
  });

  final String id;
  final String from;
  final Uint8List body;
  final DateTime sentAt;
  final DateTime receivedAt;

  /// Whether the sender's key was confirmed by comparing safety numbers.
  /// False is the ordinary "encrypted, not yet verified".
  final bool verified;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// Thrown by [SealedLetterService.send] for an install nobody pinned: there
/// is no key to lock the letter to.
class NotPinnedError extends StateError {
  NotPinnedError(String install) : super('no pinned key for $install');
}

class SealedLetterService {
  SealedLetterService({
    required AppIdentity identity,
    required this.door,
    required this.storage,
    DateTime Function()? clock,
    this.onEvent,
    this.pollWait = const Duration(seconds: 20),
    this.retryBase = const Duration(seconds: 5),
    this.retryCap = const Duration(minutes: 5),
  }) : _identity = identity,
       _clock = clock ?? DateTime.now,
       _codec = SealedBoxCodec(identity);

  /// The real thing: this install's identity, the app's border relay, and
  /// a file beside the other letter files.
  factory SealedLetterService.disk({
    required AppIdentity identity,
    required String relayHost,
    void Function(String event, Map<String, Object?> fields)? onEvent,
  }) => SealedLetterService(
    identity: identity,
    door: RelayMailboxDoor.borderRelay(relayHost),
    storage: DiskJsonStorage(
      directoryFactory: intelligenceStorageDirectory,
      fileName: fileName,
    ),
    onEvent: onEvent,
  );

  static const String fileName = 'sealed_letters.json';

  final AppIdentity _identity;
  final MailboxDoor door;
  final PersistentStorage storage;
  final DateTime Function() _clock;
  final SealedBoxCodec _codec;

  /// Raw facts as they happen (`tx`, `rx`, `receipt_tx`, `receipt_rx`,
  /// `rejected`): public ids, sizes and flags only — never a body, never a
  /// key. A rig run prints these; the app ignores them.
  final void Function(String event, Map<String, Object?> fields)? onEvent;

  final Duration pollWait;
  final Duration retryBase;
  final Duration retryCap;

  /// Letters that opened here, oldest first.
  final ValueNotifier<List<SealedReceived>> inbox =
      ValueNotifier<List<SealedReceived>>(const []);

  /// Letters written here, oldest first, with whether each was opened.
  final ValueNotifier<List<SealedSent>> outbox =
      ValueNotifier<List<SealedSent>>(const []);

  /// Whether the door answered the last time it was asked; null before.
  final ValueNotifier<bool?> doorUp = ValueNotifier<bool?>(null);

  final List<_Queued> _queue = <_Queued>[];
  final List<_Kept> _kept = <_Kept>[];
  Future<void> _chain = Future<void>.value();
  String? _ownInstall;
  bool _loaded = false;
  bool _running = false;
  bool _disposed = false;
  Future<void>? _loop;

  Future<String> _own() async =>
      _ownInstall ??= _hex(await _identity.installId());

  /// One thing at a time: the file and the lists are never touched by two
  /// operations at once.
  Future<T> _serial<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        done.complete(await action());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  /// Reads the file and opens what it holds. Safe to call again.
  Future<void> load() => _serial(_load);

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final data = await storage.load();
    for (final raw in (data['outbox'] as List? ?? const [])) {
      final entry = _Queued.tryParse(raw);
      if (entry != null) _queue.add(entry);
    }
    for (final raw in (data['inbox'] as List? ?? const [])) {
      final entry = _Kept.tryParse(raw);
      if (entry != null) _kept.add(entry);
    }
    await _publish();
  }

  Future<void> _save() => storage.save(<String, Object?>{
    'v': 1,
    'outbox': [for (final q in _queue) q.toJson()],
    'inbox': [for (final k in _kept) k.toJson()],
  });

  /// Rebuilds both lists from the sealed copies: what the screen shows is
  /// always what the boxes on disk open to.
  Future<void> _publish() async {
    final sent = <SealedSent>[];
    for (final q in _queue) {
      final own = await _codec.open(q.selfBox);
      if (own == null) continue;
      sent.add(
        SealedSent(
          id: q.id,
          to: q.to,
          body: own.body,
          at: q.at,
          attempts: q.attempts,
          deliveredAt: q.deliveredAt,
        ),
      );
    }
    final received = <SealedReceived>[];
    for (final k in _kept) {
      final opened = await _codec.open(k.box);
      if (opened == null) continue;
      received.add(
        SealedReceived(
          id: opened.letterId,
          from: opened.senderInstall,
          body: opened.body,
          sentAt: opened.createdAt,
          receivedAt: k.at,
          verified: await _identity.isVerified(
            opened.senderInstall,
            opened.senderKey,
          ),
        ),
      );
    }
    if (_disposed) return;
    outbox.value = List<SealedSent>.unmodifiable(sent);
    inbox.value = List<SealedReceived>.unmodifiable(received);
  }

  /// Seals [body] to the key pinned for [toInstall], queues it, and tries
  /// the door once. Returns as soon as the letter is safely queued; whether
  /// it was opened is told by [outbox]. Throws [NotPinnedError] when no key
  /// is pinned for [toInstall].
  Future<SealedSent> send({
    required String toInstall,
    required Uint8List body,
  }) async {
    final sent = await _serial(() async {
      await _load();
      final key = await _identity.store.pinnedKeyFor(toInstall);
      if (key == null) throw NotPinnedError(toInstall);
      final own = await _own();
      final ownKey = (await _identity.store.localIdentity()).publicKey;
      final now = _clock();
      final id = _codec.newLetterId();
      final box = await _codec.seal(
        recipientInstall: toInstall,
        recipientKey: key,
        kind: SealedKind.letter,
        letterId: id,
        createdAt: now,
        body: body,
      );
      // The same letter sealed to this install's own key, so the sender
      // can read what it sent without keeping it in the clear.
      final selfBox = await _codec.seal(
        recipientInstall: own,
        recipientKey: ownKey,
        kind: SealedKind.letter,
        letterId: id,
        createdAt: now,
        body: body,
      );
      _queue.add(
        _Queued(
          id: id,
          to: toInstall,
          box: box,
          selfBox: selfBox,
          bodySha: await _sha(body),
          at: now,
          nextAt: now,
        ),
      );
      await _save();
      await _publish();
      return outbox.value.firstWhere((s) => s.id == id);
    });
    unawaited(flush().catchError((Object _) {}));
    return sent;
  }

  /// Puts every waiting letter whose pause is over into its recipient's
  /// mailbox again.
  Future<void> flush() => _serial(() async {
    await _load();
    final now = _clock();
    var changed = false;
    for (final q in _queue) {
      if (q.deliveredAt != null || q.nextAt.isAfter(now)) continue;
      final ok = await door.deposit(q.to, q.box);
      doorUp.value = ok;
      q.attempts++;
      q.nextAt = now.add(_pause(q.attempts));
      changed = true;
      onEvent?.call('tx', <String, Object?>{
        'id': q.id,
        'from': await _own(),
        'to': q.to,
        'box_bytes': q.box.length,
        'attempt': q.attempts,
        'deposited': ok,
      });
    }
    if (changed) {
      await _save();
      await _publish();
    }
  });

  Duration _pause(int attempts) {
    var pause = retryBase;
    for (var i = 1; i < attempts && pause < retryCap; i++) {
      pause *= 2;
    }
    return pause > retryCap ? retryCap : pause;
  }

  /// Reads this install's own mailbox once and deals with what was there.
  /// Returns false when the door was down.
  Future<bool> pollOnce({Duration wait = Duration.zero}) async {
    await load();
    // The wait happens outside the serial section, so a Send is never
    // stuck behind a long-poll.
    final taken = await door.take(await _own(), wait: wait);
    doorUp.value = taken != null;
    if (taken == null) return false;
    if (taken.isEmpty) return true;
    await _serial(() => _handle(taken));
    return true;
  }

  Future<void> _handle(Uint8List taken) async {
    final own = await _own();
    var changed = false;
    for (final box in SealedBoxCodec.split(taken)) {
      final opened = await _codec.open(box);
      if (opened == null) {
        onEvent?.call('rejected', <String, Object?>{
          'why': 'unopenable',
          'box_bytes': box.length,
        });
        continue;
      }
      final pinned = await _identity.store.pinnedKeyFor(opened.senderInstall);
      if (pinned == null || !listEquals(pinned, opened.senderKey)) {
        // A valid box from a key this install never pinned, or from a
        // different key than the pinned one: not a contact. Nothing is
        // shown and nothing is answered.
        onEvent?.call('rejected', <String, Object?>{
          'why': pinned == null ? 'sender_not_pinned' : 'sender_key_changed',
          'from': opened.senderInstall,
        });
        continue;
      }
      switch (opened.kind) {
        case SealedKind.letter:
          final seen = _kept.any((k) => k.id == opened.letterId);
          if (!seen) {
            _kept.add(_Kept(id: opened.letterId, box: box, at: _clock()));
            changed = true;
            onEvent?.call('rx', <String, Object?>{
              'id': opened.letterId,
              'from': opened.senderInstall,
              'to': own,
              'bytes': opened.body.length,
              'box_bytes': box.length,
              'opened': true,
              'verified': await _identity.isVerified(
                opened.senderInstall,
                opened.senderKey,
              ),
            });
          }
          // Every copy is answered: a second copy means the first receipt
          // never reached the sender.
          final receipt = await _codec.seal(
            recipientInstall: opened.senderInstall,
            recipientKey: opened.senderKey,
            kind: SealedKind.receipt,
            letterId: opened.letterId,
            createdAt: _clock(),
            body: await _sha(opened.body),
          );
          final ok = await door.deposit(opened.senderInstall, receipt);
          onEvent?.call('receipt_tx', <String, Object?>{
            'id': opened.letterId,
            'from': own,
            'to': opened.senderInstall,
            'deposited': ok,
            'duplicate': seen,
          });
        case SealedKind.receipt:
          for (final q in _queue) {
            if (q.id != opened.letterId ||
                q.to != opened.senderInstall ||
                q.deliveredAt != null ||
                !listEquals(q.bodySha, opened.body)) {
              continue;
            }
            q.deliveredAt = _clock();
            changed = true;
            onEvent?.call('receipt_rx', <String, Object?>{
              'id': q.id,
              'from': opened.senderInstall,
              'to': own,
              'attempts': q.attempts,
            });
          }
      }
    }
    if (changed) {
      await _save();
      await _publish();
    }
  }

  /// Keeps reading the mailbox and re-sending what still waits, until
  /// [stop]. A door that is down is asked again after a short pause.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    _loop = () async {
      while (_running && !_disposed) {
        try {
          await flush();
          final up = await pollOnce(wait: pollWait);
          if (!up && _running) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        } catch (_) {
          // The loop outlives any one bad round.
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
    }();
  }

  Future<void> stop() async {
    _running = false;
  }

  Future<void> dispose() async {
    _running = false;
    _disposed = true;
    await door.dispose();
    await _loop?.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  Future<Uint8List> _sha(List<int> bytes) async =>
      Uint8List.fromList((await Sha256().hash(bytes)).bytes);
}

/// A letter waiting for its receipt.
class _Queued {
  _Queued({
    required this.id,
    required this.to,
    required this.box,
    required this.selfBox,
    required this.bodySha,
    required this.at,
    required this.nextAt,
    this.attempts = 0,
    this.deliveredAt,
  });

  final String id;
  final String to;
  final Uint8List box;
  final Uint8List selfBox;
  final Uint8List bodySha;
  final DateTime at;
  DateTime nextAt;
  int attempts;
  DateTime? deliveredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'to': to,
    'box': base64.encode(box),
    'self_box': base64.encode(selfBox),
    'body_sha': base64.encode(bodySha),
    'at': at.toUtc().toIso8601String(),
    'next_at': nextAt.toUtc().toIso8601String(),
    'attempts': attempts,
    'delivered_at': deliveredAt?.toUtc().toIso8601String(),
  };

  static _Queued? tryParse(Object? raw) {
    try {
      final map = raw as Map;
      final delivered = map['delivered_at'] as String?;
      return _Queued(
        id: map['id'] as String,
        to: map['to'] as String,
        box: base64.decode(map['box'] as String),
        selfBox: base64.decode(map['self_box'] as String),
        bodySha: base64.decode(map['body_sha'] as String),
        at: DateTime.parse(map['at'] as String),
        nextAt: DateTime.parse(map['next_at'] as String),
        attempts: (map['attempts'] as num).toInt(),
        deliveredAt: delivered == null ? null : DateTime.parse(delivered),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A box that opened here, kept as it arrived.
class _Kept {
  _Kept({required this.id, required this.box, required this.at});

  final String id;
  final Uint8List box;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'box': base64.encode(box),
    'at': at.toUtc().toIso8601String(),
  };

  static _Kept? tryParse(Object? raw) {
    try {
      final map = raw as Map;
      return _Kept(
        id: map['id'] as String,
        box: base64.decode(map['box'] as String),
        at: DateTime.parse(map['at'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
