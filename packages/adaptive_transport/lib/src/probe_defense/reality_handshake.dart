/// X25519 admission handshake, and where a 64-byte signature actually goes.
///
/// This replaces the pre-shared-secret arrangement in
/// [RealityAuthenticator] with the exchange the design always wanted:
///
/// 1. The client generates an **ephemeral X25519 key pair** per connection
///    and puts the public half in the hello's `key_share` extension —
///    where a real browser's X25519 share lives, so nothing about its
///    presence is unusual.
/// 2. Both sides compute the same shared secret: the client from
///    (its ephemeral private, the relay's published static public), the
///    relay from (its static private, the client's ephemeral public).
/// 3. [Hkdf] turns that secret into the short id and the tag key, so the
///    32-byte `legacy_session_id` carries a *derived* authenticator rather
///    than a stored one. Nothing pre-shared travels, and a captured hello
///    reveals no key: recovering the secret from the ephemeral public key
///    is the X25519 discrete-log problem.
///
/// **The 64-byte signature question, answered structurally.** An Ed25519
/// signature is 64 bytes and `legacy_session_id` is 32; no encoding fixes
/// that, and stretching the field would itself be the anomaly the whole
/// design exists to avoid. So identity proof is not in the hello at all.
/// It moves to the first record *after* admission — [RealityIdentityProof],
/// a framed 100-byte message with its own 4-byte header, sent on the
/// channel the handshake just established. That path has no size limit and
/// no fingerprint surface, because by then the connection is already
/// indistinguishable from an ordinary TLS session to anyone watching.
///
/// The split is deliberate: the hello proves *authorization* (may this
/// connection continue at all — the question the pass-through decision
/// turns on), and the first record proves *identity* (which peer this is —
/// a slower question that no longer has to be answered before the routing
/// decision).
///
/// **What the exchange costs, measured.** Adding X25519 to the admission
/// path is not free, and the number is bigger than it looks:
/// `tool/bench_x25519.dart` measures the pure-Dart scalar multiply at
/// ~1876 us, against ~77 us for the HKDF-plus-HMAC work around it. So this
/// path spends ~2 ms per candidate key, and the sub-2 ms routing budget
/// that [RealityAuthenticator]'s pre-shared path meets comfortably is
/// missed here. [KeyAgreement] is an interface precisely so a native
/// backend can close that gap; until one is wired in, the trade is real
/// and a deployment should choose it knowingly — forward secrecy for
/// roughly 2 ms of admission latency.
library;

import 'dart:typed_data';

// `cryptography` exports its own `Hkdf`; this file uses the project's
// RFC 5869 implementation, which the phase-7 vector tests cover.
import 'package:cryptography/cryptography.dart' hide Hkdf;

import '../hkdf_key_schedule.dart';
import '../scram_exporter_auth.dart' show constantTimeEquals;
import 'reality_pass_through.dart';
import 'tls_client_hello.dart';
import 'utls_client_profile.dart';

/// A raw key pair, as bytes.
class KeyPairBytes {
  const KeyPairBytes({required this.publicKey, required this.privateKey});

  /// 32-byte X25519 public key.
  final Uint8List publicKey;

  /// 32-byte X25519 private key. Never leaves the process that made it,
  /// and never appears in a config file.
  final Uint8List privateKey;
}

/// X25519 key agreement, behind an interface so tests can pin vectors and
/// so a hardware-backed implementation can replace the software one.
abstract interface class KeyAgreement {
  Future<KeyPairBytes> generateEphemeral();

  /// The X25519 shared secret between [privateKey] and [peerPublicKey].
  Future<Uint8List> sharedSecret({
    required Uint8List privateKey,
    required Uint8List peerPublicKey,
  });
}

/// X25519 over `package:cryptography` — the same audited implementation
/// the `security` package uses for Ed25519.
class X25519KeyAgreement implements KeyAgreement {
  X25519KeyAgreement({X25519? algorithm}) : _algorithm = algorithm ?? X25519();

  final X25519 _algorithm;

  /// X25519 keys and shared secrets are 32 bytes (RFC 7748 section 5).
  static const int keyLength = 32;

  @override
  Future<KeyPairBytes> generateEphemeral() async {
    final pair = await _algorithm.newKeyPair();
    final public = await pair.extractPublicKey();
    return KeyPairBytes(
      publicKey: Uint8List.fromList(public.bytes),
      privateKey: Uint8List.fromList(await pair.extractPrivateKeyBytes()),
    );
  }

  @override
  Future<Uint8List> sharedSecret({
    required Uint8List privateKey,
    required Uint8List peerPublicKey,
  }) async {
    if (privateKey.length != keyLength || peerPublicKey.length != keyLength) {
      throw ArgumentError('X25519 keys must be $keyLength bytes');
    }
    final pair = await _algorithm.newKeyPairFromSeed(privateKey);
    final secret = await _algorithm.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }
}

/// The relay's long-term X25519 key pair. The public half is what clients
/// are provisioned with; the private half exists only in the relay.
class RealityRelayIdentity {
  const RealityRelayIdentity({required this.keyPair});

  final KeyPairBytes keyPair;

  /// The value that goes into a client config. Safe to publish: it is a
  /// public key, and it names no address.
  Uint8List get publicKey => keyPair.publicKey;

  static Future<RealityRelayIdentity> generate({
    KeyAgreement? agreement,
  }) async {
    final impl = agreement ?? X25519KeyAgreement();
    return RealityRelayIdentity(keyPair: await impl.generateEphemeral());
  }
}

/// What a client produced for one connection attempt.
class RealityClientHandshake {
  const RealityClientHandshake({
    required this.ephemeral,
    required this.credential,
    required this.sessionId,
    required this.clientRandom,
    required this.timeSlot,
  });

  /// The per-connection X25519 key pair. Discarded when the connection
  /// ends; a later compromise of the relay's static key cannot re-derive
  /// past sessions' tags from a recorded hello, because the ephemeral
  /// private half no longer exists anywhere.
  final KeyPairBytes ephemeral;

  /// The credential derived from the exchange.
  final RealityCredential credential;

  /// The 32 bytes to put in `legacy_session_id`.
  final Uint8List sessionId;

  /// The 32 bytes to put in the hello's `random`.
  final Uint8List clientRandom;

  final int timeSlot;

  /// The bytes the transcript covers, which an identity proof signs.
  Uint8List get transcript => _handshakeTranscript(
    clientRandom: clientRandom,
    ephemeralPublicKey: ephemeral.publicKey,
    shortId: credential.shortId,
    timeSlot: timeSlot,
  );
}

/// Builds the client half of the admission handshake.
class RealityClientKeyExchange {
  RealityClientKeyExchange({
    required this.relayPublicKey,
    KeyAgreement? agreement,
  }) : _agreement = agreement ?? X25519KeyAgreement();

  /// The relay's published static X25519 public key.
  final Uint8List relayPublicKey;

  final KeyAgreement _agreement;

  /// Runs the exchange and produces everything the hello needs.
  Future<RealityClientHandshake> begin({
    required Uint8List clientRandom,
    required int timeSlot,
  }) async {
    final ephemeral = await _agreement.generateEphemeral();
    final shared = await _agreement.sharedSecret(
      privateKey: ephemeral.privateKey,
      peerPublicKey: relayPublicKey,
    );
    final credential = RealityCredential.fromSharedSecret(shared);
    return RealityClientHandshake(
      ephemeral: ephemeral,
      credential: credential,
      sessionId: credential.buildSessionId(
        clientRandom: clientRandom,
        timeSlot: timeSlot,
      ),
      clientRandom: clientRandom,
      timeSlot: timeSlot,
    );
  }

  /// Convenience: the full hello bytes for [profile], with the ephemeral
  /// public key in `key_share` and the derived authenticator in
  /// `legacy_session_id`.
  Uint8List buildHello({
    required RealityClientHandshake handshake,
    required UtlsClientHelloBuilder builder,
    String? serverName,
    bool enableEch = false,
  }) {
    return builder.build(
      serverName: serverName,
      clientRandom: handshake.clientRandom,
      sessionId: handshake.sessionId,
      enableEch: enableEch,
      keyShares: {TlsNamedGroup.x25519: handshake.ephemeral.publicKey},
    );
  }
}

/// Verifies a hello by running the exchange from the relay's side.
///
/// Unlike [RealityAuthenticator], there is no credential registry: the
/// credential is *derived per connection* from the client's ephemeral
/// public key. A probe that sends any other key share derives a different
/// short id and fails, and the relay stores no per-client secret that a
/// compromise could leak.
class RealityKeyExchangeAuthenticator {
  RealityKeyExchangeAuthenticator({
    required this.identity,
    KeyAgreement? agreement,
    RealityAuthenticator? replayGuard,
  }) : _agreement = agreement ?? X25519KeyAgreement(),
       _guard = replayGuard ?? RealityAuthenticator(credentials: const []);

  final RealityRelayIdentity identity;
  final KeyAgreement _agreement;

  /// Reused only for its clock-skew and replay bookkeeping; its credential
  /// registry is intentionally empty.
  final RealityAuthenticator _guard;

  /// The time slot a client should stamp right now.
  int get currentTimeSlot => _guard.currentTimeSlot;

  /// Decides on one hello.
  Future<RealityDecision> inspect(TlsClientHello hello) async {
    if (hello.sessionId.length != RealitySessionIdLayout.totalLength) {
      return RealityDecision.passThrough(
        RealityRejectReason.sessionIdWrongSize,
        hello: hello,
      );
    }

    final share = _x25519Share(hello);
    if (share == null) {
      // No X25519 share at all: not a client of ours. Browsers always send
      // one, so this costs no false rejections.
      return RealityDecision.passThrough(
        RealityRejectReason.unknownShortId,
        hello: hello,
      );
    }

    final Uint8List shared;
    try {
      shared = await _agreement.sharedSecret(
        privateKey: identity.keyPair.privateKey,
        peerPublicKey: share,
      );
    } catch (_) {
      return RealityDecision.passThrough(
        RealityRejectReason.badAuthTag,
        hello: hello,
      );
    }

    final credential = RealityCredential.fromSharedSecret(shared);
    final presentedShortId = Uint8List.sublistView(
      hello.sessionId,
      0,
      RealitySessionIdLayout.shortIdLength,
    );
    if (!constantTimeEquals(credential.shortId, presentedShortId)) {
      return RealityDecision.passThrough(
        RealityRejectReason.unknownShortId,
        hello: hello,
      );
    }

    // Hand the rest — tag, clock skew, replay — to the long-lived guard,
    // so there is one implementation of those rules and one replay memory
    // that actually spans connections.
    return _guard.verifyWith(hello, credential);
  }

  /// The client's X25519 `key_share` public key, or null when the hello
  /// carries none of the right shape.
  ///
  /// Public because the rotating authenticator needs the same extraction
  /// and a second copy of this parser would be a place for the two to
  /// disagree about what counts as a valid share.
  static Uint8List? clientX25519Share(TlsClientHello hello) =>
      _x25519Share(hello);

  static Uint8List? _x25519Share(TlsClientHello hello) {
    final ext = hello.extension(TlsExtensionType.keyShare);
    if (ext == null) return null;
    final data = ext.data;
    if (data.length < 2) return null;
    final view = ByteData.sublistView(data);
    final listLength = view.getUint16(0);
    var offset = 2;
    final end = 2 + listLength;
    while (offset + 4 <= end && offset + 4 <= data.length) {
      final group = view.getUint16(offset);
      final length = view.getUint16(offset + 2);
      final start = offset + 4;
      if (start + length > data.length) return null;
      if (group == TlsNamedGroup.x25519 &&
          length == X25519KeyAgreement.keyLength) {
        return Uint8List.sublistView(data, start, start + length);
      }
      offset = start + length;
    }
    return null;
  }
}

/// Ed25519 identity proof, sent as the first record after admission.
///
/// Wire format — a 4-byte header, then the body, which is exactly the
/// separation the 32-byte `session_id` could not provide:
///
/// ```text
///   [0]      type   = 0x01 (identity_proof)
///   [1]      version = 0x01
///   [2..4)   body length, u16 big-endian = 96
///   [4..36)  Ed25519 public key   (32 bytes)
///   [36..100) Ed25519 signature   (64 bytes)
/// ```
///
/// The signature covers the handshake transcript, so an identity proof
/// lifted from one connection does not verify on another.
class RealityIdentityProof {
  const RealityIdentityProof({
    required this.publicKey,
    required this.signature,
  });

  /// 32-byte Ed25519 public key.
  final Uint8List publicKey;

  /// 64-byte Ed25519 signature over the transcript.
  final Uint8List signature;

  static const int frameType = 0x01;
  static const int frameVersion = 0x01;
  static const int headerLength = 4;
  static const int publicKeyLength = 32;
  static const int signatureLength = 64;
  static const int bodyLength = publicKeyLength + signatureLength;
  static const int frameLength = headerLength + bodyLength;

  /// Signs [transcript] with [keyPair] and returns the proof.
  static Future<RealityIdentityProof> create({
    required SimpleKeyPair keyPair,
    required Uint8List transcript,
    Ed25519? algorithm,
  }) async {
    final ed = algorithm ?? Ed25519();
    final signature = await ed.sign(transcript, keyPair: keyPair);
    final public = await keyPair.extractPublicKey();
    return RealityIdentityProof(
      publicKey: Uint8List.fromList(public.bytes),
      signature: Uint8List.fromList(signature.bytes),
    );
  }

  /// Verifies this proof against [transcript].
  Future<bool> verify(Uint8List transcript, {Ed25519? algorithm}) async {
    final ed = algorithm ?? Ed25519();
    try {
      return await ed.verify(
        transcript,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      // A malformed key or signature is a failed verification, not a
      // crash — the peer controls these bytes.
      return false;
    }
  }

  Uint8List encode() {
    final frame = Uint8List(frameLength);
    frame[0] = frameType;
    frame[1] = frameVersion;
    ByteData.sublistView(frame).setUint16(2, bodyLength);
    frame.setRange(headerLength, headerLength + publicKeyLength, publicKey);
    frame.setRange(headerLength + publicKeyLength, frameLength, signature);
    return frame;
  }

  /// Parses a proof frame. Throws [FormatException] on anything else.
  factory RealityIdentityProof.decode(Uint8List frame) {
    if (frame.length < frameLength) {
      throw FormatException(
        'identity proof needs $frameLength bytes, got ${frame.length}',
      );
    }
    if (frame[0] != frameType) {
      throw FormatException(
        'frame type 0x${frame[0].toRadixString(16)} '
        'is not an identity proof',
      );
    }
    if (frame[1] != frameVersion) {
      throw FormatException('unsupported identity-proof version ${frame[1]}');
    }
    final declared = ByteData.sublistView(frame).getUint16(2);
    if (declared != bodyLength) {
      throw FormatException(
        'identity proof declares $declared body bytes, expected $bodyLength',
      );
    }
    return RealityIdentityProof(
      publicKey: Uint8List.sublistView(
        frame,
        headerLength,
        headerLength + publicKeyLength,
      ),
      signature: Uint8List.sublistView(
        frame,
        headerLength + publicKeyLength,
        frameLength,
      ),
    );
  }
}

/// The bytes an identity proof signs.
///
/// Binding all four values means a proof is valid for exactly one
/// connection: a different random, a different ephemeral key, or a
/// different time slot all produce a different transcript.
Uint8List _handshakeTranscript({
  required Uint8List clientRandom,
  required Uint8List ephemeralPublicKey,
  required Uint8List shortId,
  required int timeSlot,
}) {
  final slot = Uint8List(4);
  ByteData.sublistView(slot).setUint32(0, timeSlot);
  final builder = BytesBuilder(copy: false)
    ..add('reality-identity-v1'.codeUnits)
    ..add(clientRandom)
    ..add(ephemeralPublicKey)
    ..add(shortId)
    ..add(slot);
  return builder.toBytes();
}

/// Public form of the transcript, for a relay that must rebuild it from a
/// received hello rather than from its own handshake object.
Uint8List realityHandshakeTranscript({
  required Uint8List clientRandom,
  required Uint8List ephemeralPublicKey,
  required Uint8List shortId,
  required int timeSlot,
}) => _handshakeTranscript(
  clientRandom: clientRandom,
  ephemeralPublicKey: ephemeralPublicKey,
  shortId: shortId,
  timeSlot: timeSlot,
);

/// Derives an application session key from the handshake's shared secret.
///
/// Separate from the admission credential by a different HKDF label, so
/// the key that protects call media is not the key that authenticated the
/// hello — a tag observed on the wire says nothing about the media key.
Uint8List deriveSessionKey(
  Uint8List sharedSecret, {
  String label = 'reality-session-v1',
  int length = 32,
}) => Hkdf.derive(
  ikm: sharedSecret,
  salt: Uint8List(0),
  info: Uint8List.fromList(label.codeUnits),
  length: length,
);
