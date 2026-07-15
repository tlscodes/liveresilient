/// Versioned signaling envelope.
///
/// Every message exchanged with the signaling service is wrapped in a
/// [SignalEnvelope]: a small JSON structure with explicit versioning, a
/// unique message id (for at-least-once delivery and receiver-side
/// de-duplication), a per-sender sequence number (for ordering), and a typed
/// payload.
///
/// Designed from the v2 blueprint role (no v1 equivalent). Validation is
/// performed at runtime; malformed input throws [FormatException] rather
/// than tripping asserts.
library;

import 'dart:convert';
import 'dart:math';

/// Wire protocol version understood by this implementation.
const int signalProtocolVersion = 1;

/// Upper bound for a serialized envelope. Push wake-up paths and signaling
/// relays enforce small frames; anything larger must be renegotiated at the
/// application layer (e.g. SDP compaction), never chunked invisibly here.
const int maxEnvelopeBytes = 64 * 1024;

/// Message categories carried over signaling.
enum SignalType {
  /// SDP offer.
  offer,

  /// SDP answer.
  answer,

  /// Trickled ICE candidate.
  iceCandidate,

  /// Call lifecycle control (ring, accept, reject, hangup, busy).
  callControl,

  /// Delivery acknowledgement for a previously received envelope.
  ack,

  /// Liveness keep-alive.
  heartbeat,
}

String generateSignalMessageId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

class SignalEnvelope {
  final int version;

  /// Globally unique id for de-duplication and acknowledgement.
  final String messageId;

  /// Monotonic per-sender-per-call sequence number, starting at 1.
  final int sequence;

  /// Opaque call/session identifier this message belongs to.
  final String callId;

  /// Stable identifier of the sending device's public identity key
  /// (fingerprint form), never a raw key or a user identifier.
  final String senderKeyId;

  final SignalType type;

  /// Sender wall-clock creation time (Unix milliseconds). Used only for
  /// staleness limits; ordering relies on [sequence].
  final int createdAtMs;

  /// Type-specific body. For [SignalType.ack] this carries the acknowledged
  /// `messageId`. End-to-end-encrypted deployments place ciphertext here.
  final Map<String, Object?> payload;

  SignalEnvelope({
    this.version = signalProtocolVersion,
    required this.messageId,
    required this.sequence,
    required this.callId,
    required this.senderKeyId,
    required this.type,
    required this.createdAtMs,
    required Map<String, Object?> payload,
  }) : payload = Map.unmodifiable(payload) {
    _validate();
  }

  void _validate() {
    if (version != signalProtocolVersion) {
      throw FormatException('Unsupported signal protocol version: $version');
    }
    if (messageId.isEmpty || messageId.length > 64) {
      throw const FormatException('messageId must be 1..64 characters.');
    }
    if (sequence < 1) {
      throw const FormatException('sequence must be >= 1.');
    }
    if (callId.isEmpty || callId.length > 128) {
      throw const FormatException('callId must be 1..128 characters.');
    }
    if (senderKeyId.isEmpty || senderKeyId.length > 128) {
      throw const FormatException('senderKeyId must be 1..128 characters.');
    }
    if (createdAtMs <= 0) {
      throw const FormatException('createdAtMs must be positive.');
    }
  }

  /// Builds an acknowledgement envelope for this message.
  SignalEnvelope buildAck({
    required String ackSenderKeyId,
    required int sequence,
    required int nowMs,
  }) {
    return SignalEnvelope(
      messageId: generateSignalMessageId(),
      sequence: sequence,
      callId: callId,
      senderKeyId: ackSenderKeyId,
      type: SignalType.ack,
      createdAtMs: nowMs,
      payload: {'ackedMessageId': messageId},
    );
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'id': messageId,
    'seq': sequence,
    'callId': callId,
    'senderKeyId': senderKeyId,
    'type': type.name,
    'createdAtMs': createdAtMs,
    'payload': payload,
  };

  /// Serializes to UTF-8 JSON bytes, enforcing [maxEnvelopeBytes].
  List<int> toBytes() {
    final bytes = utf8.encode(jsonEncode(toJson()));
    if (bytes.length > maxEnvelopeBytes) {
      throw FormatException(
        'Envelope of ${bytes.length} bytes exceeds the '
        '$maxEnvelopeBytes byte limit.',
      );
    }
    return bytes;
  }

  factory SignalEnvelope.fromJson(Map<String, Object?> json) {
    final version = json['v'];
    final messageId = json['id'];
    final sequence = json['seq'];
    final callId = json['callId'];
    final senderKeyId = json['senderKeyId'];
    final typeName = json['type'];
    final createdAtMs = json['createdAtMs'];
    final payload = json['payload'];

    if (version is! int) {
      throw const FormatException('Envelope version missing.');
    }
    if (messageId is! String ||
        sequence is! int ||
        callId is! String ||
        senderKeyId is! String ||
        typeName is! String ||
        createdAtMs is! int) {
      throw const FormatException('Envelope has missing or mistyped fields.');
    }

    final type = SignalType.values.cast<SignalType?>().firstWhere(
      (t) => t!.name == typeName,
      orElse: () => null,
    );
    if (type == null) {
      throw FormatException('Unknown signal type: $typeName');
    }

    if (payload is! Map<String, Object?>) {
      throw const FormatException('Envelope payload must be a JSON object.');
    }

    return SignalEnvelope(
      version: version,
      messageId: messageId,
      sequence: sequence,
      callId: callId,
      senderKeyId: senderKeyId,
      type: type,
      createdAtMs: createdAtMs,
      payload: payload,
    );
  }

  factory SignalEnvelope.fromBytes(List<int> bytes) {
    if (bytes.length > maxEnvelopeBytes) {
      throw FormatException(
        'Incoming frame of ${bytes.length} bytes exceeds the '
        '$maxEnvelopeBytes byte limit.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Exception catch (e) {
      throw FormatException('Envelope is not valid UTF-8 JSON: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Envelope root must be a JSON object.');
    }
    return SignalEnvelope.fromJson(decoded);
  }

  @override
  String toString() =>
      'SignalEnvelope(${type.name}, id: $messageId, seq: $sequence, '
      'call: $callId)';
}
