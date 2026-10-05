// Automatic identity pinning — the app's rule, for every install, with no
// switch and nothing for the person to do.
//
// Each install makes its own Ed25519 identity key once (the seed stays in
// the device keystore) and one random install id (public). In the first
// call that actually connects, both sides send `install id + public key +
// a signature proving they hold the key` over that call's own chat data
// channel, and each pins the other's key to the other's install id. A later
// call presenting a DIFFERENT key under an install id already pinned is
// never accepted silently: the reading becomes [PeerTrust.changed] and the
// caller is told.
//
// What this does and does not prove. It is trust on first use. The data
// channel runs under DTLS, so a network observer cannot read or swap the
// keys; a signalling server that inserts itself into the very first call
// can, and would be pinned in the peer's place. That is why first contact
// reads "not yet verified" — only an out-of-band comparison of safety
// numbers earns [PeerTrust.verified]. Letters are not sealed with this; a
// signing key cannot seal, and a letter has no receiving path yet.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:messaging/messaging.dart' show DataChannelPort;
import 'package:security/security.dart';

import 'intelligence/device_bindings.dart'
    show identityStorageDirectory, intelligenceStorageDirectory;
import 'intelligence/disk_json_storage.dart';
import 'letter_queue_keystore.dart';

/// The three readings a person can see for the peer on a live call.
enum PeerTrust {
  /// The peer proved it holds its key and that key is pinned, but nobody
  /// has compared safety numbers.
  unverified('Encrypted — identity not yet verified'),

  /// The pinned key was confirmed out of band.
  verified('Verified'),

  /// The peer presented a different key than the one pinned for it.
  changed('Identity key changed — call stopped');

  const PeerTrust(this.label);
  final String label;
}

/// Pinned peer keys and this install's public id, in one JSON file beside
/// the other intelligence files. Public material only — the private seed
/// never comes here.
class PinnedPeerStore implements SecureKeyValueStore {
  PinnedPeerStore(this._storage);

  factory PinnedPeerStore.disk() {
    adoptIdentityFile(
      from: intelligenceStorageDirectory(),
      to: identityStorageDirectory(),
    );
    return PinnedPeerStore(
      DiskJsonStorage(
        directoryFactory: identityStorageDirectory,
        fileName: fileName,
      ),
    );
  }

  static const String fileName = 'peer_identities.json';

  /// Carries an identity file written before the folder moved into the
  /// folder it is read from now, once: never over a file already there,
  /// and the old one is left where it was. Returns whether it copied.
  static bool adoptIdentityFile({
    required Directory from,
    required Directory to,
  }) {
    try {
      if (from.path == to.path) return false;
      final old = File('${from.path}/$fileName');
      final now = File('${to.path}/$fileName');
      if (now.existsSync() || !old.existsSync()) return false;
      if (!to.existsSync()) to.createSync(recursive: true);
      old.copySync(now.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  final PersistentStorage _storage;

  @override
  Future<String?> read(String key) async {
    final value = (await _storage.load())[key];
    return value is String ? value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    final data = await _storage.load();
    data[key] = value;
    await _storage.save(data);
  }

  @override
  Future<void> delete(String key) async {
    final data = await _storage.load();
    if (data.remove(key) != null) await _storage.save(data);
  }
}

/// This install's identity: its key (through [store]) and its install id.
class AppIdentity {
  AppIdentity({required this.engine, required SecureKeyValueStore pins})
    : store = IdentityStore(engine: engine, store: pins),
      _pins = pins;

  /// The real thing: seed in the device keystore, pins on disk.
  factory AppIdentity.disk() => AppIdentity(
    engine: CryptographyIdentityKeyEngine(keyStore: DeviceKeystore()),
    pins: PinnedPeerStore.disk(),
  );

  static const int installIdBytes = 16;
  static const String _installIdKey = 'install-id';
  static const String _verifiedPrefix = 'verified:';

  final IdentityKeyEngine engine;
  final IdentityStore store;
  final SecureKeyValueStore _pins;

  /// Sixteen random bytes made once per install. Public: it is the handle
  /// a peer pins this install's key under.
  Future<Uint8List> installId() async {
    final stored = await _pins.read(_installIdKey);
    if (stored != null && stored.length == installIdBytes * 2) {
      final parsed = _tryHex(stored);
      if (parsed != null) return parsed;
    }
    final random = Random.secure();
    final fresh = Uint8List.fromList([
      for (var i = 0; i < installIdBytes; i++) random.nextInt(256),
    ]);
    await _pins.write(_installIdKey, _hex(fresh));
    return fresh;
  }

  /// Records that [publicKey] was confirmed out of band for [peerInstall].
  Future<void> markVerified(String peerInstall, Uint8List publicKey) =>
      _pins.write('$_verifiedPrefix$peerInstall', _hex(publicKey));

  /// True only while the confirmed key is the one presented now.
  Future<bool> isVerified(String peerInstall, Uint8List publicKey) async =>
      await _pins.read('$_verifiedPrefix$peerInstall') == _hex(publicKey);

  /// Forgets a confirmation: the person said the numbers differ, or a
  /// second key was proven under [peerInstall]. Only ever a downgrade.
  Future<void> clearVerified(String peerInstall) =>
      _pins.delete('$_verifiedPrefix$peerInstall');
}

/// The process's identity, set once by [bootAppIdentity]; null when the
/// device keystore is unavailable (a widget test, a host with no keychain).
AppIdentity? appIdentity;
String? _bootedKeyId;

/// What the live call's peer reads as; null when no call has exchanged
/// identities yet.
final ValueNotifier<PeerTrust?> peerTrust = ValueNotifier<PeerTrust?>(null);

/// What one judged peer frame established: who this install is, who the
/// peer said it is, what the pin store answered and the reading that
/// followed. Public ids and enum names only — never a key, never a call
/// id. It exists so a rig run can print both sides of the same call.
class PeerSighting {
  const PeerSighting({
    required this.at,
    required this.install,
    required this.peerInstall,
    required this.check,
    required this.trust,
  });

  final DateTime at;
  final String install;
  final String peerInstall;

  /// `pinnedFirstUse` the first time, `match` once the pin is on file.
  final RemoteIdentityCheck check;
  final PeerTrust trust;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'install': install,
    'peer_install': peerInstall,
    'check': check.name,
    'trust': trust.name,
  };
}

/// The most recent [PeerSighting] any handshake in this process made.
final ValueNotifier<PeerSighting?> lastPeerSighting =
    ValueNotifier<PeerSighting?>(null);

/// Makes (first launch) or loads this install's identity. Never throws: a
/// host without a keystore simply has no identity, and calls still work.
Future<void> bootAppIdentity([AppIdentity? identity]) async {
  identityBootError = null;
  try {
    final resolved = identity ?? AppIdentity.disk();
    _bootedKeyId = await resolved.store.localKeyId();
    await resolved.installId();
    appIdentity = resolved;
  } catch (error) {
    appIdentity = null;
    _bootedKeyId = null;
    identityBootError = error;
  }
}

/// Why the last [bootAppIdentity] left no identity; null when it made one
/// or has not finished. The boot never throws, so this is the only place
/// its failure can be read.
Object? identityBootError;

/// The key id this install signs its signalling envelopes with: the booted
/// identity's own, or a one-off random id when there is no identity.
String sessionKeyId() {
  final booted = _bootedKeyId;
  if (booted != null) return booted;
  final random = Random.secure();
  return 'anon-${_hex([for (var i = 0; i < 8; i++) random.nextInt(256)])}';
}

/// The identity exchange of one call, riding that call's chat data channel.
///
/// Its frames are binary and start with [magic]; the chat messenger on the
/// same channel decodes JSON and ignores them.
class IdentityHandshake {
  IdentityHandshake({
    required this._port,
    required this._identity,
    required this._callId,
    this.onTrust,
    this.resendEvery = const Duration(seconds: 2),
    this.maxHellos = 5,
  });

  /// "VKID1".
  static const List<int> magic = [0x56, 0x4B, 0x49, 0x44, 0x31];
  static const int _hello = 0;
  static const int _reply = 1;
  static const int _keyBytes = 32;
  static const int _sigBytes = 64;
  static const int frameBytes =
      5 + 1 + AppIdentity.installIdBytes + _keyBytes + _sigBytes;
  static const String _domain = 'vck-identity-v1\n';

  final DataChannelPort _port;
  final AppIdentity _identity;
  final String _callId;
  final void Function(PeerTrust trust)? onTrust;
  final Duration resendEvery;
  final int maxHellos;

  /// This call's reading; null until the peer's proof arrived.
  final ValueNotifier<PeerTrust?> trust = ValueNotifier<PeerTrust?>(null);

  /// The sixty digits both phones show for this pair of keys — what the
  /// person compares. Null until a non-changed reading, and null again
  /// once a changed key was seen: there is nothing honest to compare then.
  String? safetyNumber;

  StreamSubscription<List<int>>? _sub;
  Timer? _resend;
  Future<void> _chain = Future<void>.value();
  String? _peerKeyThisCall;
  // The peer the shown [safetyNumber] belongs to.
  String? _peerInstall;
  Uint8List? _peerKey;
  bool _disposed = false;

  /// The person saw the same digits on both phones. The only writer of a
  /// confirmation: [_onFrame] reads verified only from what this stored.
  Future<void> confirmMatch() => _judgedByPerson(PeerTrust.verified);

  /// The person saw different digits: any earlier confirmation is gone and
  /// the reading stays not verified.
  Future<void> denyMatch() => _judgedByPerson(PeerTrust.unverified);

  /// Queued behind any frame still being judged, so a tap never races a
  /// changed key. A no-op once disposed, before a peer, or after changed.
  Future<void> _judgedByPerson(PeerTrust reading) {
    bool stale() =>
        _disposed || _peerInstall == null || trust.value == PeerTrust.changed;
    return _chain = _chain
        .then((_) async {
          if (stale()) return;
          final peer = _peerInstall!;
          if (reading == PeerTrust.verified) {
            await _identity.markVerified(peer, _peerKey!);
          } else {
            await _identity.clearVerified(peer);
          }
          if (stale()) return;
          trust.value = reading;
          onTrust?.call(reading);
        })
        .catchError((Object _) {});
  }

  /// Listens, then says hello — and again every [resendEvery] until the
  /// peer is heard, because a frame sent before the other side listens is
  /// lost.
  Future<void> start() async {
    _sub = _port.inbound.listen((frame) {
      _chain = _chain.then((_) => _onFrame(frame)).catchError((Object _) {});
    });
    await _send(_hello);
    var sent = 1;
    _resend = Timer.periodic(resendEvery, (timer) {
      if (_disposed || _peerKeyThisCall != null || sent >= maxHellos) {
        timer.cancel();
        return;
      }
      sent++;
      unawaited(_send(_hello).catchError((Object _) {}));
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _resend?.cancel();
    await _sub?.cancel();
    trust.dispose();
  }

  /// What both sides sign: the call it was made for, the install id and
  /// the key, under a tag no other message this key signs can begin with.
  Future<Uint8List> _digest(Uint8List install, Uint8List publicKey) =>
      _identity.engine.sha256(
        Uint8List.fromList([
          ...utf8.encode(_domain),
          ...utf8.encode(_callId),
          0,
          ...install,
          ...publicKey,
        ]),
      );

  Future<void> _send(int type) async {
    if (_disposed) return;
    final install = await _identity.installId();
    final publicKey = (await _identity.store.localIdentity()).publicKey;
    final signature = await _identity.store.signSessionFingerprint(
      await _digest(install, publicKey),
    );
    if (_disposed) return;
    await _port.send([...magic, type, ...install, ...publicKey, ...signature]);
  }

  Future<void> _onFrame(List<int> frame) async {
    if (_disposed || frame.length != frameBytes) return;
    for (var i = 0; i < magic.length; i++) {
      if (frame[i] != magic[i]) return;
    }
    final type = frame[5];
    var at = 6;
    final install = Uint8List.fromList(
      frame.sublist(at, at += AppIdentity.installIdBytes),
    );
    final publicKey = Uint8List.fromList(frame.sublist(at, at += _keyBytes));
    final signature = Uint8List.fromList(frame.sublist(at));
    // Our own frame, looped back: not a peer.
    if (_hex(install) == _hex(await _identity.installId())) return;
    // No proof of possession, no reading: a key anyone could have copied.
    final proven = await _identity.engine.verify(
      publicKey: publicKey,
      message: await _digest(install, publicKey),
      signature: signature,
    );
    if (!proven) return;
    if (type == _hello) await _send(_reply);

    final presented = _hex(publicKey);
    final seen = _peerKeyThisCall;
    if (seen == presented) return; // A repeat of what is already judged.
    _peerKeyThisCall = presented;
    final peer = _hex(install);
    final check = seen != null
        // A second, different key inside one call.
        ? RemoteIdentityCheck.changed
        : await _identity.store.checkRemoteIdentity(
            peerId: peer,
            presentedPublicKey: publicKey,
          );
    final reading = switch (check) {
      RemoteIdentityCheck.changed => PeerTrust.changed,
      _ =>
        await _identity.isVerified(peer, publicKey)
            ? PeerTrust.verified
            : PeerTrust.unverified,
    };
    String? number;
    if (reading == PeerTrust.changed) {
      // A second key proven under this install id falsifies "only this key
      // speaks for it": the confirmation must be earned again. The pin
      // itself stays, so the old key still reads as a match next time.
      final judged = _peerInstall;
      _peerInstall = null;
      _peerKey = null;
      await _identity.clearVerified(peer);
      if (judged != null && judged != peer) {
        await _identity.clearVerified(judged);
      }
    } else {
      number = await _identity.store.safetyNumber(
        localPublicKey: (await _identity.store.localIdentity()).publicKey,
        remotePublicKey: publicKey,
      );
    }
    if (_disposed) return;
    if (reading != PeerTrust.changed) {
      _peerInstall = peer;
      _peerKey = publicKey;
    }
    safetyNumber = number;
    lastPeerSighting.value = PeerSighting(
      at: DateTime.now(),
      install: _hex(await _identity.installId()),
      peerInstall: peer,
      check: check,
      trust: reading,
    );
    if (_disposed) return;
    trust.value = reading;
    onTrust?.call(reading);
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _tryHex(String text) {
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(text.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
