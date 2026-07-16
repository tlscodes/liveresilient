/// Push-based wakeup for incoming calls (pure-Dart core).
///
/// Blueprint role (§8.1): a push message may *wake the app* and *announce
/// that an incoming call may exist* — nothing more. The payload carries an
/// opaque, low-size call ID only. Push is never the source of truth for
/// call state, and delivery is never assumed guaranteed.
///
/// The no-SDP / no-key / no-contact guarantee is enforced **by
/// construction**, not by filtering:
/// - the schema is fixed to exactly four scalar fields; any unknown key in
///   an inbound payload is a [FormatException];
/// - the call ID is restricted to 8-64 URL-safe characters, leaving no room
///   for structured data;
/// - the whole encoded payload is capped at [PushWakeupPayload.maxEncodedBytes].
///
/// Registration and platform delivery (APNs/FCM) live behind
/// [PushWakeupPort] in the native slot; nothing here can prove end-to-end
/// delivery and nothing here claims to.
library;

import 'dart:convert';

import 'media_frame.dart' show MeshSeenCache;

/// Fixed-schema wakeup payload: an opaque call ID plus its validity window.
class PushWakeupPayload {
  /// The only schema this module reads or writes.
  static const int currentSchemaVersion = 1;

  /// Hard upper bound on payload lifetime: 5 minutes.
  static const int maxTtlMs = 5 * 60 * 1000;

  /// Hard cap on the UTF-8 encoded JSON size.
  static const int maxEncodedBytes = 512;

  static const int minCallIdLength = 8;
  static const int maxCallIdLength = 64;

  static final RegExp _callIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  static const Set<String> _allowedKeys = {
    'schemaVersion',
    'callId',
    'issuedAtMs',
    'expiresAtMs',
  };

  /// Opaque identifier; carries no structured data by construction.
  final String callId;

  final int issuedAtMs;
  final int expiresAtMs;
  final int schemaVersion;

  PushWakeupPayload({
    required this.callId,
    required this.issuedAtMs,
    required this.expiresAtMs,
    this.schemaVersion = currentSchemaVersion,
  }) {
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException('Unsupported schema version: $schemaVersion');
    }
    if (callId.length < minCallIdLength || callId.length > maxCallIdLength) {
      throw FormatException(
        'callId length must be $minCallIdLength-$maxCallIdLength characters.',
      );
    }
    if (!_callIdPattern.hasMatch(callId)) {
      throw const FormatException(
        'callId may only contain A-Z, a-z, 0-9, "_" and "-".',
      );
    }
    if (issuedAtMs < 0) {
      throw const FormatException('issuedAtMs must be non-negative.');
    }
    if (expiresAtMs <= issuedAtMs) {
      throw const FormatException('expiresAtMs must be after issuedAtMs.');
    }
    if (expiresAtMs - issuedAtMs > maxTtlMs) {
      throw const FormatException(
        'Payload lifetime exceeds the maximum allowed TTL.',
      );
    }
  }

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'callId': callId,
    'issuedAtMs': issuedAtMs,
    'expiresAtMs': expiresAtMs,
  };

  /// Strict decoder: exactly the four schema keys, correct types, no more.
  /// Any extra key is rejected — that is the structural guarantee that a
  /// wakeup can never smuggle SDP, keys, or contact data.
  factory PushWakeupPayload.fromJson(Map<String, Object?> json) {
    for (final key in json.keys) {
      if (!_allowedKeys.contains(key)) {
        throw FormatException('Unknown key in push wakeup payload: $key');
      }
    }

    return PushWakeupPayload(
      schemaVersion: _requireInt(json, 'schemaVersion'),
      callId: _requireString(json, 'callId'),
      issuedAtMs: _requireInt(json, 'issuedAtMs'),
      expiresAtMs: _requireInt(json, 'expiresAtMs'),
    );
  }

  /// Encodes to compact JSON, enforcing [maxEncodedBytes].
  String encode() {
    final encoded = jsonEncode(toJson());
    if (utf8.encode(encoded).length > maxEncodedBytes) {
      throw const FormatException('Encoded payload exceeds the size cap.');
    }
    return encoded;
  }

  /// Decodes a raw push payload, enforcing the size cap before parsing.
  static PushWakeupPayload decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException('Push payload exceeds the size cap.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('Push payload is not valid JSON.');
    }

    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Push payload must be a JSON object.');
    }

    return PushWakeupPayload.fromJson(decoded);
  }

  static int _requireInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw FormatException('Field "$key" must be an integer.');
    }
    return value;
  }

  static String _requireString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Field "$key" must be a string.');
    }
    return value;
  }
}

enum PushWakeupResult { accepted, duplicate, expired, malformed }

/// Idempotent wakeup handler: at most one "incoming call may exist" signal
/// per call ID within its validity window, regardless of how many times the
/// platform redelivers the push.
class PushWakeupProcessor {
  /// Tolerated forward clock skew for `issuedAtMs`, mirroring
  /// `MeshMessageProcessor`'s bound check.
  static const int maxClockSkewMs = 60 * 1000;

  final MeshSeenCache _seenCallIds;

  /// Invoked exactly once per accepted call ID. The app treats this as
  /// "a call may exist for opaque id X" and must confirm real call state
  /// over an authenticated channel — never from the push itself.
  final void Function(String callId)? onIncomingCallAnnounced;

  PushWakeupProcessor({
    int maximumTrackedCallIds = 1024,
    this.onIncomingCallAnnounced,
  }) : _seenCallIds = MeshSeenCache(maximumEntries: maximumTrackedCallIds);

  /// Decodes and handles a raw push payload. Structural problems (bad JSON,
  /// unknown keys, oversize, invalid fields) are [PushWakeupResult.malformed].
  PushWakeupResult handleRaw(String rawPayload, {required int nowMs}) {
    final PushWakeupPayload payload;
    try {
      payload = PushWakeupPayload.decode(rawPayload);
    } on FormatException {
      return PushWakeupResult.malformed;
    }
    return handle(payload, nowMs: nowMs);
  }

  PushWakeupResult handle(PushWakeupPayload payload, {required int nowMs}) {
    if (payload.issuedAtMs > nowMs + maxClockSkewMs) {
      return PushWakeupResult.malformed;
    }

    if (payload.isExpiredAt(nowMs)) {
      return PushWakeupResult.expired;
    }

    final isNew = _seenCallIds.markIfNew(
      messageId: payload.callId,
      expiresAtMs: payload.expiresAtMs,
      nowMs: nowMs,
    );

    if (!isNew) {
      return PushWakeupResult.duplicate;
    }

    onIncomingCallAnnounced?.call(payload.callId);
    return PushWakeupResult.accepted;
  }
}

/// Platform port over the actual push transport (APNs/FCM). Token
/// registration, permission prompts, and delivery live in the native slot;
/// this pure-Dart module only validates and deduplicates what arrives.
/// Delivery is best-effort by contract — callers must never assume a
/// wakeup is guaranteed to arrive.
abstract interface class PushWakeupPort {
  /// Registers this device for wakeup pushes (platform token flow).
  Future<void> register();

  /// Raw inbound push payloads, exactly as delivered by the platform.
  Stream<String> get wakeupPayloads;

  Future<void> close();
}
