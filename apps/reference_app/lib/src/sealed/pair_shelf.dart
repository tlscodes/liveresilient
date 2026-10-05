// The pair shelf: where a sealed box waits for someone who is not there.
//
// The mailbox (mailbox_door.dart) hands a box over only while its recipient
// is reading — the relay keeps a frame for seconds. The same relay also has
// an archive: `/o/<hash>` stores an object under its own SHA-256 and
// `/a/<author>/<seq>` stores one small signed pointer per sequence number,
// both write-once and kept about two days. A shelf is one such author feed
// used by exactly two installs:
//
//   * the author's key is derived from the secret the two installs already
//     share — X25519 between their pinned identity keys — together with the
//     direction and the day. Both can derive it; nobody else can even
//     compute the address, so nobody else can find the shelf, and since the
//     archive is write-once nobody can take anything off it;
//   * the sender puts each sealed box at `/o/<sha256>` and a pointer to it
//     at the next sequence number; the recipient reads forward from the
//     last number it saw.
//
// The relay sees a pseudonymous author that changes every day, and sealed
// boxes. It cannot tell who writes to whom.
//
// Either of the two could write to a shelf (both hold its key). That is
// fine: what is ON the shelf is a sealed box signed by its real sender, and
// a box is only ever accepted on the strength of that signature.
import 'dart:convert';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:cryptography/cryptography.dart';
import 'package:security/security.dart';

import '../peer_identity.dart' show AppIdentity;

/// Where boxes wait.
abstract class LetterShelf {
  /// Puts [box] on this install's shelf for [peerInstall]. False when the
  /// relay could not be reached or refused it.
  Future<bool> put(String peerInstall, Uint8List box);

  /// Everything [peerInstall] has put on its shelf for this install since
  /// the last call. Null when the relay could not be reached (nothing is
  /// skipped: the next call starts from the same place).
  Future<List<Uint8List>?> collect(String peerInstall);

  /// How far each shelf has been written and read. The owner persists it
  /// and gives it back after a relaunch.
  Map<String, int> get cursors;
}

/// [LetterShelf] on the relay's archive routes.
class PairShelf implements LetterShelf {
  PairShelf({
    required this.identity,
    required this.origin,
    required this.transport,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppIdentity identity;

  /// `https://<relay host>`.
  final Uri origin;
  final BroadcastHttpTransport transport;
  final DateTime Function() _clock;

  @override
  final Map<String, int> cursors = <String, int>{};

  final Map<String, _Feed> _feeds = <String, _Feed>{};
  final Ed25519 _ed25519 = Ed25519();

  /// First byte of a shelf pointer. Not a broadcast descriptor version, so
  /// a broadcast reader that ever met one would refuse it.
  static const int pointerMarker = 0xB0;
  static const int pointerBytes = 2 + 16 + 32 + 64;

  /// How many days back a shelf is read: the archive keeps about two.
  static const int daysBack = 2;

  /// The most pointers read from one day's shelf in one call.
  static const int maxPerCollect = 256;

  static final List<int> _seedDomain = utf8.encode('vck-pair-shelf-v1\n');
  static final List<int> _pointerDomain = utf8.encode(
    'vck/broadcast/descriptor/v1\n',
  );

  int _day(DateTime at) =>
      at.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// The feed [sender] writes for [recipient] on [day]: its signing key,
  /// its address and the credential that authorises a write to it.
  Future<_Feed?> _feed(String sender, String recipient, int day) async {
    final cacheKey = '$sender>$recipient@$day';
    final cached = _feeds[cacheKey];
    if (cached != null) return cached;
    final own = _hex(await identity.installId());
    final peer = sender == own ? recipient : sender;
    final peerKey = await identity.store.pinnedKeyFor(peer);
    if (peerKey == null) return null;
    final pair = await identity.store.agreeWithLocalIdentity(
      ed25519PublicKeyToX25519(peerKey),
    );
    final seed = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(pair),
      nonce: const <int>[],
      info: [
        ..._seedDomain,
        ..._unhex(sender),
        ..._unhex(recipient),
        ...(ByteData(4)..setUint32(0, day)).buffer.asUint8List(),
      ],
    );
    final signer = await CryptographyBroadcastSigner.fromSeed(
      Uint8List.fromList(await seed.extractBytes()),
    );
    final start = DateTime.fromMillisecondsSinceEpoch(
      day * Duration.millisecondsPerDay,
      isUtc: true,
    );
    final certificate = await PublishingKeyCertificate.issue(
      rootSigner: signer,
      publishingKey: signer.publicKey,
      notBefore: start.subtract(const Duration(days: 1)),
      notAfter: start.add(const Duration(days: 4)),
    );
    final feed = _Feed(
      key: cacheKey,
      signer: signer,
      author: authorIdFor(signer.publicKey),
      credentials: BroadcastCredentials.of(signer.publicKey, certificate),
    );
    if (_feeds.length > 64) _feeds.clear();
    return _feeds[cacheKey] = feed;
  }

  Uri _object(String hash) => origin.replace(path: '/o/$hash');
  Uri _pointer(_Feed feed, int seq) =>
      origin.replace(path: '/a/${_hex(feed.author)}/$seq');

  @override
  Future<bool> put(String peerInstall, Uint8List box) async {
    try {
      final own = _hex(await identity.installId());
      final feed = await _feed(own, peerInstall, _day(_clock()));
      if (feed == null) return false;
      final hash = Uint8List.fromList((await Sha256().hash(box)).bytes);
      final stored = await transport.put(_object(_hex(hash)), box);
      if (stored.statusCode != 201 && stored.statusCode != 204) return false;

      final body = Uint8List(2 + 16 + 32)
        ..[0] = pointerMarker
        ..[1] = 1
        ..setAll(2, feed.author)
        ..setAll(18, hash);
      final signature = await feed.signer.sign(
        Uint8List.fromList([..._pointerDomain, ...body]),
      );
      final pointer = Uint8List.fromList([...body, ...signature]);
      // The next free number. A number already holding something else
      // (this file was lost and the count with it) is stepped over.
      var seq = cursors['out:${feed.key}'] ?? 0;
      for (var tries = 0; tries < 64; tries++, seq++) {
        final placed = await transport.put(
          _pointer(feed, seq),
          pointer,
          headers: feed.credentials.headers,
        );
        if (placed.statusCode == 201 || placed.statusCode == 204) {
          cursors['out:${feed.key}'] = seq + 1;
          return true;
        }
        if (placed.statusCode != 409) return false;
      }
      cursors['out:${feed.key}'] = seq;
      return false;
    } catch (_) {
      // The relay could not be reached.
      return false;
    }
  }

  @override
  Future<List<Uint8List>?> collect(String peerInstall) async {
    try {
      final own = _hex(await identity.installId());
      final today = _day(_clock());
      final boxes = <Uint8List>[];
      for (var day = today - daysBack; day <= today + 1; day++) {
        final feed = await _feed(peerInstall, own, day);
        if (feed == null) return const <Uint8List>[];
        var seq = cursors['in:${feed.key}'] ?? 0;
        for (var read = 0; read < maxPerCollect; read++) {
          final pointer = await transport.get(_pointer(feed, seq));
          if (pointer.statusCode == 404) break;
          if (pointer.statusCode != 200) return null;
          seq++;
          final hash = await _checked(feed, pointer.body);
          if (hash != null) {
            final object = await transport.get(_object(_hex(hash)));
            if (object.statusCode != 200 && object.statusCode != 404) {
              return null;
            }
            final box = object.body;
            // A pointer whose object is gone, or is not what it names, is
            // stepped over: nothing behind it must wait for it.
            if (box != null && _same((await Sha256().hash(box)).bytes, hash)) {
              boxes.add(box);
            }
          }
          cursors['in:${feed.key}'] = seq;
        }
      }
      return boxes;
    } catch (_) {
      return null;
    }
  }

  /// The object hash a pointer names, if the pointer is this feed's own.
  Future<Uint8List?> _checked(_Feed feed, Uint8List? pointer) async {
    if (pointer == null ||
        pointer.length != pointerBytes ||
        pointer[0] != pointerMarker ||
        pointer[1] != 1 ||
        !_same(pointer.sublist(2, 18), feed.author)) {
      return null;
    }
    final ok = await _ed25519.verify(
      [..._pointerDomain, ...pointer.sublist(0, 50)],
      signature: Signature(
        pointer.sublist(50),
        publicKey: SimplePublicKey(
          feed.signer.publicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    return ok ? Uint8List.fromList(pointer.sublist(18, 50)) : null;
  }
}

class _Feed {
  _Feed({
    required this.key,
    required this.signer,
    required this.author,
    required this.credentials,
  });

  final String key;
  final BroadcastSigner signer;
  final Uint8List author;
  final BroadcastCredentials credentials;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String text) => Uint8List.fromList([
  for (var i = 0; i + 1 < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);
