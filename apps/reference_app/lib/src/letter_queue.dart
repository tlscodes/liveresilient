// The letter's parking place when the door is down: a local, durable
// queue the courier drains — one letter, one deliver — the first time the
// door ranks usable again. The fabric's own DTN queue is in memory and
// dies with the process; this one is written through a store the app
// chooses, so a letter parked before a restart is still waiting after it.
//
// Exactly-once, the way it is kept here: an id is marked in flight before
// its one deliver and removed from the store the moment the fabric says
// sentLive — the store never holds a sent letter, so a restart can only
// re-offer a letter whose verdict never came back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:security/security.dart' show KeyMaterialStore;

/// One letter waiting behind the door.
@immutable
class QueuedLetter {
  const QueuedLetter({
    required this.id,
    required this.bytes,
    required this.kind,
    required this.queuedAt,
    this.duration,
  });

  /// The bundle id the fabric sees, unique per letter.
  final String id;
  final Uint8List bytes;

  /// `typed`, `voice` or `photo`: the composer's own names.
  final String kind;
  final DateTime queuedAt;

  /// The encoded length of a voice take, when the composer knew it.
  final Duration? duration;

  Map<String, Object?> toJson() => {
    'id': id,
    'bytes': base64Encode(bytes),
    'kind': kind,
    'queuedAt': queuedAt.toIso8601String(),
    if (duration != null) 'durationMs': duration!.inMilliseconds,
  };

  static QueuedLetter fromJson(Map<String, Object?> json) {
    final durationMs = json['durationMs'];
    return QueuedLetter(
      id: json['id']! as String,
      bytes: base64Decode(json['bytes']! as String),
      kind: json['kind']! as String,
      queuedAt: DateTime.parse(json['queuedAt']! as String),
      duration: durationMs is int ? Duration(milliseconds: durationMs) : null,
    );
  }
}

/// Where the queue lives between runs. [save] receives the whole waiting
/// list every time it changes; [load] returns what the last save left.
abstract class LetterQueueStore {
  Future<List<QueuedLetter>> load();
  Future<void> save(List<QueuedLetter> letters);
}

/// A store that forgets on restart: the courier's default when no store
/// is handed in, and every test's.
class MemoryLetterQueueStore implements LetterQueueStore {
  MemoryLetterQueueStore([List<QueuedLetter> initial = const []])
    : _letters = List<QueuedLetter>.of(initial);

  List<QueuedLetter> _letters;

  /// How many times [save] ran — the courier tests read it.
  int saves = 0;

  /// What the last save left, as a restart would read it.
  List<QueuedLetter> get contents => List<QueuedLetter>.unmodifiable(_letters);

  @override
  Future<List<QueuedLetter>> load() async => List<QueuedLetter>.of(_letters);

  @override
  Future<void> save(List<QueuedLetter> letters) async {
    saves++;
    _letters = List<QueuedLetter>.of(letters);
  }
}

/// One JSON file under [directory]: the whole waiting list, written to a
/// sibling and renamed over the old file so a crash mid-write leaves the
/// previous list, never half of the new one.
class FileLetterQueueStore implements LetterQueueStore {
  FileLetterQueueStore(Directory directory)
    : _file = File('${directory.path}${Platform.pathSeparator}$fileName');

  static const String fileName = 'letter_queue.json';

  final File _file;

  @override
  Future<List<QueuedLetter>> load() async {
    if (!_file.existsSync()) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(await _file.readAsString());
    } on FormatException {
      // A torn or foreign file holds no letter worth guessing at.
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map<String, Object?>) QueuedLetter.fromJson(entry),
    ];
  }

  @override
  Future<void> save(List<QueuedLetter> letters) async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final letter in letters) letter.toJson()]),
      flush: true,
    );
    await tmp.rename(_file.path);
  }
}

/// The same waiting list, sealed at rest: AES-256-GCM over the JSON, the
/// key held only in the device keystore under [keyHandle] (Keychain on
/// iOS/macOS, Keystore on Android). The file on disk is magic + nonce +
/// ciphertext + tag — no letter text, no JSON. Without the key nothing is
/// read: a sealed file whose key is gone loads as an empty queue.
///
/// A plain [FileLetterQueueStore] file left by an older build is moved in
/// once — loaded, sealed, then deleted — so no raw JSON stays behind. When
/// the keystore itself fails (an unsigned desktop host), the list is kept
/// in memory for this process only and never written in the clear.
class SealedFileLetterQueueStore implements LetterQueueStore {
  SealedFileLetterQueueStore(this._directory, this._keys)
    : _file = File('${_directory.path}${Platform.pathSeparator}$fileName');

  static const String fileName = 'letter_queue.sealed';
  static const String keyHandle = 'letter-queue.v1';
  static final List<int> _magic = utf8.encode('VLQ1');
  static final AesGcm _cipher = AesGcm.with256bits();

  final Directory _directory;
  final KeyMaterialStore _keys;
  final File _file;

  /// Set once the keystore has failed: from then on, memory only.
  List<QueuedLetter>? _volatile;

  Future<SecretKey?> _key({required bool create}) async {
    final existing = await _keys.read(keyHandle);
    if (existing != null) return SecretKey(existing);
    if (!create) return null;
    final rng = Random.secure();
    final fresh = Uint8List.fromList([
      for (var i = 0; i < 32; i++) rng.nextInt(256),
    ]);
    await _keys.write(keyHandle, fresh);
    return SecretKey(fresh);
  }

  @override
  Future<List<QueuedLetter>> load() async {
    final volatile = _volatile;
    if (volatile != null) return List<QueuedLetter>.of(volatile);
    final legacy = File(
      '${_directory.path}${Platform.pathSeparator}'
      '${FileLetterQueueStore.fileName}',
    );
    if (legacy.existsSync()) {
      final moved = await FileLetterQueueStore(_directory).load();
      await save(moved);
      if (_volatile == null) await legacy.delete();
      return moved;
    }
    if (!_file.existsSync()) return const [];
    final SecretKey? key;
    try {
      key = await _key(create: false);
    } on Object {
      _volatile = <QueuedLetter>[];
      return const [];
    }
    if (key == null) return const [];
    final raw = await _file.readAsBytes();
    const nonceLength = 12;
    final head = _magic.length + nonceLength;
    if (raw.length < head + 16 ||
        !listEquals(raw.sublist(0, _magic.length), _magic)) {
      return const [];
    }
    final List<int> clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(
          raw.sublist(head, raw.length - 16),
          nonce: raw.sublist(_magic.length, head),
          mac: Mac(raw.sublist(raw.length - 16)),
        ),
        secretKey: key,
        aad: _magic,
      );
    } on SecretBoxAuthenticationError {
      // Another key, or a torn file: nothing in it is ours to read.
      return const [];
    }
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map<String, Object?>) QueuedLetter.fromJson(entry),
    ];
  }

  @override
  Future<void> save(List<QueuedLetter> letters) async {
    if (_volatile != null) {
      _volatile = List<QueuedLetter>.of(letters);
      return;
    }
    final SecretKey key;
    try {
      key = (await _key(create: true))!;
    } on Object {
      _volatile = List<QueuedLetter>.of(letters);
      return;
    }
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode([for (final l in letters) l.toJson()])),
      secretKey: key,
      aad: _magic,
    );
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes([
      ..._magic,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ], flush: true);
    await tmp.rename(_file.path);
  }
}

/// The waiting list and its in-flight marks. Every waiting letter is also
/// in the store; the in-flight set is this process's alone, so a letter
/// whose deliver is running is never taken twice here and never lost on
/// a restart before its verdict.
class LetterQueue {
  LetterQueue(this.store, {this.maxLetters = defaultMaxLetters})
    : assert(maxLetters > 0);

  /// How many letters may wait at once. Every letter is already under the
  /// door's payload cap when it gets here, so this alone bounds the store
  /// and its file: a person behind a down door can park a handful, not a
  /// day's worth.
  static const int defaultMaxLetters = 12;

  final LetterQueueStore store;
  final int maxLetters;

  /// Every letter waiting or in flight, oldest first.
  final ValueNotifier<List<QueuedLetter>> pending =
      ValueNotifier<List<QueuedLetter>>(const []);

  final Set<String> _inFlight = <String>{};
  Future<void>? _loaded;

  int get length => pending.value.length;
  bool get isEmpty => pending.value.isEmpty;

  /// Letters waiting for a deliver — not the one in flight.
  int get waiting => pending.value.length - _inFlight.length;

  /// Reads the store once; every mutation waits for it, so a letter
  /// enqueued before the load finished can never overwrite the stored list.
  Future<void> ensureLoaded() => _loaded ??= () async {
    final stored = await store.load();
    pending.value = List<QueuedLetter>.unmodifiable(stored);
  }();

  /// True when [maxLetters] are already parked: the next one is refused,
  /// never an older one dropped — a parked letter is a promise.
  bool get isFull => pending.value.length >= maxLetters;

  /// Parks [letter]. Returns true when it waits now (or already did — a
  /// second offer of the same id is ignored), false when the queue is full
  /// and the letter was refused.
  Future<bool> enqueue(QueuedLetter letter) async {
    await ensureLoaded();
    if (pending.value.any((l) => l.id == letter.id)) return true;
    if (isFull) return false;
    pending.value = List<QueuedLetter>.unmodifiable([...pending.value, letter]);
    await store.save(pending.value);
    return true;
  }

  /// The oldest letter not in flight, marked in flight — null when none.
  QueuedLetter? take() {
    for (final letter in pending.value) {
      if (_inFlight.add(letter.id)) return letter;
    }
    return null;
  }

  /// A deliver ended without a verdict that settles it (parked again,
  /// timed out): the letter waits for the next door-up.
  void release(String id) => _inFlight.remove(id);

  /// Sent or refused: the letter leaves the queue and the store.
  Future<void> remove(String id) async {
    await ensureLoaded();
    _inFlight.remove(id);
    if (!pending.value.any((l) => l.id == id)) return;
    pending.value = List<QueuedLetter>.unmodifiable([
      for (final letter in pending.value)
        if (letter.id != id) letter,
    ]);
    await store.save(pending.value);
  }

  void dispose() => pending.dispose();
}
