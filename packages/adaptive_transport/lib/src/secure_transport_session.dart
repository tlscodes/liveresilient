import 'dart:typed_data';

import 'authenticated_relay_server.dart';
import 'path_validation.dart';

/// Thrown when a wire datagram fails the session's anti-replay admission.
class ReplayedDatagramException implements Exception {
  ReplayedDatagramException(this.sequence);
  final int sequence;
  @override
  String toString() => 'ReplayedDatagramException: sequence $sequence '
      'was already admitted or is stale';
}

/// Binds an established [MutualRelaySession] to the datagram path: every
/// outgoing datagram is prefixed with a u48 sequence number, every incoming
/// one must clear the session's counter+bitmap replay window before its
/// payload is released, and path migration helpers are keyed to the session's
/// CURRENT epoch key so a rotated session invalidates old challenges and
/// continuity tokens automatically.
class SecureTransportSession {
  SecureTransportSession({required MutualRelaySession session})
      : _session = session;

  final MutualRelaySession _session;

  int _nextSequence = 0;
  static const int _headerLength = 6; // u48 big-endian sequence

  String get sessionId => _session.sessionId;
  int get keyEpoch => _session.keyEpoch;
  int get nextSequence => _nextSequence;

  /// Bytes of framing this layer adds per datagram.
  static const int overheadBytes = _headerLength;

  /// Prefixes [datagram] with the next sequence number. u48 gives 2^48
  /// datagrams per session — at 1000 datagrams/s that is ~8900 years, so the
  /// counter never wraps within a call.
  Uint8List seal(Uint8List datagram) {
    final seq = _nextSequence++;
    final out = Uint8List(_headerLength + datagram.length);
    out[0] = (seq >> 40) & 0xff;
    out[1] = (seq >> 32) & 0xff;
    out[2] = (seq >> 24) & 0xff;
    out[3] = (seq >> 16) & 0xff;
    out[4] = (seq >> 8) & 0xff;
    out[5] = seq & 0xff;
    out.setRange(_headerLength, out.length, datagram);
    return out;
  }

  /// Strips and checks the sequence header. Throws [ReplayedDatagramException]
  /// when the replay window rejects it; also advances the key-rotation budget
  /// for every admitted datagram.
  Uint8List open(Uint8List wire) {
    if (wire.length < _headerLength) {
      throw ArgumentError.value(wire.length, 'wire', 'shorter than the header');
    }
    final seq = (wire[0] << 40) |
        (wire[1] << 32) |
        (wire[2] << 24) |
        (wire[3] << 16) |
        (wire[4] << 8) |
        wire[5];
    if (!_session.admitMessage(seq)) {
      throw ReplayedDatagramException(seq);
    }
    return Uint8List.sublistView(wire, _headerLength);
  }

  /// A path validator keyed to the CURRENT epoch's traffic key. Mint it fresh
  /// at each migration; after a key rotation old validators stop matching.
  PathValidator newPathValidator() =>
      PathValidator(sessionKey: _session.trafficKey);

  /// Continuity token for re-attaching this session on a new endpoint without
  /// a full SCRAM re-handshake. Bound to session id + current epoch.
  Uint8List mintContinuityToken() =>
      SessionContinuityToken(sessionKey: _session.trafficKey)
          .mint(sessionId: _session.sessionId, epoch: _session.keyEpoch);

  /// Server-side check of a presented continuity token against the session's
  /// current epoch.
  bool verifyContinuityToken(Uint8List token) =>
      SessionContinuityToken(sessionKey: _session.trafficKey).verify(
        sessionId: _session.sessionId,
        epoch: _session.keyEpoch,
        token: token,
      );
}
