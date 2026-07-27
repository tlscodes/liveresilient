import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// SCRAM-style mutual authentication (RFC 5802) over HMAC-SHA256, with the
/// channel binding slot carrying a TLS 1.3 exporter value (RFC 8446
/// section 7.5, used the way RFC 9266 defines `tls-exporter`).
///
/// Flow (one round trip each way):
///  1. client-first: username + client nonce
///  2. server-first: combined nonce + salt + iteration count
///  3. client-final: channel binding (exporter) + ClientProof
///  4. server-final: ServerSignature — the client verifies it, so the server
///     also proves possession of the password-derived key (mutual auth).
///
/// The server stores only `StoredKey`/`ServerKey`, never the password.

/// The label RFC 9266 assigns to the TLS 1.3 exporter used as a channel
/// binding, and the exporter output length this implementation fixes.
const String tlsExporterLabel = 'EXPORTER-Channel-Binding';
const int tlsExporterLength = 32;

Uint8List _hmac(Uint8List key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

Uint8List _h(List<int> data) => Uint8List.fromList(sha256.convert(data).bytes);

/// Hi(str, salt, i) from RFC 5802 section 2.2 — PBKDF2-style iterated HMAC.
Uint8List scramHi(Uint8List password, Uint8List salt, int iterations) {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'must be >= 1');
  }
  var u = _hmac(password, [...salt, 0, 0, 0, 1]);
  final result = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = _hmac(password, u);
    for (var j = 0; j < result.length; j++) {
      result[j] ^= u[j];
    }
  }
  return result;
}

/// The verifier record a server keeps per user instead of the password.
class ScramVerifier {
  ScramVerifier({
    required this.username,
    required this.salt,
    required this.iterations,
    required this.storedKey,
    required this.serverKey,
  });

  /// Derives the stored verifier from a password, run once at enrollment.
  factory ScramVerifier.fromPassword({
    required String username,
    required String password,
    required Uint8List salt,
    int iterations = 4096,
  }) {
    final salted = scramHi(
      Uint8List.fromList(utf8.encode(password)),
      salt,
      iterations,
    );
    final clientKey = _hmac(salted, utf8.encode('Client Key'));
    return ScramVerifier(
      username: username,
      salt: salt,
      iterations: iterations,
      storedKey: _h(clientKey),
      serverKey: _hmac(salted, utf8.encode('Server Key')),
    );
  }

  final String username;
  final Uint8List salt;
  final int iterations;
  final Uint8List storedKey;
  final Uint8List serverKey;
}

/// What both sides MAC over: every handshake field plus the channel binding,
/// so a proof cannot be replayed on a different TLS connection (the exporter
/// value differs) or with different nonces.
Uint8List scramAuthMessage({
  required String username,
  required String clientNonce,
  required String serverNonce,
  required Uint8List salt,
  required int iterations,
  required Uint8List channelBinding,
}) {
  if (channelBinding.length != tlsExporterLength) {
    throw ArgumentError.value(
      channelBinding.length,
      'channelBinding',
      'must be a $tlsExporterLength-byte TLS exporter value',
    );
  }
  return Uint8List.fromList([
    ...utf8.encode('n=$username,r=$clientNonce\n'),
    ...utf8.encode(
      'r=$clientNonce$serverNonce,'
      's=${base64.encode(salt)},i=$iterations\n',
    ),
    ...utf8.encode('c='),
    ...channelBinding,
    ...utf8.encode(',r=$clientNonce$serverNonce'),
  ]);
}

/// Client side: computes ClientProof and verifies the server's signature.
class ScramClient {
  ScramClient({required this.username, required String password})
    : _password = Uint8List.fromList(utf8.encode(password));

  final String username;
  final Uint8List _password;

  Uint8List? _serverKeyCheck;

  /// Computes the client-final proof for the server's challenge parameters.
  Uint8List proof({
    required String clientNonce,
    required String serverNonce,
    required Uint8List salt,
    required int iterations,
    required Uint8List channelBinding,
  }) {
    final salted = scramHi(_password, salt, iterations);
    final clientKey = _hmac(salted, utf8.encode('Client Key'));
    final storedKey = _h(clientKey);
    final auth = scramAuthMessage(
      username: username,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      salt: salt,
      iterations: iterations,
      channelBinding: channelBinding,
    );
    final signature = _hmac(storedKey, auth);
    final proof = Uint8List(clientKey.length);
    for (var i = 0; i < proof.length; i++) {
      proof[i] = clientKey[i] ^ signature[i];
    }
    _serverKeyCheck = _hmac(_hmac(salted, utf8.encode('Server Key')), auth);
    return proof;
  }

  /// Mutual-auth step: true only when the server proved it holds ServerKey
  /// for this exact handshake (same nonces, same channel binding).
  bool verifyServerSignature(Uint8List serverSignature) {
    final expected = _serverKeyCheck;
    if (expected == null) return false;
    return constantTimeEquals(expected, serverSignature);
  }
}

/// Server side: verifies ClientProof against the stored verifier and, on
/// success, returns the ServerSignature the client will check.
class ScramServer {
  ScramServer({required this.verifier});

  final ScramVerifier verifier;

  /// Verifies [clientProof]; returns the server signature on success, null on
  /// failure. Never throws on bad input, so timing stays uniform.
  Uint8List? verifyClientProof({
    required String clientNonce,
    required String serverNonce,
    required Uint8List channelBinding,
    required Uint8List clientProof,
  }) {
    if (clientProof.length != verifier.storedKey.length) return null;
    final auth = scramAuthMessage(
      username: verifier.username,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      salt: verifier.salt,
      iterations: verifier.iterations,
      channelBinding: channelBinding,
    );
    final signature = _hmac(verifier.storedKey, auth);
    final recoveredClientKey = Uint8List(clientProof.length);
    for (var i = 0; i < clientProof.length; i++) {
      recoveredClientKey[i] = clientProof[i] ^ signature[i];
    }
    if (!constantTimeEquals(_h(recoveredClientKey), verifier.storedKey)) {
      return null;
    }
    return _hmac(verifier.serverKey, auth);
  }
}

/// Length-independent-time comparison so a mismatch leaks no byte position.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  var diff = a.length ^ b.length;
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
