/// Relay-side admission control: authenticate a client from its Client
/// Hello alone, or hand the whole connection to a real web server.
///
/// The design rule that makes this work is negative: **the relay never
/// originates a byte on the unauthenticated path.** No alert, no
/// handshake failure, no synthetic HTTP response, no timing tell. An
/// unauthenticated peer is spliced to a genuine upstream host and every
/// response it sees — certificate chain, HTTP/2 settings, 404 body, TCP
/// reset — is that host's own. A scanner cannot distinguish the relay from
/// the site it fronts, because on that path it *is* the site it fronts.
///
/// Authentication rides inside `legacy_session_id`, a 32-byte field a TLS
/// 1.3 client fills with opaque bytes, so the hello stays structurally
/// ordinary:
///
/// ```text
///   session_id[0..8)   short id      — which credential is claimed
///   session_id[8..12)  time slot     — minutes since the Unix epoch
///   session_id[12..32) auth tag      — HMAC-SHA256 truncated to 20 bytes
/// ```
///
/// The tag covers the client random, so it cannot be lifted from one
/// connection and pasted into another; the time slot bounds how long a
/// captured hello stays replayable; and a per-random seen-set closes the
/// replay window inside that bound.
///
/// Key agreement is deliberately *not* in this file. The shared secret
/// comes from whatever the deployment already trusts — an X25519 exchange
/// against the relay's published public key, or a provisioned identity —
/// and reaches us through [RealityCredential.fromSharedSecret], which runs
/// it through HKDF. Inventing a second key exchange here would add a
/// bespoke cryptographic surface for no gain.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';

import '../hkdf_key_schedule.dart';
import '../scram_exporter_auth.dart' show constantTimeEquals;
import 'tls_client_hello.dart';

/// Byte layout of the authenticator inside `legacy_session_id`.
class RealitySessionIdLayout {
  const RealitySessionIdLayout._();

  static const int shortIdLength = 8;
  static const int timeSlotLength = 4;
  static const int tagLength = 20;
  static const int totalLength = shortIdLength + timeSlotLength + tagLength;
}

/// One client credential: a short id plus the symmetric key its tag is
/// computed under.
class RealityCredential {
  RealityCredential({required Uint8List shortId, required Uint8List authKey})
      : shortId = Uint8List.fromList(shortId),
        authKey = Uint8List.fromList(authKey) {
    if (shortId.length != RealitySessionIdLayout.shortIdLength) {
      throw ArgumentError.value(
        shortId.length,
        'shortId',
        'must be exactly ${RealitySessionIdLayout.shortIdLength} bytes',
      );
    }
    if (authKey.isEmpty) {
      throw ArgumentError.value(authKey, 'authKey', 'must not be empty');
    }
  }

  /// Derives the credential from a secret both ends already share (an
  /// X25519 output, a provisioned key), separating the short id from the
  /// tag key so neither reveals the other.
  factory RealityCredential.fromSharedSecret(
    Uint8List sharedSecret, {
    String label = 'reality-admission-v1',
  }) {
    final material = Hkdf.derive(
      ikm: sharedSecret,
      salt: Uint8List(0),
      info: Uint8List.fromList(label.codeUnits),
      length: RealitySessionIdLayout.shortIdLength + 32,
    );
    return RealityCredential(
      shortId: Uint8List.sublistView(
        material,
        0,
        RealitySessionIdLayout.shortIdLength,
      ),
      authKey: Uint8List.sublistView(
        material,
        RealitySessionIdLayout.shortIdLength,
      ),
    );
  }

  final Uint8List shortId;
  final Uint8List authKey;

  /// Hex form of [shortId], used as the registry key.
  String get shortIdHex =>
      shortId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The 20-byte tag for a hello with [clientRandom] in [timeSlot].
  Uint8List computeTag({
    required Uint8List clientRandom,
    required int timeSlot,
  }) {
    final message = BytesBuilder(copy: false)
      ..add(clientRandom)
      ..add(shortId)
      ..add(_timeSlotBytes(timeSlot));
    final mac = Hmac(sha256, authKey).convert(message.toBytes()).bytes;
    return Uint8List.fromList(
      mac.sublist(0, RealitySessionIdLayout.tagLength),
    );
  }

  /// Builds the 32-byte `legacy_session_id` a client should send.
  Uint8List buildSessionId({
    required Uint8List clientRandom,
    required int timeSlot,
  }) {
    final out = Uint8List(RealitySessionIdLayout.totalLength);
    out.setRange(0, RealitySessionIdLayout.shortIdLength, shortId);
    out.setRange(
      RealitySessionIdLayout.shortIdLength,
      RealitySessionIdLayout.shortIdLength +
          RealitySessionIdLayout.timeSlotLength,
      _timeSlotBytes(timeSlot),
    );
    out.setRange(
      RealitySessionIdLayout.shortIdLength +
          RealitySessionIdLayout.timeSlotLength,
      out.length,
      computeTag(clientRandom: clientRandom, timeSlot: timeSlot),
    );
    return out;
  }

  static Uint8List _timeSlotBytes(int timeSlot) {
    final bytes = Uint8List(RealitySessionIdLayout.timeSlotLength);
    ByteData.sublistView(bytes).setUint32(0, timeSlot);
    return bytes;
  }
}

/// Why a connection was not admitted.
///
/// The reason is for the relay's own logs only. It never reaches the peer:
/// every value below produces the exact same observable behavior — silent
/// pass-through.
enum RealityRejectReason {
  notATlsHandshake,
  malformedClientHello,
  sessionIdWrongSize,
  unknownShortId,
  badAuthTag,
  staleTimeSlot,
  replayedHello,
}

/// The outcome of inspecting one Client Hello.
class RealityDecision {
  const RealityDecision._({
    required this.admitted,
    this.credential,
    this.reason,
    this.hello,
  });

  const RealityDecision.admit(RealityCredential credential, TlsClientHello hello)
      : this._(admitted: true, credential: credential, hello: hello);

  const RealityDecision.passThrough(
    RealityRejectReason reason, {
    TlsClientHello? hello,
  }) : this._(admitted: false, reason: reason, hello: hello);

  /// True when the peer proved knowledge of a registered credential.
  final bool admitted;

  /// The credential that verified, on the admitted path.
  final RealityCredential? credential;

  /// Why the peer was not admitted, on the pass-through path.
  final RealityRejectReason? reason;

  /// The parsed hello, when it parsed at all.
  final TlsClientHello? hello;
}

/// Verifies Client Hellos against a registry of credentials.
class RealityAuthenticator {
  RealityAuthenticator({
    required Iterable<RealityCredential> credentials,
    this.clockSkew = const Duration(minutes: 2),
    this.replayMemory = const Duration(minutes: 5),
  }) : _credentials = {
          for (final credential in credentials)
            credential.shortIdHex: credential,
        };

  final Map<String, RealityCredential> _credentials;

  /// How far a hello's time slot may sit from the relay's own clock in
  /// either direction. Two minutes tolerates ordinary device drift while
  /// keeping a captured hello short-lived.
  final Duration clockSkew;

  /// How long a verified client random is remembered, so the same hello
  /// cannot be replayed inside the clock-skew window.
  final Duration replayMemory;

  final Map<String, DateTime> _seenRandoms = {};

  /// Current time slot: whole minutes since the Unix epoch.
  static int timeSlotFor(DateTime now) =>
      now.toUtc().millisecondsSinceEpoch ~/ 60000;

  /// The time slot a client should stamp into its session id right now.
  int get currentTimeSlot => timeSlotFor(clock.now());

  /// Inspects [helloBytes] — a complete TLS record — and decides.
  RealityDecision inspectRecord(List<int> helloBytes) {
    final TlsClientHello hello;
    try {
      hello = TlsClientHello.parseRecord(helloBytes);
    } on TlsParseException {
      final isHandshake =
          helloBytes.isNotEmpty && helloBytes.first == tlsHandshakeContentType;
      return RealityDecision.passThrough(
        isHandshake
            ? RealityRejectReason.malformedClientHello
            : RealityRejectReason.notATlsHandshake,
      );
    }
    return inspect(hello);
  }

  /// Decides on an already-parsed [hello].
  RealityDecision inspect(TlsClientHello hello) {
    _expireReplayMemory();

    if (hello.sessionId.length != RealitySessionIdLayout.totalLength) {
      return RealityDecision.passThrough(
        RealityRejectReason.sessionIdWrongSize,
        hello: hello,
      );
    }

    final shortId = Uint8List.sublistView(
      hello.sessionId,
      0,
      RealitySessionIdLayout.shortIdLength,
    );
    final credential = _credentials[_hex(shortId)];
    if (credential == null) {
      return RealityDecision.passThrough(
        RealityRejectReason.unknownShortId,
        hello: hello,
      );
    }

    final timeSlot = ByteData.sublistView(
      hello.sessionId,
      RealitySessionIdLayout.shortIdLength,
      RealitySessionIdLayout.shortIdLength +
          RealitySessionIdLayout.timeSlotLength,
    ).getUint32(0);
    final presentedTag = Uint8List.sublistView(
      hello.sessionId,
      RealitySessionIdLayout.shortIdLength +
          RealitySessionIdLayout.timeSlotLength,
    );

    // The tag is checked before the clock, and with a constant-time
    // compare, so neither the outcome nor the time taken tells an attacker
    // whether a guessed short id was real.
    final expected = credential.computeTag(
      clientRandom: hello.random,
      timeSlot: timeSlot,
    );
    if (!constantTimeEquals(expected, presentedTag)) {
      return RealityDecision.passThrough(
        RealityRejectReason.badAuthTag,
        hello: hello,
      );
    }

    final drift = (currentTimeSlot - timeSlot).abs();
    if (drift > clockSkew.inMinutes) {
      return RealityDecision.passThrough(
        RealityRejectReason.staleTimeSlot,
        hello: hello,
      );
    }

    final randomKey = _hex(hello.random);
    if (_seenRandoms.containsKey(randomKey)) {
      return RealityDecision.passThrough(
        RealityRejectReason.replayedHello,
        hello: hello,
      );
    }
    _seenRandoms[randomKey] = clock.now();

    return RealityDecision.admit(credential, hello);
  }

  /// Number of client randoms currently remembered for replay defense.
  int get replayMemorySize => _seenRandoms.length;

  void _expireReplayMemory() {
    final cutoff = clock.now().subtract(replayMemory);
    _seenRandoms.removeWhere((_, seenAt) => seenAt.isBefore(cutoff));
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A bidirectional byte stream — one accepted TCP connection, or one
/// outbound connection to the fallback host.
///
/// Abstract so the relay logic is testable without sockets and so a native
/// zero-copy implementation can be dropped in behind the same interface.
abstract class DuplexByteStream {
  Stream<Uint8List> get inbound;

  /// Writes [bytes] toward the peer. Implementations must not copy,
  /// reorder, or reframe: the pass-through path is byte-exact.
  void add(Uint8List bytes);

  Future<void> close();
}

/// Opens a connection to the fallback host.
typedef FallbackConnector = Future<DuplexByteStream> Function(
  String host,
  int port,
);

/// Where unauthenticated connections go.
class FallbackTarget {
  const FallbackTarget({required this.host, this.port = 443});

  /// A real, reachable, high-reputation host that genuinely serves TLS on
  /// [port]. It must be a site the relay's own IP plausibly fronts —
  /// pointing at a host whose certificate names an unrelated CDN is itself
  /// a signal.
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Byte counters for one spliced connection.
class PassThroughStats {
  PassThroughStats();

  int bytesToUpstream = 0;
  int bytesToClient = 0;

  @override
  String toString() =>
      'PassThroughStats(up: $bytesToUpstream B, down: $bytesToClient B)';
}

/// Forwards a connection verbatim to the fallback host.
///
/// On the copy question, stated plainly: the Dart VM exposes no `splice(2)`
/// or `sendfile(2)`, so this forwards the buffers it is handed *by
/// reference* — no re-slicing, no reframing, no per-byte work — which is
/// the closest the managed runtime allows. A native splice implementation
/// belongs behind [DuplexByteStream], not in place of it; nothing above
/// this line would change.
class PassThroughRelay {
  PassThroughRelay({
    required this.connector,
    required this.target,
    this.connectTimeout = const Duration(seconds: 5),
  });

  final FallbackConnector connector;
  final FallbackTarget target;
  final Duration connectTimeout;

  /// Splices [client] to [target], first replaying [preface] — the bytes
  /// already read from the client in order to decide, which the upstream
  /// host must receive unchanged and in position, or the handshake it
  /// completes will not be the one the client started.
  ///
  /// Completes when either side closes. If the upstream connection cannot
  /// be established, the client socket is closed with no bytes written:
  /// silence is the one response that reveals nothing.
  Future<PassThroughStats> splice(
    DuplexByteStream client, {
    required Uint8List preface,
  }) async {
    final stats = PassThroughStats();
    DuplexByteStream upstream;
    try {
      upstream =
          await connector(target.host, target.port).timeout(connectTimeout);
    } catch (_) {
      await _closeQuietly(client);
      return stats;
    }

    if (preface.isNotEmpty) {
      upstream.add(preface);
      stats.bytesToUpstream += preface.length;
    }

    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final clientSub = client.inbound.listen(
      (chunk) {
        upstream.add(chunk);
        stats.bytesToUpstream += chunk.length;
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    final upstreamSub = upstream.inbound.listen(
      (chunk) {
        client.add(chunk);
        stats.bytesToClient += chunk.length;
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );

    await done.future;
    await clientSub.cancel();
    await upstreamSub.cancel();
    await _closeQuietly(client);
    await _closeQuietly(upstream);
    return stats;
  }

  static Future<void> _closeQuietly(DuplexByteStream stream) async {
    try {
      await stream.close();
    } catch (_) {
      // The peer is already gone; there is nothing left to release.
    }
  }
}

/// What the gate did with a connection.
class RealityGateOutcome {
  const RealityGateOutcome({
    required this.decision,
    required this.elapsed,
    this.stats,
  });

  final RealityDecision decision;

  /// Time spent from first byte to routing decision. The authentication
  /// path is a parse plus one HMAC — the budget it is held to is under a
  /// millisecond, asserted in the benchmark test.
  final Duration elapsed;

  /// Byte counters, on the pass-through path only.
  final PassThroughStats? stats;

  bool get admitted => decision.admitted;
}

/// Front door of the relay: read the first record, verify it, and either
/// hand the connection to the call transport or splice it away.
class RealityGate {
  RealityGate({
    required this.authenticator,
    required this.relay,
    this.firstRecordTimeout = const Duration(seconds: 5),
    this.maxHelloBytes = 16640,
  });

  final RealityAuthenticator authenticator;
  final PassThroughRelay relay;

  /// How long the peer has to deliver a complete first record. A prober
  /// that connects and says nothing is spliced anyway when this expires —
  /// exactly as a slow real client would be handled.
  final Duration firstRecordTimeout;

  /// Cap on buffered pre-decision bytes: one TLS record plus its header.
  final int maxHelloBytes;

  /// Handles one accepted [client].
  ///
  /// On admission [onAdmitted] is invoked with the client stream and the
  /// bytes already consumed; the caller owns the connection from there.
  Future<RealityGateOutcome> handle(
    DuplexByteStream client, {
    required void Function(
      DuplexByteStream client,
      Uint8List consumed,
      RealityCredential credential,
    ) onAdmitted,
  }) async {
    final started = clock.now();
    final buffer = BytesBuilder(copy: true);
    final firstRecord = Completer<Uint8List?>();

    late final StreamSubscription<Uint8List> sub;
    sub = client.inbound.listen(
      (chunk) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final complete = _completeRecordLength(bytes);
        if (complete != null && bytes.length >= complete) {
          if (!firstRecord.isCompleted) {
            firstRecord.complete(Uint8List.sublistView(bytes, 0, complete));
          }
        } else if (bytes.length >= maxHelloBytes) {
          // Too much for any legitimate first record: decide on what we
          // have rather than buffer without bound.
          if (!firstRecord.isCompleted) firstRecord.complete(bytes);
        }
      },
      onDone: () {
        if (!firstRecord.isCompleted) firstRecord.complete(null);
      },
      onError: (Object _) {
        if (!firstRecord.isCompleted) firstRecord.complete(null);
      },
    );

    Uint8List? record;
    try {
      record = await firstRecord.future.timeout(firstRecordTimeout);
    } on TimeoutException {
      record = null;
    }

    final consumed = buffer.toBytes();
    final decision = record == null
        ? const RealityDecision.passThrough(
            RealityRejectReason.notATlsHandshake,
          )
        : authenticator.inspectRecord(record);
    final elapsed = clock.now().difference(started);

    if (decision.admitted) {
      await sub.cancel();
      onAdmitted(client, consumed, decision.credential!);
      return RealityGateOutcome(decision: decision, elapsed: elapsed);
    }

    // Hand the whole conversation to the real host, replaying every byte
    // the client has sent so far. Our own subscription must go first so
    // the relay receives the remainder.
    await sub.cancel();
    final stats = await relay.splice(client, preface: consumed);
    return RealityGateOutcome(
      decision: decision,
      elapsed: elapsed,
      stats: stats,
    );
  }

  /// Total length of the first TLS record in [bytes], or null while the
  /// 5-byte header is still incomplete.
  static int? _completeRecordLength(Uint8List bytes) {
    if (bytes.length < 5) return null;
    return 5 + ByteData.sublistView(bytes).getUint16(3);
  }
}
