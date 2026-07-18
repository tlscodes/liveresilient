/// TURN credential issuance (coturn `use-auth-secret` REST API scheme).
///
/// coturn's `use-auth-secret` mechanism mints short-lived TURN
/// username/password pairs from a shared secret instead of static
/// long-term credentials (`lt-cred-mech`). This lets the signaling server
/// hand each call a credential that already carries its own expiry, so a
/// leaked/logged credential from one call cannot be replayed indefinitely.
///
/// Wire format (fixed by the coturn REST API scheme, not a design choice
/// of this class — the TURN server implements it exactly this way, so
/// client and server must agree byte-for-byte):
/// - `username` = `"<unix-expiry-seconds>:<userId>"` (expiry FIRST, then a
///   colon, then the caller-supplied user identifier);
/// - `credential` = `base64(HMAC-SHA1(sharedSecret, username))`.
///
/// HMAC-SHA1 is used here because it is the algorithm coturn's
/// `use-auth-secret` mechanism is hard-coded to verify — this is an
/// interop requirement with the TURN server, not a general recommendation
/// to use SHA-1 elsewhere in this codebase. Identity and content
/// integrity keep using Ed25519 signatures and SHA-256 hashing (see
/// `identity_store.dart`); this file's SHA-1 usage is scoped to this one
/// legacy wire format.
///
/// `sharedSecret` is server-side secret material (`static-auth-secret` in
/// `turnserver.conf`): it must live only wherever credentials are minted
/// — in this project's architecture, the signaling server — and MUST NOT
/// ship inside a client app bundle. This class is usable from either
/// side mechanically, but issuing real credentials from a client build
/// would leak the shared secret to every device that installs the app.
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';

/// A short-lived TURN username/password pair plus its expiry, matching
/// coturn's `use-auth-secret` REST API scheme.
final class TurnCredentials {
  const TurnCredentials({
    required this.username,
    required this.credential,
    required this.expiresAt,
    this.uris,
  });

  /// `"<unix-expiry-seconds>:<userId>"` — sent as the TURN username.
  final String username;

  /// `base64(HMAC-SHA1(sharedSecret, username))` — sent as the TURN
  /// password/credential.
  final String credential;

  /// When this credential stops being accepted by the TURN server.
  final DateTime expiresAt;

  /// Optional TURN server URIs to pair with this credential (e.g.
  /// `turn:host:3478?transport=udp`), passed through unchanged for the
  /// caller's convenience; this class does not validate or use them.
  final List<String>? uris;
}

/// Mints [TurnCredentials] for coturn's `use-auth-secret` mechanism.
///
/// Requires the same shared secret configured as `static-auth-secret` in
/// `turnserver.conf` on the TURN server side (see `infra/turn/README.md`,
/// "production credentials" section). Time comes from the ambient
/// `package:clock` clock so tests can pin exact expiries with
/// `withClock` instead of depending on wall-clock time.
final class TurnCredentialsIssuer {
  TurnCredentialsIssuer({
    required String sharedSecret,
    this.ttl = const Duration(hours: 1),
  }) : _secretBytes = utf8.encode(sharedSecret) {
    if (sharedSecret.isEmpty) {
      throw ArgumentError.value(
        sharedSecret,
        'sharedSecret',
        'must not be empty',
      );
    }
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'must be strictly positive');
    }
  }

  /// How long a minted credential remains valid. Keep this comfortably
  /// above expected call setup + duration; coturn rejects any TURN
  /// allocation attempt once the encoded expiry has passed.
  final Duration ttl;

  /// Caller-supplied secret material, UTF-8 encoded so the HMAC can be
  /// computed. Dart's [String] and [List] types have no zeroize/wipe
  /// primitive — the bytes stay resident (and, for `String`, may have been
  /// copied by the runtime/GC) for as long as this issuer and its inputs
  /// are reachable. Callers should not retain [sharedSecret] longer than
  /// needed to construct this issuer.
  final List<int> _secretBytes;

  /// Issues a fresh credential for [userId], expiring [ttl] from now.
  ///
  /// [uris] is passed through onto the returned [TurnCredentials]
  /// unchanged; it plays no part in the HMAC computation.
  ///
  /// Throws [ArgumentError] if [userId] is empty or contains a colon
  /// (`:`) — the coturn wire format joins `"<expiry>:<userId>"` with a
  /// colon, so a colon inside `userId` would make the encoded username
  /// structurally ambiguous (the server cannot tell where the expiry
  /// field ends).
  TurnCredentials issue(String userId, {List<String>? uris}) {
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'must not be empty');
    }
    if (userId.contains(':')) {
      throw ArgumentError.value(
        userId,
        'userId',
        'must not contain ":" (would collide with the '
            '"<expiry>:<userId>" wire format separator)',
      );
    }
    final expiresAt = clock.now().toUtc().add(ttl);
    final expirySeconds = expiresAt.millisecondsSinceEpoch ~/ 1000;
    final username = '$expirySeconds:$userId';
    final mac = Hmac(sha1, _secretBytes).convert(utf8.encode(username));
    final credential = base64.encode(mac.bytes);
    return TurnCredentials(
      username: username,
      credential: credential,
      expiresAt: expiresAt,
      uris: uris,
    );
  }

  /// Whether [credentials] has expired as of [now] (defaults to the
  /// ambient clock). The boundary is inclusive: a credential is
  /// considered expired exactly at [TurnCredentials.expiresAt], matching
  /// the TURN server's own check against the encoded unix-second expiry
  /// (a request arriving in the same second the encoded expiry ticks
  /// over is not guaranteed to beat the server's own clock read).
  bool isExpired(TurnCredentials credentials, {DateTime? now}) {
    final at = (now ?? clock.now()).toUtc();
    return !at.isBefore(credentials.expiresAt);
  }
}
