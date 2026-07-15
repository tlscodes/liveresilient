/// Pure mapping between `call_core`'s [SignalingCommand]/[SignalingEvent]
/// types and the wire-level `(SignalType, payload)` pairs `signaling`
/// exchanges.
///
/// Both directions are pure functions with no I/O:
/// - [encodeCommand] never fails — every [SignalingCommand] `call_core` can
///   construct is representable on the wire.
/// - [decodeInbound] NEVER throws on malformed remote data; a payload that
///   doesn't decode cleanly returns `null` and the caller drops it. Remote
///   input is untrusted by construction.
library;

import 'package:call_core/call_core.dart';
import 'package:signaling/signaling.dart';

/// Encodes an outgoing [SignalingCommand] into the `(type, payload)` pair
/// `SignalingGateway.send` expects.
(SignalType, Map<String, Object?>) encodeCommand(SignalingCommand command) {
  switch (command) {
    case SendDescriptionCommand(:final description):
      final type = description.type == SessionDescriptionType.offer
          ? SignalType.offer
          : SignalType.answer;
      return (type, {'type': description.type.name, 'sdp': description.sdp});

    case SendIceCandidateCommand(:final candidate):
      return (
        SignalType.iceCandidate,
        {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      );

    case SendHangupCommand(:final reason):
      return (
        SignalType.callControl,
        {'action': 'hangup', if (reason != null) 'reason': reason},
      );

    case SendRestartRequestCommand():
      return (SignalType.callControl, const {'action': 'restartRequest'});
  }
}

/// Decodes an inbound `(type, payload)` pair into a [SignalingEvent].
///
/// Returns `null` when the payload is malformed or the type is not
/// meaningful at this layer (`ack`/`heartbeat` are consumed internally by
/// `SignalingClient` and never reach here in practice, but are handled
/// defensively). An unknown `callControl` action is forward-compatible and
/// is ignored (returns `null`), never treated as an error.
SignalingEvent? decodeInbound(SignalType type, Map<String, Object?> payload) {
  switch (type) {
    case SignalType.offer:
    case SignalType.answer:
      return _decodeDescription(type, payload);

    case SignalType.iceCandidate:
      return _decodeIceCandidate(payload);

    case SignalType.callControl:
      return _decodeCallControl(payload);

    case SignalType.ack:
    case SignalType.heartbeat:
      return null;
  }
}

SignalingEvent? _decodeDescription(
  SignalType type,
  Map<String, Object?> payload,
) {
  final sdp = payload['sdp'];
  if (sdp is! String) return null;
  final descriptionType = type == SignalType.offer
      ? SessionDescriptionType.offer
      : SessionDescriptionType.answer;
  try {
    return RemoteDescriptionEvent(
      SessionDescription(type: descriptionType, sdp: sdp),
    );
  } on ArgumentError {
    return null;
  }
}

SignalingEvent? _decodeIceCandidate(Map<String, Object?> payload) {
  final candidate = payload['candidate'];
  final sdpMid = payload['sdpMid'];
  final sdpMLineIndex = payload['sdpMLineIndex'];
  if (candidate != null && candidate is! String) return null;
  if (sdpMid != null && sdpMid is! String) return null;
  if (sdpMLineIndex != null && sdpMLineIndex is! int) return null;
  try {
    return RemoteIceCandidateEvent(
      IceCandidate(
        candidate: candidate as String?,
        sdpMid: sdpMid as String?,
        sdpMLineIndex: sdpMLineIndex as int?,
      ),
    );
  } on ArgumentError {
    return null;
  }
}

SignalingEvent? _decodeCallControl(Map<String, Object?> payload) {
  final action = payload['action'];
  if (action is! String) return null;
  switch (action) {
    case 'hangup':
      final reason = payload['reason'];
      if (reason != null && reason is! String) return null;
      try {
        return RemoteHangupEvent(reason as String?);
      } on ArgumentError {
        return null;
      }
    case 'restartRequest':
      return const RestartRequestedEvent();
    default:
      // Forward-compatible: unrecognized control actions are ignored, not
      // treated as an error.
      return null;
  }
}
