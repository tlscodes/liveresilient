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
// A photo, a voice note or a video is a letter that describes it (size,
// SHA-256, number of pieces) plus the pieces, each its own sealed box. The
// recipient asks for the pieces it lacks, so only those are sent again, and
// gives its receipt only when the whole verified against the description.
//
// At rest nothing is in the clear: the queue holds the sealed box plus a
// copy sealed to this install's own key (so the sender can still read what
// it sent), and the inbox holds the boxes as they arrived.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';

import '../broadcast_wiring.dart' show IoBroadcastHttpTransport;
import '../intelligence/device_bindings.dart' show intelligenceStorageDirectory;
import '../intelligence/disk_json_storage.dart';
import '../peer_identity.dart';
import 'mailbox_door.dart';
import 'pair_shelf.dart';
import 'sealed_blob_store.dart';
import 'sealed_box.dart';
import 'sealed_content.dart';

/// Where a letter this install wrote is, in words a screen can show as
/// they are. There is no "sending…": a letter is in the queue until its
/// receipt is here, and the reason it is still there is always known.
enum SealedSentState {
  /// The mailbox could not be reached at all; nothing has left yet.
  queuedDoorClosed,

  /// The box was put in their mailbox and no receipt has come: they are
  /// not reading it, or the relay dropped it. It will be put in again.
  queuedNoReceipt,

  /// Their receipt is here: it opened on their device.
  opened,
}

/// A letter this install wrote.
@immutable
class SealedSent {
  const SealedSent({
    required this.id,
    required this.to,
    required this.content,
    required this.at,
    required this.attempts,
    required this.everDeposited,
    this.onShelf = false,
    required this.nextAt,
    required this.deliveredAt,
  });

  final String id;
  final String to;
  final SealedContent content;
  final DateTime at;

  /// How many times the box was put in the recipient's mailbox.
  final int attempts;

  /// Whether the relay ever took it.
  final bool everDeposited;

  /// It is on the relay's shelf, where it waits for a recipient who is
  /// away, rather than only in this install's own queue.
  final bool onShelf;

  /// When it is put in again, while it waits.
  final DateTime nextAt;

  /// When the recipient's receipt arrived; null while the letter waits.
  final DateTime? deliveredAt;

  bool get delivered => deliveredAt != null;
  String get text => content.text ?? content.summary;
  int get bytes => content.bytes;

  SealedSentState get state => delivered
      ? SealedSentState.opened
      : everDeposited
      ? SealedSentState.queuedNoReceipt
      : SealedSentState.queuedDoorClosed;

  /// The whole truth about this letter in one line, for the screen.
  String describe(DateTime now) {
    switch (state) {
      case SealedSentState.opened:
        return 'opened by them';
      case SealedSentState.queuedDoorClosed:
        return 'in queue — mailbox unreachable, tried $attempts×';
      case SealedSentState.queuedNoReceipt when onShelf:
        return 'on the relay, not opened yet — it waits there about '
            'two days for them';
      case SealedSentState.queuedNoReceipt:
        final late = now.difference(at) > const Duration(minutes: 10);
        final wait = nextAt.difference(now).inSeconds;
        return '${late ? 'not delivered yet' : 'in queue'} — put in their '
            'mailbox $attempts×, no receipt: they are not reading it'
            '${wait > 0 ? ' · again in ${wait}s' : ''}';
    }
  }
}

/// A letter that opened on this install, from a pinned sender.
@immutable
class SealedReceived {
  const SealedReceived({
    required this.id,
    required this.from,
    required this.content,
    required this.media,
    required this.sentAt,
    required this.receivedAt,
    required this.verified,
  });

  final String id;
  final String from;
  final SealedContent content;

  /// The photo, voice or video itself, verified against the description;
  /// null for a text.
  final Uint8List? media;
  final DateTime sentAt;
  final DateTime receivedAt;

  /// Whether the sender's key was confirmed by comparing safety numbers.
  /// False is the ordinary "encrypted, not yet verified".
  final bool verified;

  String get text => content.text ?? content.summary;
  int get bytes => content.bytes;

  /// The text's bytes, or the media's.
  Uint8List get body =>
      media ?? Uint8List.fromList(utf8.encode(content.text ?? ''));
}

/// Thrown by [SealedLetterService.send] for an install nobody pinned: there
/// is no key to lock the letter to.
class NotPinnedError extends StateError {
  NotPinnedError(String install) : super('no pinned key for $install');
}

/// The app's one mailbox service, once this install has an identity; null
/// before, and on a host with no identity. A rig driver reads it; the app's
/// own screens are handed the service directly.
final ValueNotifier<SealedLetterService?> sealedLetterService =
    ValueNotifier<SealedLetterService?>(null);

class SealedLetterService {
  SealedLetterService({
    required AppIdentity identity,
    required this.door,
    required this.storage,
    SealedBlobStore? blobs,
    this.shelf,
    DateTime Function()? clock,
    this.onEvent,
    this.pollWait = const Duration(seconds: 20),
    this.retryBase = const Duration(seconds: 5),
    this.retryCap = const Duration(minutes: 5),
    this.needQuiet = const Duration(seconds: 3),
    this.needEvery = const Duration(seconds: 6),
    this.shelfRefresh = const Duration(hours: 40),
  }) : _identity = identity,
       blobs = blobs ?? MemorySealedBlobStore(),
       _clock = clock ?? DateTime.now,
       _codec = SealedBoxCodec(identity);

  /// The real thing: this install's identity, the app's border relay, and
  /// files beside the other letter files. Every event is also appended to
  /// `sealed_events.jsonl` there — ids, sizes, times and flags, never a
  /// body — so what happened can be read back after the fact.
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
    blobs: DiskSealedBlobStore(
      () => Directory('${intelligenceStorageDirectory().path}/sealed_blobs'),
    ),
    shelf: PairShelf(
      identity: identity,
      origin: Uri(scheme: 'https', host: relayHost),
      transport: IoBroadcastHttpTransport(),
    ),
    onEvent: (event, fields) {
      _journal(event, fields);
      onEvent?.call(event, fields);
    },
  );

  static const String fileName = 'sealed_letters.json';
  static const String journalName = 'sealed_events.jsonl';

  static void _journal(String event, Map<String, Object?> fields) {
    try {
      File(
        '${intelligenceStorageDirectory().path}/$journalName',
      ).writeAsStringSync(
        '${jsonEncode(<String, Object?>{'at': DateTime.now().toUtc().toIso8601String(), 'event': event, ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // The journal is evidence, never a dependency.
    }
  }

  final AppIdentity _identity;
  final MailboxDoor door;
  final PersistentStorage storage;
  final SealedBlobStore blobs;

  /// Where boxes wait for a recipient who is away. With a shelf, every
  /// box goes there and the mailbox only rings; without one (a relay
  /// that has no archive) boxes go through the mailbox and reach only
  /// a recipient who is reading it.
  final LetterShelf? shelf;

  /// How long after shelving a letter that still has no receipt it is
  /// shelved again — before the relay's two days run out.
  final Duration shelfRefresh;
  final DateTime Function() _clock;
  final SealedBoxCodec _codec;

  /// Raw facts as they happen (`tx`, `rx`, `receipt_tx`, `receipt_rx`,
  /// `here_tx`, `here_rx`, `need_tx`, `need_rx`, `rejected`): public ids,
  /// sizes, times and flags only — never a body, never a key.
  final void Function(String event, Map<String, Object?> fields)? onEvent;

  final Duration pollWait;
  final Duration retryBase;
  final Duration retryCap;

  /// How long no piece must have arrived before the missing ones are
  /// asked for, and how often at most they are asked for again.
  final Duration needQuiet;
  final Duration needEvery;

  /// Letters that opened here, oldest first.
  final ValueNotifier<List<SealedReceived>> inbox =
      ValueNotifier<List<SealedReceived>>(const []);

  /// Letters written here, oldest first, with where each one is.
  final ValueNotifier<List<SealedSent>> outbox =
      ValueNotifier<List<SealedSent>>(const []);

  /// Whether the door answered the last time it was asked; null before.
  final ValueNotifier<bool?> doorUp = ValueNotifier<bool?>(null);

  final List<_Queued> _queue = <_Queued>[];
  final List<_Kept> _kept = <_Kept>[];
  final Map<String, _Partial> _partial = <String, _Partial>{};
  final Map<String, Uint8List> _media = <String, Uint8List>{};
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
    final cursors = data['shelf'];
    if (cursors is Map) {
      cursors.forEach((key, value) {
        if (value is num) shelf?.cursors['$key'] = value.toInt();
      });
    }
    for (final raw in (data['outbox'] as List? ?? const [])) {
      final entry = _Queued.tryParse(raw);
      if (entry != null) _queue.add(entry);
    }
    for (final raw in (data['inbox'] as List? ?? const [])) {
      final entry = _Kept.tryParse(raw);
      if (entry != null) _kept.add(entry);
    }
    for (final raw in (data['partial'] as List? ?? const [])) {
      final entry = _Kept.tryParse(raw);
      if (entry == null) continue;
      final opened = await _codec.open(entry.box);
      final media = opened == null
          ? null
          : SealedContent.decode(opened.body).media;
      if (opened == null || media == null) continue;
      final partial = _Partial(
        id: entry.id,
        from: opened.senderInstall,
        senderKey: opened.senderKey,
        box: entry.box,
        media: media,
        at: entry.at,
      );
      for (final name in await blobs.list('in.${entry.id}.')) {
        final index = int.tryParse(name.split('.').last);
        if (index != null && index < media.chunks) partial.have.add(index);
      }
      _partial[entry.id] = partial;
    }
    await _publish();
  }

  Future<void> _save() => storage.save(<String, Object?>{
    'v': 2,
    'outbox': [for (final q in _queue) q.toJson()],
    'inbox': [for (final k in _kept) k.toJson()],
    'partial': [
      for (final p in _partial.values)
        _Kept(id: p.id, box: p.box, at: p.at).toJson(),
    ],
    'shelf': shelf?.cursors ?? const <String, int>{},
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
          content: SealedContent.decode(own.body),
          at: q.at,
          attempts: q.attempts,
          everDeposited: q.everDeposited,
          onShelf: shelf != null && q.everDeposited,
          nextAt: q.nextAt,
          deliveredAt: q.deliveredAt,
        ),
      );
    }
    final received = <SealedReceived>[];
    for (final k in _kept) {
      final opened = await _codec.open(k.box);
      if (opened == null) continue;
      final content = SealedContent.decode(opened.body);
      Uint8List? media;
      final described = content.media;
      if (described != null) {
        media = _media[k.id] ??=
            await _assemble(k.id, described) ?? Uint8List(0);
        if (media.isEmpty) continue; // Its pieces are gone: nothing to show.
      }
      received.add(
        SealedReceived(
          id: opened.letterId,
          from: opened.senderInstall,
          content: content,
          media: media,
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

  /// Opens every piece of letter [id] and joins them; null when a piece is
  /// missing, does not open, or the whole is not what was described.
  Future<Uint8List?> _assemble(String id, SealedMedia media) async {
    final whole = BytesBuilder(copy: false);
    for (var i = 0; i < media.chunks; i++) {
      final box = await blobs.get('in.$id.$i');
      if (box == null) return null;
      final opened = await _codec.open(box);
      if (opened == null ||
          opened.kind != SealedKind.chunk ||
          opened.letterId != id ||
          opened.body.length < 2 ||
          ByteData.sublistView(opened.body).getUint16(0) != i) {
        return null;
      }
      whole.add(Uint8List.sublistView(opened.body, 2));
    }
    final bytes = whole.takeBytes();
    if (bytes.length != media.size ||
        !listEquals(await _sha(bytes), media.sha256)) {
      return null;
    }
    return bytes;
  }

  /// Seals the text [body] to the key pinned for [toInstall], queues it,
  /// and tries the door once. Returns as soon as the letter is safely
  /// queued; where it is from then on is told by [outbox]. Throws
  /// [NotPinnedError] when no key is pinned for [toInstall].
  Future<SealedSent> send({
    required String toInstall,
    required Uint8List body,
  }) => _enqueue(
    toInstall,
    SealedContent.text(utf8.decode(body, allowMalformed: true)),
    null,
  );

  /// Seals a photo, voice note or video for [toInstall]: one letter that
  /// describes it and one sealed box per piece. Throws [ArgumentError] when
  /// it is empty or over [sealedMaxMediaBytes].
  Future<SealedSent> sendMedia({
    required String toInstall,
    required SealedMediaKind kind,
    required String contentType,
    required Uint8List bytes,
    Duration duration = Duration.zero,
    String caption = '',
  }) async {
    if (bytes.isEmpty || bytes.length > sealedMaxMediaBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'must be 1..$sealedMaxMediaBytes',
      );
    }
    return _enqueue(
      toInstall,
      SealedContent.media(
        SealedMedia(
          kind: kind,
          contentType: contentType,
          size: bytes.length,
          sha256: await _sha(bytes),
          chunks: (bytes.length + sealedChunkBytes - 1) ~/ sealedChunkBytes,
          duration: duration,
          caption: caption,
        ),
      ),
      bytes,
    );
  }

  Future<SealedSent> _enqueue(
    String toInstall,
    SealedContent content,
    Uint8List? mediaBytes,
  ) async {
    final sent = await _serial(() async {
      await _load();
      final key = await _identity.store.pinnedKeyFor(toInstall);
      if (key == null) throw NotPinnedError(toInstall);
      final own = await _own();
      final ownKey = (await _identity.store.localIdentity()).publicKey;
      final now = _clock();
      final id = _codec.newLetterId();
      final body = content.encode();
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
      final chunks = content.media?.chunks ?? 0;
      if (mediaBytes != null) {
        for (var i = 0; i < chunks; i++) {
          final from = i * sealedChunkBytes;
          final to = from + sealedChunkBytes > mediaBytes.length
              ? mediaBytes.length
              : from + sealedChunkBytes;
          final piece = Uint8List(2 + to - from);
          ByteData.sublistView(piece).setUint16(0, i);
          piece.setAll(2, Uint8List.sublistView(mediaBytes, from, to));
          await blobs.put(
            'out.$id.$i',
            await _codec.seal(
              recipientInstall: toInstall,
              recipientKey: key,
              kind: SealedKind.chunk,
              letterId: id,
              createdAt: now,
              body: piece,
            ),
          );
        }
      }
      _queue.add(
        _Queued(
          id: id,
          to: toInstall,
          box: box,
          selfBox: selfBox,
          bodySha: await _sha(body),
          at: now,
          nextAt: now,
          kind: content.kindLabel,
          bytes: content.bytes,
          chunks: chunks,
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
  /// mailbox again. A media letter's pieces go with it the first time (and
  /// again when its recipient says it is there); after that the letter
  /// alone is enough, because the recipient asks for what it lacks.
  Future<void> flush() => _serial(() async {
    await _load();
    final now = _clock();
    var changed = false;
    for (final q in _queue) {
      if (q.deliveredAt != null || q.nextAt.isAfter(now)) continue;
      // Shelved before and due again: its two days are nearly up, so
      // the letter and every piece are shelved afresh.
      if (shelf != null && q.everDeposited) q.piecesPushed = false;
      var ok = await _put(q.to, q.box);
      var pieces = 0;
      if (ok && q.chunks > 0 && !q.piecesPushed) {
        pieces = await _depositPieces(q, null);
        ok = pieces == q.chunks;
        q.piecesPushed = ok;
      }
      doorUp.value = ok;
      q.attempts++;
      q.everDeposited = q.everDeposited || ok;
      q.nextAt = now.add(
        ok && shelf != null ? shelfRefresh : _pause(q.attempts),
      );
      if (ok) await _ring(q.to);
      changed = true;
      onEvent?.call('tx', <String, Object?>{
        'via': shelf != null ? 'shelf' : 'mailbox',
        'id': q.id,
        'kind': q.kind,
        'from': await _own(),
        'to': q.to,
        'bytes': q.bytes,
        'sent_at': q.at.toUtc().toIso8601String(),
        'attempt': q.attempts,
        'deposited': ok,
        'pieces_sent': pieces,
      });
    }
    if (changed) {
      await _save();
      await _publish();
    }
  });

  /// Hands one box over: onto the shelf when there is one, where it
  /// waits for a recipient who is away; otherwise into the mailbox,
  /// which keeps it only for a recipient who is reading.
  Future<bool> _put(String to, Uint8List box) {
    final shelf = this.shelf;
    return shelf != null ? shelf.put(to, box) : door.deposit(to, box);
  }

  /// Rings [to]'s mailbox after something was shelved for it, so a
  /// recipient who is reading looks at the shelf now instead of at its
  /// next round. Lost without harm: the box is on the shelf.
  Future<void> _ring(String to) async {
    if (shelf == null) return;
    final key = await _identity.store.pinnedKeyFor(to);
    if (key == null) return;
    await door.deposit(
      to,
      await _codec.seal(
        recipientInstall: to,
        recipientKey: key,
        kind: SealedKind.here,
        letterId: _codec.newLetterId(),
        createdAt: _clock(),
        body: Uint8List(0),
      ),
    );
  }

  /// Puts pieces of [q] in its recipient's mailbox: [only] those, or all.
  /// Returns how many the relay took; stops at the first it refuses.
  Future<int> _depositPieces(_Queued q, Iterable<int>? only) async {
    var sent = 0;
    for (final i in only ?? Iterable<int>.generate(q.chunks)) {
      if (i < 0 || i >= q.chunks) continue;
      final box = await blobs.get('out.${q.id}.$i');
      if (box == null) continue;
      if (!await _put(q.to, box)) break;
      sent++;
    }
    return sent;
  }

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
    var reachable = taken != null;
    // Then the shelves: what each pinned peer left since the last look.
    // This is where a letter written while this install was away is.
    final shelf = this.shelf;
    final shelved = <Uint8List>[];
    final cursorsBefore = shelf == null ? '' : jsonEncode(shelf.cursors);
    if (shelf != null) {
      for (final peer in await _identity.pinnedInstalls()) {
        final boxes = await shelf.collect(peer);
        if (boxes == null) continue;
        reachable = true;
        shelved.addAll(boxes);
      }
    }
    doorUp.value = reachable;
    if (!reachable) return false;
    await _serial(() async {
      if (taken != null && taken.isNotEmpty) {
        await _handleBoxes(SealedBoxCodec.split(taken));
      }
      if (shelved.isNotEmpty) await _handleBoxes(shelved);
      await _progress();
      await _flushReceipts();
      if (shelf != null && jsonEncode(shelf.cursors) != cursorsBefore) {
        await _save();
      }
    });
    return true;
  }

  Future<void> _handleBoxes(List<Uint8List> boxes) async {
    final own = await _own();
    var changed = false;
    var resend = false;
    for (final box in boxes) {
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
          final content = SealedContent.decode(opened.body);
          final media = content.media;
          final seen = _kept.any((k) => k.id == opened.letterId);
          if (media != null && !seen) {
            // A described photo, voice or video: kept aside until every
            // piece is here. Its receipt waits for that too.
            if (!_partial.containsKey(opened.letterId)) {
              final partial = _Partial(
                id: opened.letterId,
                from: opened.senderInstall,
                senderKey: opened.senderKey,
                box: box,
                media: media,
                at: _clock(),
              );
              for (final name in await blobs.list('in.${partial.id}.')) {
                final index = int.tryParse(name.split('.').last);
                if (index != null && index < media.chunks) {
                  partial.have.add(index);
                }
              }
              _partial[partial.id] = partial;
              changed = true;
            }
            continue;
          }
          if (!seen) {
            _kept.add(_Kept(id: opened.letterId, box: box, at: _clock()));
            changed = true;
            _rx(opened, content, own, box.length);
          }
          // Through the mailbox every copy is answered: a second copy
          // means the first receipt never reached the sender. On a shelf
          // a receipt that was shelved is there to be read, so a copy is
          // answered only if its receipt never got onto the shelf.
          final kept = _kept.firstWhere((k) => k.id == opened.letterId);
          if (shelf == null || !kept.receiptOk) {
            kept.receiptOk = await _receipt(opened, own, duplicate: seen);
            changed = true;
          }
        case SealedKind.chunk:
          if (opened.body.length < 3) continue;
          final index = ByteData.sublistView(opened.body).getUint16(0);
          final partial = _partial[opened.letterId];
          if (_kept.any((k) => k.id == opened.letterId) ||
              index >= (partial?.media.chunks ?? 64)) {
            continue; // Already whole, or not a piece of anything.
          }
          await blobs.put('in.${opened.letterId}.$index', box);
          if (partial != null) {
            partial.have.add(index);
            partial.lastPieceAt = _clock();
          }
        case SealedKind.need:
          for (final q in _queue) {
            if (q.id != opened.letterId ||
                q.to != opened.senderInstall ||
                q.deliveredAt != null ||
                q.chunks == 0) {
              continue;
            }
            final asked = <int>[
              for (var at = 0; at + 1 < opened.body.length; at += 2)
                ByteData.sublistView(opened.body).getUint16(at),
            ];
            final sent = await _depositPieces(q, asked.isEmpty ? null : asked);
            onEvent?.call('need_rx', <String, Object?>{
              'id': q.id,
              'from': opened.senderInstall,
              'to': own,
              'asked': asked.isEmpty ? q.chunks : asked.length,
              'pieces_sent': sent,
            });
          }
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
            await blobs.deletePrefix('out.${q.id}.');
            onEvent?.call('receipt_rx', <String, Object?>{
              'id': q.id,
              'kind': q.kind,
              'from': opened.senderInstall,
              'to': own,
              'bytes': q.bytes,
              'sent_at': q.at.toUtc().toIso8601String(),
              'receipt_at': q.deliveredAt!.toUtc().toIso8601String(),
              'attempts': q.attempts,
            });
          }
        case SealedKind.here:
          // The peer is reading its mailbox now: whatever waits for it
          // goes again at once — pieces included — instead of at the end
          // of its pause.
          var waiting = 0;
          for (final q in _queue) {
            if (q.to != opened.senderInstall || q.deliveredAt != null) {
              continue;
            }
            // Already on the shelf: it is there to be read.
            if (shelf != null && q.everDeposited) continue;
            q.nextAt = _clock();
            q.piecesPushed = false;
            waiting++;
          }
          onEvent?.call('here_rx', <String, Object?>{
            'from': opened.senderInstall,
            'to': own,
            'waiting_for_them': waiting,
          });
          if (waiting > 0) resend = true;
      }
    }
    if (changed) {
      await _save();
      await _publish();
    }
    if (resend) unawaited(flush().catchError((Object _) {}));
  }

  void _rx(OpenedBox opened, SealedContent content, String own, int boxBytes) {
    onEvent?.call('rx', <String, Object?>{
      'id': opened.letterId,
      'kind': content.kindLabel,
      'from': opened.senderInstall,
      'to': own,
      'bytes': content.bytes,
      'box_bytes': boxBytes,
      'sent_at': opened.createdAt.toUtc().toIso8601String(),
      'opened_at': _clock().toUtc().toIso8601String(),
      'opened': true,
    });
  }

  Future<bool> _receipt(
    OpenedBox opened,
    String own, {
    required bool duplicate,
  }) async {
    final receipt = await _codec.seal(
      recipientInstall: opened.senderInstall,
      recipientKey: opened.senderKey,
      kind: SealedKind.receipt,
      letterId: opened.letterId,
      createdAt: _clock(),
      body: await _sha(opened.body),
    );
    final ok = await _put(opened.senderInstall, receipt);
    if (ok) await _ring(opened.senderInstall);
    onEvent?.call('receipt_tx', <String, Object?>{
      'id': opened.letterId,
      'from': own,
      'to': opened.senderInstall,
      'deposited': ok,
      'duplicate': duplicate,
    });
    return ok;
  }

  /// Shelves the receipts that could not be shelved when their letters
  /// opened (the relay was out of reach just then).
  Future<void> _flushReceipts() async {
    if (shelf == null) return;
    final own = await _own();
    var changed = false;
    for (final kept in _kept) {
      if (kept.receiptOk) continue;
      final opened = await _codec.open(kept.box);
      if (opened == null) {
        kept.receiptOk = true;
        continue;
      }
      kept.receiptOk = await _receipt(opened, own, duplicate: true);
      changed = changed || kept.receiptOk;
    }
    if (changed) await _save();
  }

  /// Finishes media letters whose pieces are all here, and asks for the
  /// pieces of those that have gone quiet.
  Future<void> _progress() async {
    if (_partial.isEmpty) return;
    final own = await _own();
    final now = _clock();
    var changed = false;
    for (final partial in _partial.values.toList()) {
      final opened = await _codec.open(partial.box);
      if (opened == null) {
        _partial.remove(partial.id);
        changed = true;
        continue;
      }
      if (partial.have.length >= partial.media.chunks) {
        final whole = await _assemble(partial.id, partial.media);
        if (whole != null) {
          _media[partial.id] = whole;
          _partial.remove(partial.id);
          final kept = _Kept(id: partial.id, box: partial.box, at: now);
          _kept.add(kept);
          changed = true;
          _rx(
            opened,
            SealedContent.decode(opened.body),
            own,
            partial.box.length,
          );
          kept.receiptOk = await _receipt(opened, own, duplicate: false);
          continue;
        }
        // Every piece is here and the whole is wrong: start over.
        await blobs.deletePrefix('in.${partial.id}.');
        partial.have.clear();
        onEvent?.call('rejected', <String, Object?>{
          'why': 'media_does_not_match_its_description',
          'id': partial.id,
          'from': partial.from,
        });
      }
      if (now.difference(partial.lastPieceAt) < needQuiet ||
          now.difference(partial.lastNeedAt) < needEvery) {
        continue;
      }
      final missing = <int>[
        for (var i = 0; i < partial.media.chunks; i++)
          if (!partial.have.contains(i)) i,
      ];
      final body = Uint8List(
        missing.length == partial.media.chunks ? 0 : missing.length * 2,
      );
      for (var i = 0; i * 2 < body.length; i++) {
        ByteData.sublistView(body).setUint16(i * 2, missing[i]);
      }
      final ok = await _put(
        partial.from,
        await _codec.seal(
          recipientInstall: partial.from,
          recipientKey: partial.senderKey,
          kind: SealedKind.need,
          letterId: partial.id,
          createdAt: now,
          body: body,
        ),
      );
      partial.lastNeedAt = now;
      onEvent?.call('need_tx', <String, Object?>{
        'id': partial.id,
        'from': own,
        'to': partial.from,
        'missing': missing.length,
        'of': partial.media.chunks,
        'deposited': ok,
      });
    }
    if (changed) {
      await _save();
      await _publish();
    }
  }

  /// Tells every pinned peer that this install is reading its mailbox now,
  /// and makes every letter still waiting here due at once. Called when the
  /// service starts and when the door comes back.
  ///
  /// It is a sealed box like any other — the relay cannot tell it from a
  /// letter — but a pinned peer who is listening does learn that this
  /// install is online.
  Future<void> announce() => _serial(() async {
    await _load();
    final now = _clock();
    for (final q in _queue) {
      // What is already on the shelf is there to be read: starting the app
      // must not put it there a second time.
      if (shelf != null && q.everDeposited) continue;
      if (q.deliveredAt == null) q.nextAt = now;
    }
    final own = await _own();
    for (final peer in await _identity.pinnedInstalls()) {
      final key = await _identity.store.pinnedKeyFor(peer);
      if (key == null || peer == own) continue;
      final box = await _codec.seal(
        recipientInstall: peer,
        recipientKey: key,
        kind: SealedKind.here,
        letterId: _codec.newLetterId(),
        createdAt: now,
        body: Uint8List(0),
      );
      final ok = await door.deposit(peer, box);
      doorUp.value = ok;
      onEvent?.call('here_tx', <String, Object?>{
        'from': own,
        'to': peer,
        'deposited': ok,
      });
    }
  });

  /// Keeps reading the mailbox and re-sending what still waits, until
  /// [stop]. A door that is down is asked again after a short pause.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    _loop = () async {
      // Null so the first round announces, like a door that just came up.
      bool? wasUp;
      while (_running && !_disposed) {
        try {
          if (wasUp != true) {
            // Only once the door answers: an announcement into a closed
            // door is nothing, and the next round would repeat it.
            final reachable = await pollOnce();
            if (reachable) await announce();
            wasUp = reachable;
          }
          await flush();
          // While a media letter is still coming, the mailbox is read in
          // short rounds so the missing pieces are asked for promptly.
          final up = await pollOnce(
            wait: _partial.isEmpty ? pollWait : needQuiet,
          );
          wasUp = up;
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
    this.kind = 'text',
    this.bytes = 0,
    this.chunks = 0,
    this.attempts = 0,
    this.everDeposited = false,
    this.piecesPushed = false,
    this.deliveredAt,
  });

  final String id;
  final String to;
  final Uint8List box;
  final Uint8List selfBox;
  final Uint8List bodySha;
  final DateTime at;
  final String kind;
  final int bytes;

  /// How many pieces travel beside the letter; zero for a text.
  final int chunks;
  DateTime nextAt;
  int attempts;
  bool everDeposited;

  /// Whether every piece has been put in the mailbox since the recipient
  /// last said it was there.
  bool piecesPushed;
  DateTime? deliveredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'to': to,
    'box': base64.encode(box),
    'self_box': base64.encode(selfBox),
    'body_sha': base64.encode(bodySha),
    'at': at.toUtc().toIso8601String(),
    'next_at': nextAt.toUtc().toIso8601String(),
    'kind': kind,
    'bytes': bytes,
    'chunks': chunks,
    'attempts': attempts,
    'ever_deposited': everDeposited,
    'pieces_pushed': piecesPushed,
    'delivered_at': deliveredAt?.toUtc().toIso8601String(),
  };

  static _Queued? tryParse(Object? raw) {
    try {
      final map = raw as Map;
      final delivered = map['delivered_at'] as String?;
      final attempts = (map['attempts'] as num).toInt();
      return _Queued(
        id: map['id'] as String,
        to: map['to'] as String,
        box: base64.decode(map['box'] as String),
        selfBox: base64.decode(map['self_box'] as String),
        bodySha: base64.decode(map['body_sha'] as String),
        at: DateTime.parse(map['at'] as String),
        nextAt: DateTime.parse(map['next_at'] as String),
        kind: map['kind'] as String? ?? 'text',
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        chunks: (map['chunks'] as num?)?.toInt() ?? 0,
        attempts: attempts,
        // A file from before this was recorded: any attempt counted.
        everDeposited: map['ever_deposited'] as bool? ?? attempts > 0,
        piecesPushed: map['pieces_pushed'] as bool? ?? false,
        deliveredAt: delivered == null ? null : DateTime.parse(delivered),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A box that opened here, kept as it arrived.
class _Kept {
  _Kept({
    required this.id,
    required this.box,
    required this.at,
    this.receiptOk = false,
  });

  final String id;
  final Uint8List box;
  final DateTime at;

  /// Whether this letter's receipt was handed over.
  bool receiptOk;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'box': base64.encode(box),
    'at': at.toUtc().toIso8601String(),
    'receipt_ok': receiptOk,
  };

  static _Kept? tryParse(Object? raw) {
    try {
      final map = raw as Map;
      return _Kept(
        id: map['id'] as String,
        box: base64.decode(map['box'] as String),
        at: DateTime.parse(map['at'] as String),
        // A file from before this was recorded: its receipt went out
        // the old way, by answering every copy.
        receiptOk: map['receipt_ok'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A media letter whose pieces are still coming.
class _Partial {
  _Partial({
    required this.id,
    required this.from,
    required this.senderKey,
    required this.box,
    required this.media,
    required this.at,
  }) : lastPieceAt = at,
       lastNeedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final String id;
  final String from;
  final Uint8List senderKey;
  final Uint8List box;
  final SealedMedia media;
  final DateTime at;
  final Set<int> have = <int>{};
  DateTime lastPieceAt;
  DateTime lastNeedAt;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
