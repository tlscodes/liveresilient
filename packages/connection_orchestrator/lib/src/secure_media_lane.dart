/// The modern assembly of the whole phase 7+8 transport stack as ONE fabric
/// lane. Before this file, the pieces (racer, path validation, SCRAM mutual
/// auth, channel framing, anti-replay sealing) existed and were tested but no
/// live path composed them end-to-end; [ConnectionFabric] lanes carried raw
/// bytes. [SecureMediaLane.establish] runs the full modern connection recipe
/// and the result plugs into `ConnectionFabric.registerLane` (or
/// `buildIntelligence(primaryLane: ...)`) unchanged:
///
///  1. RFC 8305 staggered racing across endpoints (first success wins,
///     losers' connections are closed);
///  2. SCRAM mutual authentication (RFC 5802) channel-bound to the
///     connection's TLS exporter (RFC 8446 section 7.5);
///  3. QUIC-style path validation before any media rides the new path;
///  4. TURN ChannelData framing (RFC 8656) as the outermost wire layer;
///  5. every datagram sealed with the session's sequence header —
///     replayed datagrams throw before reaching the application.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

/// What [SecureMediaLane] needs from one dialed connection. The app supplies
/// the real socket + handshake broker; tests supply an in-memory peer.
abstract class SecureLaneConnection {
  /// TLS 1.3 exporter value of THIS connection (RFC 8446 section 7.5,
  /// [tlsExporterLength] bytes). Every credential is bound to it.
  Uint8List get tlsExporter;

  /// Server half of the SCRAM exchange: given the client-first parameters,
  /// returns the server nonce, salt and iteration count.
  Future<({String serverNonce, Uint8List salt, int iterations})> startAuth(
    String username,
    String clientNonce,
  );

  /// Submits the client proof; returns the server signature on success or
  /// null when the server rejected the credentials.
  Future<Uint8List?> finishAuth(Uint8List clientProof);

  /// The peer's answer to a path-validation challenge (HMAC under the
  /// session key the peer derived from the same handshake).
  Future<Uint8List> answerPathChallenge(Uint8List challenge);

  /// Ships one wire datagram (already framed and sealed).
  Future<void> sendDatagram(Uint8List frame);

  /// Closes the underlying connection (used for race losers too).
  Future<void> close();
}

/// Raised when [SecureMediaLane.establish] connected but could not complete
/// mutual authentication or path validation.
class LaneEstablishmentException implements Exception {
  LaneEstablishmentException(this.stage, this.endpoint);
  final String stage;
  final RelayEndpoint endpoint;
  @override
  String toString() => 'LaneEstablishmentException: $stage failed on $endpoint';
}

/// A fully secured, relay-framed transport lane. Implements
/// [TransportChannel], so [ConnectionFabric] ranks, probes and drains it like
/// any other lane while every byte gets the full phase 7+8 treatment.
class SecureMediaLane implements TransportChannel {
  SecureMediaLane._({
    required this.endpoint,
    required SecureLaneConnection connection,
    required SecureTransportSession session,
    required ChannelRelayLink relayLink,
    required DateTime Function() now,
    required Duration establishElapsed,
  }) : _connection = connection,
       _session = session,
       _relayLink = relayLink,
       _now = now,
       health = ChannelHealth(
         reliabilityPrior: 0.9,
         bandwidth: 0.7,
         // Seed RTT from the measured race-winner connect time instead of
         // the pessimistic default, so a freshly validated lane starts in
         // live mode rather than degraded.
         rttMs: establishElapsed.inMilliseconds.clamp(1, 2000),
       );

  /// Runs the full modern recipe over [endpoints] and returns a live lane.
  ///
  /// [randomBytes] supplies nonce/challenge material (length-parameterized so
  /// callers inject a CSPRNG in production and fixed bytes in tests).
  static Future<SecureMediaLane> establish({
    required List<RelayEndpoint> endpoints,
    required Future<SecureLaneConnection> Function(RelayEndpoint) dial,
    required String username,
    required String password,
    required Uint8List Function(int length) randomBytes,
    ChannelRelayBinder? binder,
    Duration connectionAttemptDelay = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) async {
    // 1. RFC 8305 race; a losing dial is closed, never leaked.
    final raced = await HappyEyeballsRacer<SecureLaneConnection>(
      endpoints: endpoints,
      connect: dial,
      connectionAttemptDelay: connectionAttemptDelay,
      // A losing dial is closed fire-and-forget, but its close() may
      // reject (socket already reset by the peer). Swallowing it here
      // keeps that from surfacing as an unhandled zone error that would
      // fail the whole establish() — the race winner is unaffected.
      discard: (loser) => unawaited(loser.close().catchError((_) {})),
    ).race();
    final connection = raced.connection;
    final endpoint = raced.endpoint;

    // 2. SCRAM mutual auth bound to this connection's TLS exporter.
    final clientNonce = _hexOf(randomBytes(12));
    final challenge = await connection.startAuth(username, clientNonce);
    final client = ScramClient(username: username, password: password);
    final proof = client.proof(
      clientNonce: clientNonce,
      serverNonce: challenge.serverNonce,
      salt: challenge.salt,
      iterations: challenge.iterations,
      channelBinding: connection.tlsExporter,
    );
    final serverSignature = await connection.finishAuth(proof);
    if (serverSignature == null ||
        !client.verifyServerSignature(serverSignature)) {
      await connection.close();
      throw LaneEstablishmentException('mutual authentication', endpoint);
    }

    // Derive the same session the server holds: the verifier is recomputed
    // from the password, so both ends ratchet identical traffic keys.
    final verifier = ScramVerifier.fromPassword(
      username: username,
      password: password,
      salt: challenge.salt,
      iterations: challenge.iterations,
    );
    final established = MutualRelaySession.establish(
      verifier: verifier,
      clientNonce: clientNonce,
      serverNonce: challenge.serverNonce,
      tlsExporter: connection.tlsExporter,
      clientProof: proof,
    );
    if (established == null) {
      await connection.close();
      throw LaneEstablishmentException('session derivation', endpoint);
    }
    final session = SecureTransportSession(session: established.session);

    // 3. Path validation: no media until the peer proved it holds the same
    //    session key ON THIS PATH.
    final validator = session.newPathValidator();
    final pathId = endpoint.hostPort.authority;
    final challengeBytes = validator.issueChallenge(pathId, randomBytes(8));
    final answer = await connection.answerPathChallenge(challengeBytes);
    if (!validator.validateResponse(pathId, answer)) {
      await connection.close();
      throw LaneEstablishmentException('path validation', endpoint);
    }

    // 4. TURN channel binding for the relayed wire format.
    final link = (binder ?? ChannelRelayBinder()).bind(endpoint.hostPort);

    return SecureMediaLane._(
      endpoint: endpoint,
      connection: connection,
      session: session,
      relayLink: link,
      now: now ?? DateTime.now,
      establishElapsed: raced.elapsed,
    );
  }

  final RelayEndpoint endpoint;
  final SecureLaneConnection _connection;
  final SecureTransportSession _session;
  final ChannelRelayLink _relayLink;
  final DateTime Function() _now;

  bool _disposed = false;

  @override
  String get name => 'secure-relay:${endpoint.hostPort.authority}';

  @override
  final ChannelHealth health;

  /// Sequence/framing state, exposed for telemetry.
  int get keyEpoch => _session.keyEpoch;
  int get channelNumber => _relayLink.channelNumber;

  /// Seals and frames [payload] exactly as it goes on the wire:
  /// ChannelData(seal(payload)). Public so a receiving peer/test can be fed
  /// the true wire bytes.
  Uint8List frame(List<int> payload) =>
      _relayLink.wrap(_session.seal(Uint8List.fromList(payload)));

  /// Reverses [frame] on the receiving side of a symmetric lane; a replayed
  /// wire datagram throws [ReplayedDatagramException].
  Uint8List unframe(Uint8List wire) => _session.open(_relayLink.unwrap(wire));

  @override
  Future<SendResult> send(List<int> payload) async {
    if (_disposed) {
      return const SendResult(SendStatus.unavailable);
    }
    final started = _now();
    try {
      await _connection.sendDatagram(frame(payload));
      final result = SendResult(
        SendStatus.ok,
        rttMs: _now().difference(started).inMilliseconds,
      );
      health.observe(result);
      return result;
    } on PermissionNotInstalledException catch (error) {
      final result = SendResult(SendStatus.unavailable, error: error);
      health.observe(result);
      return result;
    } catch (error) {
      final result = SendResult(SendStatus.transient, error: error);
      health.observe(result);
      return result;
    }
  }

  /// A real liveness probe: re-runs path validation, so a probe success
  /// means "the authenticated peer is still reachable on this path", not
  /// just "the socket exists".
  @override
  Future<bool> probe() async {
    if (_disposed) return false;
    try {
      final validator = _session.newPathValidator();
      final pathId = endpoint.hostPort.authority;
      final challenge = validator.issueChallenge(
        pathId,
        Uint8List.fromList(
          List.generate(8, (i) => (_now().microsecond + i) & 0xff),
        ),
      );
      final answer = await _connection.answerPathChallenge(challenge);
      final ok = validator.validateResponse(pathId, answer);
      if (!ok) health.pathDegraded = true;
      return ok;
    } catch (_) {
      health.pathDegraded = true;
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _connection.close();
  }

  static String _hexOf(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
