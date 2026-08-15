/// Relay static-key rotation, on epochs, with no wire change at all.
///
/// The design constraint that shapes everything here: the admission
/// payload has no room left. `legacy_session_id` is exactly 32 bytes and
/// all of them are spent (8 short id + 4 time slot + 20 tag), and adding a
/// key-id field anywhere else in the hello would create precisely the kind
/// of distinguishing marker the surrounding layer exists to avoid. A
/// browser's hello carries no such field, so ours must not either.
///
/// So the epoch is **not** transmitted. The relay recovers it by trial:
/// it runs the X25519 agreement against each key in its ring and keeps the
/// one whose derived short id matches what the client presented.
///
/// **The cost, measured rather than assumed.** `tool/bench_x25519.dart` on
/// the Dart VM (Apple Silicon, JIT, warmed):
///
/// ```text
///   X25519 shared secret   1876 us/op     <- pure-Dart scalar multiply
///   X25519 keygen           947 us/op
///   HKDF credential          77 us/op
/// ```
///
/// That changes what can honestly be claimed. The sub-2 ms admission
/// budget holds for the pre-shared-key path in [RealityAuthenticator]
/// (~0.1 ms: one HKDF plus one HMAC), and it does **not** hold for the
/// key-exchange path: one key costs ~2 ms and a two-key grace window costs
/// ~4 ms. Meeting 2 ms here requires a native X25519 backend behind
/// [KeyAgreement] — `cryptography_flutter` or a platform binding — which
/// is exactly why key agreement sits behind that interface. Until such a
/// backend is wired in, a deployment that needs the tight budget should
/// run the pre-shared path and accept its weaker key hygiene, and one that
/// needs forward secrecy should accept ~2-4 ms. Stating this plainly beats
/// a comment claiming a budget the code misses by 2x.
///
/// The cost is bounded but real: rotation adds up to 2 extra scalar
/// multiplications, paid on *unauthenticated* connections too, since a
/// probe is tried against every key before being spliced away. A relay
/// under heavy scanning pays it on every probe, so [RelayKeyRing.maxKeys]
/// caps the worst case at three.
///
/// Three keys, three roles:
///
/// * **current** — what freshly-provisioned clients use.
/// * **previous** — accepted through the grace window, so a client whose
///   config predates the rotation still connects. Admission under this key
///   sets [EpochAdmission.keyUpdateRequired], and the relay answers with a
///   [RelayKeyUpdate] frame on the now-authenticated channel.
/// * **next** — published ahead of time so clients can pre-fetch, never
///   accepted before its epoch begins. Accepting it early would widen the
///   window a stolen key is useful in, which is the opposite of the point.
library;

import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../scram_exporter_auth.dart' show constantTimeEquals;
import 'reality_handshake.dart';
import 'reality_pass_through.dart';
import 'tls_client_hello.dart';

/// One static key pair and the epoch it belongs to.
class RelayKeyEpoch {
  const RelayKeyEpoch({required this.epoch, required this.keyPair});

  /// Monotonic epoch number. Derived from the clock by
  /// [RelayKeyRing.epochAt], never sent on the wire.
  final int epoch;

  final KeyPairBytes keyPair;

  Uint8List get publicKey => keyPair.publicKey;

  @override
  String toString() => 'RelayKeyEpoch($epoch)';
}

/// Raised when a ring is asked for something it cannot honor.
class KeyRotationError implements Exception {
  const KeyRotationError(this.message);

  final String message;

  @override
  String toString() => 'KeyRotationError: $message';
}

/// The relay's rolling set of static keys.
class RelayKeyRing {
  RelayKeyRing({
    required RelayKeyEpoch current,
    RelayKeyEpoch? previous,
    RelayKeyEpoch? next,
    this.epochDuration = const Duration(days: 7),
    this.gracePeriod = const Duration(days: 1),
    this.origin,
  }) : _current = current,
       _previous = previous,
       _next = next {
    if (epochDuration <= Duration.zero) {
      throw const KeyRotationError('epochDuration must be positive');
    }
    if (gracePeriod > epochDuration) {
      // A grace window longer than an epoch would keep a key valid past
      // the rotation that replaced the one after it.
      throw const KeyRotationError('gracePeriod must not exceed epochDuration');
    }
    if (previous != null && previous.epoch >= current.epoch) {
      throw const KeyRotationError('previous epoch must precede current');
    }
    if (next != null && next.epoch <= current.epoch) {
      throw const KeyRotationError('next epoch must follow current');
    }
  }

  /// Builds a ring with freshly generated keys for all three roles.
  static Future<RelayKeyRing> generate({
    KeyAgreement? agreement,
    Duration epochDuration = const Duration(days: 7),
    Duration gracePeriod = const Duration(days: 1),
    DateTime? origin,
  }) async {
    final impl = agreement ?? X25519KeyAgreement();
    final start = origin ?? clock.now();
    final epoch = _epochAt(start, start, epochDuration);
    return RelayKeyRing(
      current: RelayKeyEpoch(
        epoch: epoch,
        keyPair: await impl.generateEphemeral(),
      ),
      next: RelayKeyEpoch(
        epoch: epoch + 1,
        keyPair: await impl.generateEphemeral(),
      ),
      epochDuration: epochDuration,
      gracePeriod: gracePeriod,
      origin: start,
    );
  }

  /// How long one epoch lasts.
  final Duration epochDuration;

  /// The overlap window: how long after a rotation the outgoing epoch's
  /// key still authenticates material that arrives. Defaults to one day
  /// (set in the constructor and in [generate]) — long enough for a
  /// client holding a pre-rotation config to connect once more and be
  /// handed a [RelayKeyUpdate] on the authenticated channel.
  ///
  /// Zero is constructible and wrong to run: with no overlap, the instant
  /// of rotation invalidates every connection already in flight under the
  /// outgoing key and strands every client whose config predates the
  /// rotation, turning routine key hygiene into a scheduled outage. The
  /// overlap exists so a rotation never invalidates work already in
  /// progress; shortening it to zero saves nothing and removes exactly
  /// that guarantee.
  final Duration gracePeriod;

  /// Epoch-numbering origin. Null means epochs count from the Unix epoch.
  final DateTime? origin;

  /// The ring never holds more than this many keys — the bound on how much
  /// trial work one admission decision can cost.
  static const int maxKeys = 3;

  RelayKeyEpoch _current;
  RelayKeyEpoch? _previous;
  RelayKeyEpoch? _next;

  RelayKeyEpoch get current => _current;
  RelayKeyEpoch? get previous => _previous;
  RelayKeyEpoch? get next => _next;

  /// Whether [gracePeriod] has elapsed since the last rotation, which is
  /// what retires the previous key.
  DateTime? _rotatedAt;

  /// The epoch number for [at].
  int epochAt(DateTime at) => _epochAt(
    at,
    origin ?? DateTime.fromMillisecondsSinceEpoch(0),
    epochDuration,
  );

  static int _epochAt(DateTime at, DateTime origin, Duration epochDuration) {
    final elapsed = at.toUtc().difference(origin.toUtc()).inMicroseconds;
    return elapsed ~/ epochDuration.inMicroseconds;
  }

  /// The epoch number right now.
  int get currentEpoch => epochAt(clock.now());

  /// Whether the previous key is still inside its grace window.
  bool get previousInGrace {
    final previous = _previous;
    final rotatedAt = _rotatedAt;
    if (previous == null || rotatedAt == null) return false;
    return clock.now().difference(rotatedAt) <= gracePeriod;
  }

  /// Whether [_next] has reached its epoch and should be promoted.
  bool get rotationDue => currentEpoch >= (_next?.epoch ?? 1 << 62);

  /// ACCEPT role: the epochs whose keys may verify material that arrives
  /// right now, best first.
  ///
  /// During the overlap this holds two entries — the current epoch and
  /// the previous one still inside [gracePeriod]. `next` is deliberately
  /// absent: it is published so clients can pre-fetch, not accepted
  /// before its time.
  ///
  /// Contrast [emissionEpoch]: what the ring accepts is plural during an
  /// overlap; what it emits under never is.
  List<RelayKeyEpoch> get admissibleKeys => [
    _current,
    if (previousInGrace) _previous!,
  ];

  /// EMIT role: the single epoch used for material being produced right
  /// now.
  ///
  /// Always the newest promoted epoch. During the overlap the ring still
  /// *accepts* the previous epoch ([admissibleKeys]) but never *emits*
  /// under it — new material carries the new epoch from the moment of
  /// rotation, so the population converges on the new key while nothing
  /// already in flight breaks.
  RelayKeyEpoch get emissionEpoch => _current;

  /// The one validity authority: whether material stamped with [epoch]
  /// is acceptable right now.
  ///
  /// A record carries only its epoch identifier — never an expiry of its
  /// own. A per-record expiry field was considered and rejected: each
  /// record would then hold its own clock opinion, and validity would
  /// have two authorities able to disagree. Instead every "is this still
  /// good?" question funnels here, and the answer is derived from ring
  /// state alone: acceptable means the current epoch, or the previous
  /// epoch while its overlap window is still open.
  bool acceptsEpoch(int epoch) {
    if (epoch == _current.epoch) return true;
    final previous = _previous;
    return previous != null && epoch == previous.epoch && previousInGrace;
  }

  /// Rotates one epoch forward: promotes `next` to `current`, demotes
  /// `current` to `previous`, and installs [freshNext] as the newly
  /// staged `next`.
  ///
  /// The incoming epoch begins while the outgoing one is still valid —
  /// their validity windows overlap by [gracePeriod]. That overlap is the
  /// point of staged rotation: a rotation must never invalidate a
  /// connection already in flight, so the outgoing key keeps verifying
  /// arrivals ([admissibleKeys]) while everything newly produced already
  /// uses the promoted key ([emissionEpoch]).
  ///
  /// Time comes from `clock.now()` (package:clock), so a test drives a
  /// full rotate-overlap-retire cycle under `withClock` without waiting.
  void rotate({required KeyPairBytes freshNext}) {
    final promoted = _next;
    if (promoted == null) {
      throw const KeyRotationError('no next key staged; call stageNext first');
    }
    _previous = _current;
    _current = promoted;
    _next = RelayKeyEpoch(epoch: promoted.epoch + 1, keyPair: freshNext);
    _rotatedAt = clock.now();
  }

  /// Installs a `next` key without rotating, for a ring built without one.
  void stageNext(KeyPairBytes keyPair) {
    _next = RelayKeyEpoch(epoch: _current.epoch + 1, keyPair: keyPair);
  }

  /// Drops the previous epoch once its overlap window has closed.
  /// Idempotent; returns true when a key was actually retired.
  ///
  /// This is the history bound. The ring retains at most ONE past epoch,
  /// and only for [gracePeriod] after the rotation that demoted it. Past
  /// the overlap it is dropped — explicitly here, or implicitly by the
  /// next [rotate] overwriting the `previous` slot. Old epochs therefore
  /// never accumulate: whatever the rotation count, the ring holds at
  /// most [maxKeys] entries (previous + current + next), and
  /// [acceptsEpoch] answers false for anything older.
  bool retireExpired() {
    if (_previous == null || previousInGrace) return false;
    _previous = null;
    return true;
  }

  /// Distribution: what a peer receives in order to learn a new epoch —
  /// the current epoch number with its public key, plus the staged next
  /// epoch and its key so the peer can pre-fetch before the rotation
  /// lands. Public material only; private keys never leave the ring.
  ///
  /// What this file deliberately does NOT do: it does not fetch, push, or
  /// deliver this announcement anywhere, and it does not decide when to
  /// publish it. Transport and publication policy belong to whoever owns
  /// the transport. The one delivery this library does define,
  /// [RelayKeyUpdate], rides a channel the handshake has already
  /// authenticated.
  RelayKeyAnnouncement get announcement => RelayKeyAnnouncement(
    currentEpoch: _current.epoch,
    currentPublicKey: _current.publicKey,
    nextEpoch: _next?.epoch,
    nextPublicKey: _next?.publicKey,
  );
}

/// What a relay publishes about its keys. Contains public keys only.
class RelayKeyAnnouncement {
  const RelayKeyAnnouncement({
    required this.currentEpoch,
    required this.currentPublicKey,
    this.nextEpoch,
    this.nextPublicKey,
  });

  final int currentEpoch;
  final Uint8List currentPublicKey;
  final int? nextEpoch;
  final Uint8List? nextPublicKey;
}

/// The result of a rotating admission decision.
class EpochAdmission {
  const EpochAdmission({
    required this.decision,
    this.epoch,
    this.keyUpdateRequired = false,
    this.keysTried = 0,
  });

  final RealityDecision decision;

  /// Which epoch's key authenticated this client, or null when none did.
  final int? epoch;

  /// True when the client authenticated under the *previous* key. It is
  /// still admitted — that is what zero-downtime means — but it should be
  /// sent a [RelayKeyUpdate] so its next connection uses the current key.
  final bool keyUpdateRequired;

  /// How many ring keys were tried. Bounded by [RelayKeyRing.maxKeys].
  final int keysTried;

  bool get admitted => decision.admitted;
}

/// Admission control over a rotating key ring.
///
/// Shares one long-lived [RealityAuthenticator] for clock-skew and replay
/// bookkeeping across every epoch, so a rotation never resets replay
/// memory — the same mistake that a fresh-authenticator-per-connection
/// implementation made before, caught by a replay test.
class RotatingRealityAuthenticator {
  RotatingRealityAuthenticator({
    required this.ring,
    KeyAgreement? agreement,
    RealityAuthenticator? replayGuard,
  }) : _agreement = agreement ?? X25519KeyAgreement(),
       _guard = replayGuard ?? RealityAuthenticator(credentials: const []);

  final RelayKeyRing ring;
  final KeyAgreement _agreement;
  final RealityAuthenticator _guard;

  int get currentTimeSlot => _guard.currentTimeSlot;

  /// Decides on one hello, trying each admissible key in turn.
  Future<EpochAdmission> inspect(TlsClientHello hello) async {
    if (hello.sessionId.length != RealitySessionIdLayout.totalLength) {
      return EpochAdmission(
        decision: RealityDecision.passThrough(
          RealityRejectReason.sessionIdWrongSize,
          hello: hello,
        ),
      );
    }

    final share = RealityKeyExchangeAuthenticator.clientX25519Share(hello);
    if (share == null) {
      return EpochAdmission(
        decision: RealityDecision.passThrough(
          RealityRejectReason.unknownShortId,
          hello: hello,
        ),
      );
    }

    final presentedShortId = Uint8List.sublistView(
      hello.sessionId,
      0,
      RealitySessionIdLayout.shortIdLength,
    );

    var tried = 0;
    for (final key in ring.admissibleKeys) {
      tried++;
      final Uint8List shared;
      try {
        shared = await _agreement.sharedSecret(
          privateKey: key.keyPair.privateKey,
          peerPublicKey: share,
        );
      } catch (_) {
        continue;
      }
      final credential = RealityCredential.fromSharedSecret(shared);
      if (!constantTimeEquals(credential.shortId, presentedShortId)) {
        continue;
      }
      // The short id matched this epoch's key; the tag, clock skew, and
      // replay checks are the shared verifier's job.
      final decision = _guard.verifyWith(hello, credential);
      return EpochAdmission(
        decision: decision,
        epoch: decision.admitted ? key.epoch : null,
        keyUpdateRequired: decision.admitted && key.epoch != ring.current.epoch,
        keysTried: tried,
      );
    }

    return EpochAdmission(
      decision: RealityDecision.passThrough(
        RealityRejectReason.unknownShortId,
        hello: hello,
      ),
      keysTried: tried,
    );
  }
}

/// Tells an admitted client which static key to use from now on.
///
/// Sent on the channel the handshake just established, so its authenticity
/// comes from that channel rather than from a signature of its own — the
/// client has already proven it derived the same secret, and nobody else
/// can write to this stream. A key update carried on an *unauthenticated*
/// path would need its own signature; this one does not, and the
/// distinction is the reason it is defined here rather than in the hello.
///
/// Wire format, sharing the framing shape of [RealityIdentityProof]:
///
/// ```text
///   [0]      type    = 0x02 (relay_key_update)
///   [1]      version = 0x01
///   [2..4)   body length, u16 big-endian = 36
///   [4..8)   epoch, u32 big-endian
///   [8..40)  X25519 static public key (32 bytes)
/// ```
class RelayKeyUpdate {
  const RelayKeyUpdate({required this.epoch, required this.publicKey});

  final int epoch;

  /// The static X25519 public key for [epoch].
  final Uint8List publicKey;

  static const int frameType = 0x02;
  static const int frameVersion = 0x01;
  static const int headerLength = 4;
  static const int publicKeyLength = 32;
  static const int bodyLength = 4 + publicKeyLength;
  static const int frameLength = headerLength + bodyLength;

  /// The update a relay should send to a client admitted on an old key.
  factory RelayKeyUpdate.forRing(RelayKeyRing ring) => RelayKeyUpdate(
    epoch: ring.current.epoch,
    publicKey: ring.current.publicKey,
  );

  Uint8List encode() {
    final frame = Uint8List(frameLength);
    frame[0] = frameType;
    frame[1] = frameVersion;
    final view = ByteData.sublistView(frame);
    view.setUint16(2, bodyLength);
    view.setUint32(headerLength, epoch);
    frame.setRange(headerLength + 4, frameLength, publicKey);
    return frame;
  }

  factory RelayKeyUpdate.decode(Uint8List frame) {
    if (frame.length < frameLength) {
      throw FormatException(
        'key update needs $frameLength bytes, got ${frame.length}',
      );
    }
    if (frame[0] != frameType) {
      throw FormatException(
        'frame type 0x${frame[0].toRadixString(16)} is not a key update',
      );
    }
    if (frame[1] != frameVersion) {
      throw FormatException('unsupported key-update version ${frame[1]}');
    }
    final view = ByteData.sublistView(frame);
    final declared = view.getUint16(2);
    if (declared != bodyLength) {
      throw FormatException(
        'key update declares $declared body bytes, expected $bodyLength',
      );
    }
    return RelayKeyUpdate(
      epoch: view.getUint32(headerLength),
      publicKey: Uint8List.sublistView(frame, headerLength + 4, frameLength),
    );
  }
}

/// Client-side holder of the relay's static key, updated in place when the
/// relay says the client is behind.
class RelayKeyStore {
  RelayKeyStore({required Uint8List publicKey, required this.epoch})
    : _publicKey = Uint8List.fromList(publicKey);

  Uint8List _publicKey;
  int epoch;

  Uint8List get publicKey => _publicKey;

  /// Applies [update], ignoring one that is not newer.
  ///
  /// Rejecting a backwards update matters: an attacker who could replay an
  /// old key-update frame would otherwise pin a client to a retired key.
  bool apply(RelayKeyUpdate update) {
    if (update.epoch <= epoch) return false;
    _publicKey = Uint8List.fromList(update.publicKey);
    epoch = update.epoch;
    return true;
  }
}
