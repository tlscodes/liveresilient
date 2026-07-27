/// A signed list of relays, small enough to arrive by any means at all.
///
/// This is the answer to the hardest question in the design: how a device
/// that is already cut off learns where to read. The list is signed, so
/// the channel it arrives on needs to be neither confidential nor
/// authenticated nor even two-way. That makes every one-way public channel
/// usable — a photographed QR code, a printed page, a file handed over on
/// a memory card, bytes read aloud.
///
/// It is signed by the author's own root key rather than by a separate
/// authority. An author knows where they publish, and a reader already
/// holds that key in order to read anything, so this adds no new trust
/// anchor and nothing new to distribute.
///
/// Two things bound the damage a stolen key can do here. A directory
/// expires, so a captured one stops working on its own. And it carries a
/// sequence number that a reader refuses to go backwards on, so an old
/// list naming a relay the author has since abandoned cannot be replayed
/// over a newer one.
library;

import 'dart:typed_data';

import 'broadcast_keys.dart';
import 'wire.dart';

final Uint8List _directoryDomain = Uint8List.fromList(
  'vck/broadcast/relay-directory/v1\n'.codeUnits,
);

/// The only directory version this build understands.
const int directoryVersion = 1;

/// Most relays one directory may name.
///
/// Small on purpose. The list has to fit a channel a human can carry, and
/// beyond a handful of relays the marginal one adds far less than the
/// bytes it costs.
const int maxDirectoryRelays = 8;

/// Longest origin string accepted, in bytes.
const int maxOriginLength = 64;

/// Longest validity a reader will accept for a directory.
const Duration maxDirectoryValidity = Duration(days: 365);

/// Why a directory was refused.
enum DirectoryRejection {
  malformed,
  unsupportedVersion,
  noRelays,
  tooManyRelays,
  badOrigin,
  duplicateOrigin,
  expired,
  validityTooLong,
  rolledBack,
  badSignature,
}

/// A verified list of relay origins.
class RelayDirectory {
  const RelayDirectory._({
    required this.seq,
    required this.notAfter,
    required this.origins,
    required this.encoded,
  });

  /// Monotonic version of this list for its author.
  final int seq;

  /// When readers stop accepting it.
  final DateTime notAfter;

  /// Relay origins, most preferred first.
  final List<Uri> origins;

  /// The exact bytes this was parsed from, or produced as.
  final Uint8List encoded;

  /// Encoded size of a directory naming [origins].
  ///
  /// Worth having as a function: the reason this format is fixed-width and
  /// terse is that the whole list has to fit a channel a human can carry,
  /// and that is a claim only arithmetic can keep honest.
  static int sizeFor(Iterable<String> origins) =>
      1 + 1 + 4 + 5 + origins.fold<int>(0, (sum, o) => sum + 1 + o.length) + 64;

  /// Sign a directory with the author's root key.
  static Future<RelayDirectory> issue({
    required BroadcastSigner rootSigner,
    required List<Uri> origins,
    required int seq,
    required DateTime notAfter,
  }) async {
    if (origins.isEmpty) {
      throw ArgumentError.value(origins, 'origins', 'name at least one relay');
    }
    if (origins.length > maxDirectoryRelays) {
      throw ArgumentError.value(
        origins.length,
        'origins.length',
        'at most $maxDirectoryRelays',
      );
    }
    final texts = <String>[];
    for (final origin in origins) {
      final text = _canonical(origin);
      if (text == null) {
        throw ArgumentError.value(origin, 'origins', 'not an http(s) origin');
      }
      if (text.length > maxOriginLength) {
        throw ArgumentError.value(
          origin,
          'origins',
          'longer than $maxOriginLength bytes',
        );
      }
      if (texts.contains(text)) {
        throw ArgumentError.value(origin, 'origins', 'named twice');
      }
      texts.add(text);
    }

    final body = _body(seq: seq, notAfter: notAfter, origins: texts);
    final signature = await rootSigner.sign(_signingInput(body));
    final out = WireWriter()
      ..bytes(body)
      ..bytes(signature);
    return RelayDirectory._(
      seq: seq,
      notAfter: notAfter.toUtc(),
      origins: List.unmodifiable([for (final t in texts) Uri.parse(t)]),
      encoded: out.take(),
    );
  }

  /// Parse and verify [encoded] against [rootPublicKey].
  ///
  /// [knownSeq] is the highest sequence number this reader has already
  /// accepted; anything at or below it is refused as a rollback. Pass null
  /// when adopting a first directory.
  static Future<RelayDirectory?> verify({
    required Uint8List encoded,
    required Uint8List rootPublicKey,
    required BroadcastVerifier verifier,
    required DateTime now,
    int? knownSeq,
    void Function(DirectoryRejection reason)? onReject,
  }) async {
    void reject(DirectoryRejection reason) => onReject?.call(reason);

    final reader = WireReader(encoded);
    final int seq;
    final int notAfterSeconds;
    final List<String> texts;
    try {
      if (reader.u8() != directoryVersion) {
        reject(DirectoryRejection.unsupportedVersion);
        return null;
      }
      final count = reader.u8();
      if (count == 0) {
        reject(DirectoryRejection.noRelays);
        return null;
      }
      if (count > maxDirectoryRelays) {
        reject(DirectoryRejection.tooManyRelays);
        return null;
      }
      seq = reader.u32();
      notAfterSeconds = reader.u40();
      texts = <String>[];
      for (var i = 0; i < count; i++) {
        final length = reader.u8();
        if (length == 0 || length > maxOriginLength) {
          reject(DirectoryRejection.badOrigin);
          return null;
        }
        texts.add(String.fromCharCodes(reader.bytes(length)));
      }
      if (reader.remaining != 64) {
        reject(DirectoryRejection.malformed);
        return null;
      }
    } on FormatException {
      reject(DirectoryRejection.malformed);
      return null;
    }

    final origins = <Uri>[];
    for (final text in texts) {
      final parsed = Uri.tryParse(text);
      if (parsed == null || _canonical(parsed) != text) {
        reject(DirectoryRejection.badOrigin);
        return null;
      }
      if (origins.any((held) => held.toString() == text)) {
        reject(DirectoryRejection.duplicateOrigin);
        return null;
      }
      origins.add(parsed);
    }

    final notAfter = DateTime.fromMillisecondsSinceEpoch(
      notAfterSeconds * 1000,
      isUtc: true,
    );
    if (now.isAfter(notAfter)) {
      reject(DirectoryRejection.expired);
      return null;
    }
    if (notAfter.difference(now) > maxDirectoryValidity) {
      reject(DirectoryRejection.validityTooLong);
      return null;
    }
    if (knownSeq != null && seq <= knownSeq) {
      reject(DirectoryRejection.rolledBack);
      return null;
    }

    final body = Uint8List.fromList(
      Uint8List.sublistView(encoded, 0, encoded.length - 64),
    );
    final ok = await verifier.verify(
      message: _signingInput(body),
      signature: Uint8List.sublistView(encoded, encoded.length - 64),
      publicKey: rootPublicKey,
    );
    if (!ok) {
      reject(DirectoryRejection.badSignature);
      return null;
    }

    return RelayDirectory._(
      seq: seq,
      notAfter: notAfter,
      origins: List.unmodifiable(origins),
      encoded: Uint8List.fromList(encoded),
    );
  }

  /// The canonical text for an origin: scheme, host, and a port only when
  /// it is not the default.
  ///
  /// One spelling per relay, so a directory cannot name the same relay
  /// twice in ways that look different, and so the bytes a reader verifies
  /// are the bytes it acts on.
  static String? _canonical(Uri origin) {
    if (!origin.isScheme('https') && !origin.isScheme('http')) return null;
    if (origin.host.isEmpty) return null;
    if (origin.userInfo.isNotEmpty) return null;
    final defaultPort = origin.isScheme('https') ? 443 : 80;
    final port = origin.hasPort && origin.port != defaultPort
        ? ':${origin.port}'
        : '';
    return '${origin.scheme}://${origin.host}$port';
  }

  static Uint8List _body({
    required int seq,
    required DateTime notAfter,
    required List<String> origins,
  }) {
    final seconds = notAfter.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (seconds < 0 || seconds > 0xFFFFFFFFFF) {
      throw ArgumentError.value(
        notAfter,
        'notAfter',
        'not representable in five bytes',
      );
    }
    final out = WireWriter()
      ..u8(directoryVersion)
      ..u8(origins.length)
      ..u32(seq)
      ..u40(seconds);
    for (final origin in origins) {
      final bytes = Uint8List.fromList(origin.codeUnits);
      out
        ..u8(bytes.length)
        ..bytes(bytes);
    }
    return out.take();
  }

  static Uint8List _signingInput(Uint8List body) {
    final out = WireWriter()
      ..bytes(_directoryDomain)
      ..bytes(body);
    return out.take();
  }
}

/// Holds the newest directory a reader has accepted.
///
/// Keeping the sequence number is the point: without it, an attacker who
/// captured any older signed list could replay it forever and pin a reader
/// to relays the author has abandoned.
class RelayDirectoryStore {
  RelayDirectoryStore({RelayDirectory? initial}) : _current = initial;

  RelayDirectory? _current;

  RelayDirectory? get current => _current;

  int? get knownSeq => _current?.seq;

  /// Verify [encoded] and keep it if it is newer than what is held.
  Future<bool> adopt({
    required Uint8List encoded,
    required Uint8List rootPublicKey,
    required BroadcastVerifier verifier,
    required DateTime now,
    void Function(DirectoryRejection reason)? onReject,
  }) async {
    final directory = await RelayDirectory.verify(
      encoded: encoded,
      rootPublicKey: rootPublicKey,
      verifier: verifier,
      now: now,
      knownSeq: knownSeq,
      onReject: onReject,
    );
    if (directory == null) return false;
    _current = directory;
    return true;
  }

  /// Origins to use now: the held directory's, or [fallback] when there is
  /// none or it has expired.
  ///
  /// A reader whose directory expired is not stranded — it keeps whatever
  /// was compiled in. Losing reach is acceptable; losing the ability to
  /// read at all is not.
  List<Uri> originsAt(DateTime now, {required List<Uri> fallback}) {
    final held = _current;
    if (held == null || now.isAfter(held.notAfter)) return fallback;
    return held.origins;
  }
}
