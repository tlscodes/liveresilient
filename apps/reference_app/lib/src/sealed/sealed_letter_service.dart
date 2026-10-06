// Sealed letters between installs that have pinned each other.
//
// To write, the sender seals the letter to the recipient's PINNED key and
// puts the box on the pair's shelf on the relay (pair_shelf.dart), where it
// waits about two days. The recipient reads the shelf, opens the box,
// checks that the key inside is the one it pinned for that install, and
// shelves a short receipt — itself a sealed box — for the sender.
//
// The sender keeps every letter until its receipt comes back. One that
// could not be shelved is tried again with a growing pause; one that was
// shelved and never answered is shelved afresh before the relay's two days
// run out. The recipient may therefore see a letter twice; it shows it once.
//
// Nothing rings. No request is held open waiting for the relay to speak,
// and no install tells its contacts that it is there. A reader finds out by
// looking, and how often it looks follows the conversation: every few
// seconds for two minutes after something was written or the screen was
// opened, then at twice the interval each time, down to once in fifteen
// minutes. Every request counts against a daily allowance
// (relay_requests.dart).
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

import '../intelligence/device_bindings.dart' show intelligenceStorageDirectory;
import '../intelligence/disk_json_storage.dart';
import '../peer_identity.dart';
import 'pair_shelf.dart';
import 'relay_requests.dart';
import 'sealed_blob_store.dart';
import 'sealed_box.dart';
import 'sealed_content.dart';

/// Where a letter this install wrote is, in words a screen can show as
/// they are. There is no "sending…": a letter is in the queue until its
/// receipt is here, and the reason it is still there is always known.
enum SealedSentState {
  /// Not on the relay yet: it could not be reached, or today's allowance
  /// of requests is used up. It is tried again.
  waiting,

  /// On the relay's shelf, where it waits about two days to be opened.
  shelved,

  /// Their receipt is here: it opened on their device.
  opened,
}

/// What the relay said the last time this install asked it anything.
enum SealedRelayState {
  /// Nothing has been asked yet.
  unknown,
  reachable,
  unreachable,

  /// Today's allowance of requests is used up: nothing more is asked
  /// until the next day (UTC).
  spent,
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
    required this.onShelf,
    required this.nextAt,
    required this.deliveredAt,
  });

  final String id;
  final String to;
  final SealedContent content;
  final DateTime at;

  /// How many times the box was handed to the relay.
  final int attempts;

  /// The relay took it, whole: it is on the shelf, where it waits for a
  /// recipient who is away.
  final bool onShelf;

  /// When it is handed to the relay again, while it waits.
  final DateTime nextAt;

  /// When the recipient's receipt arrived; null while the letter waits.
  final DateTime? deliveredAt;

  bool get delivered => deliveredAt != null;
  String get text => content.text ?? content.summary;
  int get bytes => content.bytes;

  SealedSentState get state => delivered
      ? SealedSentState.opened
      : onShelf
      ? SealedSentState.shelved
      : SealedSentState.waiting;

  /// The whole truth about this letter in one line, for the screen.
  String describe(DateTime now) {
    switch (state) {
      case SealedSentState.opened:
        return 'opened by them';
      case SealedSentState.shelved:
        return 'on the relay, not opened yet — it waits there about '
            'two days for them';
      case SealedSentState.waiting when attempts == 0:
        return 'in queue — not on the relay yet';
      case SealedSentState.waiting:
        final wait = nextAt.difference(now).inSeconds;
        return 'in queue — relay unreachable, tried $attempts×'
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

/// The app's one sealed-letter service, once this install has an identity;
/// null before, and on a host with no identity. A rig driver and the
/// diagnostics screen read it; the letters panel is handed the service
/// directly.
final ValueNotifier<SealedLetterService?> sealedLetterService =
    ValueNotifier<SealedLetterService?>(null);

class SealedLetterService {
  SealedLetterService({
    required AppIdentity identity,
    required this.shelf,
    required this.storage,
    SealedBlobStore? blobs,
    this.budget,
    DateTime Function()? clock,
    // `sleep:` — how the loop waits between looks. A test passes its own
    // and runs hours of schedule in an instant.
    this._sleep,
    this.onEvent,
    this.warmEvery = const Duration(seconds: 3),
    this.warmFor = const Duration(minutes: 2),
    this.coldEvery = const Duration(minutes: 15),
    this.slowEvery = const Duration(minutes: 30),
    this.aliveEvery = const Duration(seconds: 30),
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
  /// `sealed_events.jsonl` there — ids, sizes, times, counts and flags,
  /// never a body — so what happened can be read back after the fact.
  factory SealedLetterService.disk({
    required AppIdentity identity,
    required String relayHost,
    void Function(String event, Map<String, Object?> fields)? onEvent,
  }) {
    void record(String event, Map<String, Object?> fields) {
      _journal(event, fields);
      onEvent?.call(event, fields);
    }

    final budget = RequestBudget(
      ledger: FileRequestLedger(intelligenceStorageDirectory),
    );
    return SealedLetterService(
      identity: identity,
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
        transport: MeteredRelayTransport(
          budget: budget,
          onRequest: (open, {required write, required cut}) {
            // A request that was cut, or took most of its limit, is worth
            // a line; the rest are only counted.
            if (!cut && open < const Duration(seconds: 1)) return;
            record('slow_request', <String, Object?>{
              'ms': open.inMilliseconds,
              'write': write,
              'cut': cut,
            });
          },
        ),
      ),
      budget: budget,
      onEvent: record,
    );
  }

  static const String fileName = 'sealed_letters.json';
  static const String journalName = 'sealed_events.jsonl';

  /// The journal starts a new file at this size and keeps the one before:
  /// a line every thirty seconds would otherwise grow without end.
  static const int journalMaxBytes = 4 * 1024 * 1024;

  static void _journal(String event, Map<String, Object?> fields) {
    try {
      final file = File('${intelligenceStorageDirectory().path}/$journalName');
      if (file.existsSync() && file.lengthSync() > journalMaxBytes) {
        file.renameSync('${file.path}.1');
      }
      file.writeAsStringSync(
        '${jsonEncode(<String, Object?>{'at': DateTime.now().toUtc().toIso8601String(), 'event': event, ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // The journal is evidence, never a dependency.
    }
  }

  final AppIdentity _identity;
  final PersistentStorage storage;
  final SealedBlobStore blobs;

  /// Where every box goes and where every box is read from.
  final LetterShelf shelf;

  /// This install's daily allowance of relay requests, when the shelf's
  /// transport counts against one. The service does not look once the
  /// share for looking is used up, and says so.
  final RequestBudget? budget;

  /// How long after shelving a letter that still has no receipt it is
  /// shelved again — before the relay's two days run out.
  final Duration shelfRefresh;
  final DateTime Function() _clock;
  final Future<void> Function(Duration wait)? _sleep;
  final SealedBoxCodec _codec;

  /// Raw facts as they happen (`start`, `alive`, `stop`, `warm`, `tx`,
  /// `rx`, `receipt_tx`, `receipt_rx`, `need_tx`, `need_rx`, `rejected`):
  /// public ids, sizes, times, counts and flags only — never a body, never
  /// a key.
  final void Function(String event, Map<String, Object?> fields)? onEvent;

  /// How often the shelves are looked at while the conversation is warm,
  /// and for how long after the last write or opened screen it stays so.
  final Duration warmEvery;
  final Duration warmFor;

  /// After that the interval doubles at every look, up to this.
  final Duration coldEvery;

  /// How often the days a fast look leaves out are looked at.
  final Duration slowEvery;

  /// "The service is on" is a line in the journal at start and one every
  /// [aliveEvery] after it — not an entry in a process list.
  final Duration aliveEvery;

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

  /// What the relay said the last time it was asked.
  final ValueNotifier<SealedRelayState> relay = ValueNotifier<SealedRelayState>(
    SealedRelayState.unknown,
  );

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
  int _generation = 0;

  static final DateTime _never = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  /// The loop never turns faster than this, whatever its schedule says.
  static const Duration _shortest = Duration(milliseconds: 50);

  // The schedule. Heat is the time of the last write, opened screen or
  // arriving letter; the fast look follows it, the slow look its own clock.
  DateTime _touchedAt = _never;
  DateTime _startedAt = _never;
  DateTime _lastFastAt = _never;
  DateTime _nextFastAt = _never;
  DateTime _nextSlowAt = _never;
  Duration _every = Duration.zero;
  int _fastLooks = 0;
  int _slowLooks = 0;
  Completer<void>? _wake;
  Timer? _beat;

  /// The relay could not be reached when a letter was handed to it: the
  /// letters behind it wait until then rather than each finding the same.
  DateTime _holdUntil = _never;

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
        if (value is num) shelf.cursors['$key'] = value.toInt();
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
    'shelf': shelf.cursors,
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
          onShelf: q.everDeposited,
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
  /// and hands it to the relay once. Returns as soon as the letter is
  /// safely queued; where it is from then on is told by [outbox]. Throws
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
    // Something was written: an answer may follow, so look often for a
    // while.
    touch('write');
    unawaited(flush().catchError((Object _) {}));
    return sent;
  }

  /// What the screen is told after the relay was asked. Once the share for
  /// looking is used up nothing that arrives is seen until the next day:
  /// that is said from the request that used it up, whether or not that
  /// request itself was answered.
  SealedRelayState _afterRequest(bool ok) => (budget?.now.looksSpent ?? false)
      ? SealedRelayState.spent
      : ok
      ? SealedRelayState.reachable
      : SealedRelayState.unreachable;

  /// Hands every waiting letter whose pause is over to the relay. A media
  /// letter's pieces go with it; after that the recipient asks for what it
  /// lacks. When the relay cannot be reached the letters behind the first
  /// one wait for its next try instead of each finding the same.
  Future<void> flush() => _serial(() async {
    await _load();
    final now = _clock();
    if (now.isBefore(_holdUntil)) return;
    var changed = false;
    for (final q in _queue) {
      if (q.deliveredAt != null || q.nextAt.isAfter(now)) continue;
      if (budget?.now.spent ?? false) {
        relay.value = SealedRelayState.spent;
        break;
      }
      // Shelved before and due again: its two days are nearly up, so the
      // letter and every piece are shelved afresh.
      if (q.everDeposited) q.piecesPushed = false;
      var ok = await shelf.put(q.to, q.box);
      var pieces = 0;
      if (ok && q.chunks > 0 && !q.piecesPushed) {
        pieces = await _depositPieces(q, null);
        ok = pieces == q.chunks;
        q.piecesPushed = ok;
      }
      relay.value = _afterRequest(ok);
      q.attempts++;
      q.everDeposited = q.everDeposited || ok;
      q.nextAt = now.add(ok ? shelfRefresh : _pause(q.attempts));
      changed = true;
      onEvent?.call('tx', <String, Object?>{
        'via': 'shelf',
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
      if (!ok) {
        _holdUntil = q.nextAt;
        break;
      }
    }
    if (changed) {
      await _save();
      await _publish();
    }
  });

  /// Shelves pieces of [q] for its recipient: [only] those, or all.
  /// Returns how many the relay took; stops at the first it refuses.
  Future<int> _depositPieces(_Queued q, Iterable<int>? only) async {
    var sent = 0;
    for (final i in only ?? Iterable<int>.generate(q.chunks)) {
      if (i < 0 || i >= q.chunks) continue;
      final box = await blobs.get('out.${q.id}.$i');
      if (box == null) continue;
      if (!await shelf.put(q.to, box)) break;
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

  /// Asks the relay what each pinned peer has shelved for this install on
  /// the days [look] covers, and deals with what was there. False when the
  /// relay could not be reached, or today's allowance for looking is used
  /// up.
  Future<bool> look({ShelfLook look = ShelfLook.all}) async {
    await load();
    if (budget?.now.looksSpent ?? false) {
      relay.value = SealedRelayState.spent;
      return false;
    }
    if (look != ShelfLook.slow) {
      _fastLooks++;
      _lastFastAt = _clock();
    }
    if (look != ShelfLook.fast) _slowLooks++;
    final peers = await _identity.pinnedInstalls();
    if (peers.isEmpty) return true;
    final shelved = <Uint8List>[];
    final cursorsBefore = jsonEncode(shelf.cursors);
    var reachable = false;
    for (final peer in peers) {
      final boxes = await shelf.collect(peer, look: look);
      if (boxes == null) continue;
      reachable = true;
      shelved.addAll(boxes);
    }
    relay.value = _afterRequest(reachable);
    if (!reachable) return false;
    await _serial(() async {
      if (shelved.isNotEmpty) await _handleBoxes(shelved);
      await _progress();
      await _flushReceipts();
      if (jsonEncode(shelf.cursors) != cursorsBefore) await _save();
    });
    return true;
  }

  Future<void> _handleBoxes(List<Uint8List> boxes) async {
    final own = await _own();
    var changed = false;
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
              touch('letter');
            }
            continue;
          }
          if (!seen) {
            _kept.add(_Kept(id: opened.letterId, box: box, at: _clock()));
            changed = true;
            _rx(opened, content, own, box.length);
          }
          // A receipt that was shelved is there to be read, so a second
          // copy of a letter is answered only if its receipt never got
          // onto the shelf.
          final kept = _kept.firstWhere((k) => k.id == opened.letterId);
          if (!kept.receiptOk) {
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
            touch('letter');
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
          // "I am reading now", from an install built before that was
          // removed. Nothing is told to contacts any more, and nothing
          // follows from being told.
          break;
      }
    }
    if (changed) {
      await _save();
      await _publish();
    }
  }

  void _rx(OpenedBox opened, SealedContent content, String own, int boxBytes) {
    // A letter just opened: an answer may be written, so look often for a
    // while.
    touch('letter');
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
    final ok = await shelf.put(opened.senderInstall, receipt);
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
      // Out of reach still: the ones behind it would only find the same.
      if (!kept.receiptOk) break;
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
      final ok = await shelf.put(
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

  /// Makes every letter that never reached the relay due at once. Called
  /// when the service starts: the path may be up now. What is already on
  /// the shelf is there to be read and is left alone, and nobody is told
  /// that this install has come on.
  Future<void> retryWaiting() => _serial(() async {
    await _load();
    final now = _clock();
    for (final q in _queue) {
      if (q.deliveredAt == null && !q.everDeposited) q.nextAt = now;
    }
    _holdUntil = _never;
  });

  bool _warmAt(DateTime at) => at.difference(_touchedAt) < warmFor;

  /// Something was written, the letters screen was opened, or a letter
  /// arrived: the shelves are looked at every [warmEvery] for the next
  /// [warmFor].
  void touch([String why = 'screen']) {
    if (_disposed) return;
    final now = _clock();
    final wasWarm = _warmAt(now);
    _touchedAt = now;
    if (!_running) return;
    if (!wasWarm) onEvent?.call('warm', <String, Object?>{'why': why});
    // On the warm beat from here: the next look comes one beat after the
    // last one, or now if that has already passed.
    final beat = _lastFastAt.add(warmEvery);
    final soonest = beat.isAfter(now) ? beat : now;
    if (_nextFastAt.isAfter(soonest)) _nextFastAt = soonest;
    _wakeLoop();
  }

  /// Plans the fast look after one that began at [from]: on the warm beat
  /// while the conversation is warm, at twice the last interval after that.
  void _scheduleFast(DateTime from) {
    if (_warmAt(from)) {
      _every = warmEvery;
    } else {
      final doubled = (_every < warmEvery ? warmEvery : _every) * 2;
      _every = doubled > coldEvery ? coldEvery : doubled;
    }
    _nextFastAt = from.add(_every);
  }

  /// When the next waiting letter is handed to the relay again; null when
  /// none waits.
  DateTime? _nextDue() {
    DateTime? next;
    for (final q in _queue) {
      if (q.deliveredAt != null) continue;
      if (next == null || q.nextAt.isBefore(next)) next = q.nextAt;
    }
    if (next == null) return null;
    if (budget?.now.spent ?? false) return budget!.nextDay;
    return next.isBefore(_holdUntil) ? _holdUntil : next;
  }

  void _wakeLoop() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Waits for whatever is due next — a fast look, a slow look, a letter's
  /// next try — or until [touch] or [stop] ends the wait.
  Future<void> _idle() async {
    final now = _clock();
    var next = (budget?.now.looksSpent ?? false)
        ? budget!.nextDay
        : (_nextSlowAt.isBefore(_nextFastAt) ? _nextSlowAt : _nextFastAt);
    final due = _nextDue();
    if (due != null && due.isBefore(next)) next = due;
    var wait = next.difference(now);
    if (wait < _shortest) wait = _shortest;
    final wake = _wake = Completer<void>();
    final sleep = _sleep;
    if (sleep != null) {
      await Future.any<void>(<Future<void>>[sleep(wait), wake.future]);
    } else {
      final timer = Timer(wait, () {
        if (!wake.isCompleted) wake.complete();
      });
      await wake.future;
      timer.cancel();
    }
    if (identical(_wake, wake)) _wake = null;
  }

  int get _waiting =>
      _queue.where((q) => q.deliveredAt == null && !q.everDeposited).length;
  int get _shelved =>
      _queue.where((q) => q.deliveredAt == null && q.everDeposited).length;

  Map<String, Object?> _vitals() {
    final count = budget?.now;
    final now = _clock();
    return <String, Object?>{
      'pid': pid,
      'up_s': now.difference(_startedAt).inSeconds,
      'req_start': count?.sinceStart,
      'req_day': count?.usedToday,
      'cap': count?.dailyCap,
      'refused_day': count?.refusedToday,
      'longest_ms': count?.longestOpen.inMilliseconds,
      'open_now': count?.openNow,
      'looks_fast': _fastLooks,
      'looks_slow': _slowLooks,
      'every_s': _every.inSeconds,
      'warm': _warmAt(now),
      'waiting': _waiting,
      'shelved': _shelved,
      'relay': relay.value.name,
    };
  }

  /// Looks at the shelves on the schedule and re-sends what still waits,
  /// until [stop]. While it runs, the journal has a `start` line and an
  /// `alive` line every [aliveEvery]: that, and nothing else, is what "the
  /// service is on" means.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    final generation = ++_generation;
    final now = _clock();
    _startedAt = now;
    // The app was just opened: that is a screen being opened.
    _touchedAt = now;
    _every = warmEvery;
    _beat = Timer.periodic(
      aliveEvery,
      (_) => onEvent?.call('alive', _vitals()),
    );
    _loop = _run(generation);
  }

  Future<void> _run(int generation) async {
    bool on() => _running && !_disposed && generation == _generation;
    var first = true;
    while (on()) {
      try {
        final now = _clock();
        if (first) {
          first = false;
          await load();
          onEvent?.call('start', <String, Object?>{
            ..._vitals(),
            'peers': (await _identity.pinnedInstalls()).length,
            'look_cap': budget?.lookCap,
            'warm_every_s': warmEvery.inSeconds,
            'warm_for_s': warmFor.inSeconds,
            'cold_every_s': coldEvery.inSeconds,
            'slow_every_s': slowEvery.inSeconds,
            'alive_every_s': aliveEvery.inSeconds,
          });
          await retryWaiting();
          await look();
          _nextSlowAt = now.add(slowEvery);
          _scheduleFast(now);
        } else {
          if (!now.isBefore(_nextSlowAt)) {
            await look(look: ShelfLook.slow);
            // From the planned time, so the half hours do not drift.
            final next = _nextSlowAt.add(slowEvery);
            _nextSlowAt = next.isAfter(now) ? next : now.add(slowEvery);
          }
          if (!now.isBefore(_nextFastAt)) {
            await look(look: ShelfLook.fast);
            _scheduleFast(now);
          }
        }
        // After the look: a receipt already on the shelf is read before
        // its letter would be shelved again.
        await flush();
      } catch (_) {
        // The loop outlives any one bad round.
      }
      if (!on()) break;
      await _idle();
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _beat?.cancel();
    _beat = null;
    _wakeLoop();
    onEvent?.call('stop', _vitals());
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    _wakeLoop();
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

  /// Whether the relay ever took it, pieces and all.
  bool everDeposited;

  /// Whether every piece has been shelved since the letter was last due.
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
