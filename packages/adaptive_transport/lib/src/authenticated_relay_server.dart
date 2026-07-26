import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';

import 'anti_replay_window.dart';
import 'hkdf_key_schedule.dart';
import 'scram_exporter_auth.dart';

/// Session-establishment credential a client presents on the first message of a
/// relay connection.
///
/// The MAC covers every field, so a peer cannot move a captured MAC onto a
/// different nonce, timestamp, or SNI host name.
class SessionCredential {
  const SessionCredential({
    required this.keyId,
    required this.nonce,
    required this.issuedAtMs,
    required this.mac,
    this.sniHostName = '',
  });

  final String keyId;
  final String nonce;
  final int issuedAtMs;
  final Uint8List mac;

  /// The host name the client sent in its TLS SNI extension (RFC 6066
  /// section 3). Binding it into the MAC stops a credential minted for one
  /// virtual host from being replayed against another.
  final String sniHostName;

  /// Canonical, unambiguous signing input. Newline-separated with no field
  /// allowed to contain a newline, so no two distinct credentials can produce
  /// the same bytes.
  Uint8List signingInput() {
    for (final field in [keyId, nonce, sniHostName]) {
      if (field.contains('\n')) {
        throw ArgumentError.value(field, 'field', 'must not contain a newline');
      }
    }
    return Uint8List.fromList(
      utf8.encode('$keyId\n$nonce\n$issuedAtMs\n$sniHostName'),
    );
  }
}

/// Why a handshake was refused. [accepted] is the only non-error outcome.
enum HandshakeRejection {
  accepted,
  unknownKeyId,
  badMac,
  expired,
  replayedNonce,
  malformed,
}

/// The server's answer to a handshake attempt.
class HandshakeOutcome {
  const HandshakeOutcome({
    required this.statusCode,
    required this.rejection,
    required this.closeConnection,
    this.sessionId,
    this.wwwAuthenticate,
  });

  final int statusCode;
  final HandshakeRejection rejection;

  /// True when the server must shut the socket down instead of continuing to
  /// read from it.
  final bool closeConnection;

  final String? sessionId;

  /// RFC 9110 section 11.6.1 requires every 401 response to carry at least one
  /// challenge in WWW-Authenticate.
  final String? wwwAuthenticate;

  bool get accepted => rejection == HandshakeRejection.accepted;
}

/// Verifies HMAC/nonce session credentials before a relay connection is allowed
/// to carry media.
///
/// Rejections answer with `HTTP 401 Unauthorized` plus a challenge (RFC 9110
/// section 11.6.1) and then close the socket, so an unauthenticated peer can
/// never hold a relay slot open.
class AuthenticatedRelayServer {
  AuthenticatedRelayServer({
    required Map<String, Uint8List> sharedKeys,
    this.nonceLifetime = const Duration(seconds: 30),
    this.authScheme = 'HMAC-SHA256',
    this.realm = 'relay',
  })  : _sharedKeys = Map<String, Uint8List>.unmodifiable(
          sharedKeys.map((k, v) => MapEntry(k, Uint8List.fromList(v))),
        ),
        assert(sharedKeys.isNotEmpty, 'at least one shared key is required');

  final Map<String, Uint8List> _sharedKeys;
  final Duration nonceLifetime;
  final String authScheme;
  final String realm;

  /// Nonces already spent, mapped to the instant they stop being replay-
  /// relevant. Entries older than that are pruned, so memory stays bounded by
  /// the handshake rate inside one [nonceLifetime] window.
  final Map<String, DateTime> _spentNonces = {};

  int _sessionCounter = 0;

  /// Number of nonces currently held for replay detection.
  int get trackedNonceCount => _spentNonces.length;

  /// Computes the MAC a client is expected to present for [credential] under
  /// the key named by its `keyId`.
  Uint8List expectedMac(SessionCredential credential) {
    final key = _sharedKeys[credential.keyId];
    if (key == null) {
      throw StateError('No shared key for keyId ${credential.keyId}');
    }
    return Uint8List.fromList(
      Hmac(sha256, key).convert(credential.signingInput()).bytes,
    );
  }

  HandshakeOutcome handleHandshake(SessionCredential credential) {
    final now = clock.now();
    _pruneSpentNonces(now);

    if (credential.keyId.isEmpty || credential.nonce.isEmpty) {
      return _reject(HandshakeRejection.malformed);
    }
    if (!_sharedKeys.containsKey(credential.keyId)) {
      return _reject(HandshakeRejection.unknownKeyId);
    }

    final Uint8List expected;
    try {
      expected = expectedMac(credential);
    } on ArgumentError {
      return _reject(HandshakeRejection.malformed);
    }
    if (!_constantTimeEquals(expected, credential.mac)) {
      return _reject(HandshakeRejection.badMac);
    }

    // Age is checked only after the MAC verifies, so an unauthenticated peer
    // learns nothing about the server's clock.
    final age = now.difference(
      DateTime.fromMillisecondsSinceEpoch(credential.issuedAtMs),
    );
    if (age.isNegative || age > nonceLifetime) {
      return _reject(HandshakeRejection.expired);
    }

    final nonceKey = '${credential.keyId}:${credential.nonce}';
    if (_spentNonces.containsKey(nonceKey)) {
      return _reject(HandshakeRejection.replayedNonce);
    }
    _spentNonces[nonceKey] = now.add(nonceLifetime);

    _sessionCounter++;
    return HandshakeOutcome(
      statusCode: 200,
      rejection: HandshakeRejection.accepted,
      closeConnection: false,
      sessionId: 's$_sessionCounter-${credential.nonce}',
    );
  }

  HandshakeOutcome _reject(HandshakeRejection rejection) => HandshakeOutcome(
        statusCode: 401,
        rejection: rejection,
        closeConnection: true,
        wwwAuthenticate: '$authScheme realm="$realm"',
      );

  void _pruneSpentNonces(DateTime now) {
    _spentNonces.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
  }

  /// Length-independent-time comparison so a wrong MAC leaks no byte position.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    int diff = a.length ^ b.length;
    final int len = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// A fully authenticated relay session: SCRAM mutual auth (RFC 5802) bound to
/// the connection's TLS 1.3 exporter (RFC 8446 section 7.5), then per-message
/// anti-replay via a counter+bitmap window and HKDF-driven key rotation
/// (RFC 5869).
///
/// Compared to [AuthenticatedRelayServer]'s single-shot HMAC credential, this
/// upgrades every axis:
///  * mutual — the client also verifies the server (ServerSignature);
///  * channel-bound — a proof captured on one TLS connection is useless on
///    any other, because the exporter value differs;
///  * O(1) replay defense — bitmap window instead of a growing nonce set;
///  * forward-ratcheted — traffic keys rotate by epoch and old keys are wiped.
class MutualRelaySession {
  MutualRelaySession._({
    required this.sessionId,
    required RotatingKeySchedule keySchedule,
    required AntiReplayWindow replayWindow,
  })  : _keySchedule = keySchedule,
        _replayWindow = replayWindow;

  /// Runs the server side of the SCRAM exchange. Returns null (auth failed)
  /// or an established session whose traffic keys are derived from the
  /// exporter and the handshake, so both directions start from a fresh,
  /// connection-unique secret.
  static ({MutualRelaySession session, Uint8List serverSignature})?
      establish({
    required ScramVerifier verifier,
    required String clientNonce,
    required String serverNonce,
    required Uint8List tlsExporter,
    required Uint8List clientProof,
    int replayWindowSize = 1024,
    int messagesPerEpoch = 1 << 20,
  }) {
    final server = ScramServer(verifier: verifier);
    final serverSignature = server.verifyClientProof(
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      channelBinding: tlsExporter,
      clientProof: clientProof,
    );
    if (serverSignature == null) return null;
    final trafficSecret = Hkdf.derive(
      ikm: Uint8List.fromList([...verifier.storedKey, ...tlsExporter]),
      salt: Uint8List.fromList(utf8.encode('$clientNonce$serverNonce')),
      info: Uint8List.fromList(utf8.encode('relay traffic secret')),
      length: 32,
    );
    final session = MutualRelaySession._(
      sessionId: 'scram-$clientNonce$serverNonce',
      keySchedule: RotatingKeySchedule(
        initialSecret: trafficSecret,
        messagesPerEpoch: messagesPerEpoch,
      ),
      replayWindow: AntiReplayWindow(windowSize: replayWindowSize),
    );
    return (session: session, serverSignature: serverSignature);
  }

  final String sessionId;
  final RotatingKeySchedule _keySchedule;
  final AntiReplayWindow _replayWindow;

  int get keyEpoch => _keySchedule.epoch;
  Uint8List get trafficKey => _keySchedule.currentKey;
  AntiReplayWindow get replayWindow => _replayWindow;

  /// Admits one protected message: the sequence number must clear the replay
  /// window, and the epoch counter advances the key schedule when its budget
  /// is spent. Returns false for replayed/stale sequence numbers.
  bool admitMessage(int sequenceNumber) {
    if (!_replayWindow.accept(sequenceNumber)) return false;
    _keySchedule.recordMessage();
    return true;
  }
}
