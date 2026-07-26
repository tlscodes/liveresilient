import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'hkdf_key_schedule.dart';

/// Path validation after an endpoint switch, modeled on QUIC PATH_CHALLENGE /
/// PATH_RESPONSE (RFC 9000 section 8.2): before a migrated path may carry
/// media, the peer must echo an unpredictable challenge back, proving the new
/// path actually reaches the same authenticated peer.
///
/// The response is not a plain echo: it is HMAC(session key, challenge), so an
/// on-path attacker who sees the challenge but lacks the session key cannot
/// forge a response (stronger than RFC 9000's echo, which relies on the QUIC
/// AEAD instead).
class PathValidator {
  PathValidator({required Uint8List sessionKey, this.challengeLength = 8})
      : _sessionKey = Uint8List.fromList(sessionKey),
        assert(challengeLength >= 8, 'RFC 9000 uses 8-byte challenges');

  final Uint8List _sessionKey;
  final int challengeLength;

  final Map<String, Uint8List> _outstanding = {};

  int _issued = 0;
  int _validated = 0;
  int _rejected = 0;

  int get outstandingCount => _outstanding.length;
  int get issuedCount => _issued;
  int get validatedCount => _validated;
  int get rejectedCount => _rejected;

  /// Issues a challenge for [pathId] (e.g. "endpointHost:port"). The caller
  /// sends the returned bytes over the NEW path only.
  Uint8List issueChallenge(String pathId, Uint8List randomBytes) {
    if (randomBytes.length != challengeLength) {
      throw ArgumentError.value(randomBytes.length, 'randomBytes',
          'must be exactly $challengeLength bytes');
    }
    final challenge = Uint8List.fromList(randomBytes);
    _outstanding[pathId] = challenge;
    _issued++;
    return challenge;
  }

  /// What the authenticated peer must answer with.
  Uint8List expectedResponse(Uint8List challenge) => Uint8List.fromList(
        Hmac(sha256, _sessionKey).convert(challenge).bytes,
      );

  /// Validates the peer's response for [pathId]. A path becomes usable only
  /// after this returns true; each challenge is single-use.
  bool validateResponse(String pathId, Uint8List response) {
    final challenge = _outstanding[pathId];
    if (challenge == null) {
      _rejected++;
      return false;
    }
    final expected = expectedResponse(challenge);
    var diff = expected.length ^ response.length;
    final len =
        expected.length < response.length ? expected.length : response.length;
    for (var i = 0; i < len; i++) {
      diff |= expected[i] ^ response[i];
    }
    if (diff != 0) {
      _rejected++;
      return false;
    }
    _outstanding.remove(pathId);
    _validated++;
    return true;
  }
}

/// Session continuity across endpoint switches: a resumption token derived
/// from the session key with HKDF (RFC 5869), presented on the new endpoint so
/// the relay can re-attach the existing session without a full re-handshake
/// (the same idea as TLS 1.3 session tickets, RFC 8446 section 4.6.1).
///
/// The token is bound to the session id and an epoch, so rotating the session
/// key (epoch bump) invalidates every previously minted token.
class SessionContinuityToken {
  SessionContinuityToken({required Uint8List sessionKey})
      : _sessionKey = Uint8List.fromList(sessionKey);

  final Uint8List _sessionKey;

  Uint8List mint({required String sessionId, required int epoch}) =>
      Hkdf.derive(
        ikm: _sessionKey,
        salt: Uint8List(0),
        info: Uint8List.fromList(
          utf8.encode('session continuity\n$sessionId\n$epoch'),
        ),
        length: 32,
      );

  /// True when [token] was minted for exactly this session id and epoch.
  bool verify({
    required String sessionId,
    required int epoch,
    required Uint8List token,
  }) {
    final expected = mint(sessionId: sessionId, epoch: epoch);
    var diff = expected.length ^ token.length;
    final len = expected.length < token.length ? expected.length : token.length;
    for (var i = 0; i < len; i++) {
      diff |= expected[i] ^ token[i];
    }
    return diff == 0;
  }
}
