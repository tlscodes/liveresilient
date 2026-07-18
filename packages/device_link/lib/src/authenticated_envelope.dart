/// Authenticated envelope for local peer links.
///
/// Every frame exchanged with a nearby device (local Wi-Fi / peer-to-peer
/// link) is wrapped in an [AuthenticatedEnvelope]: an Ed25519 signature by
/// the sender's device identity key over the canonical envelope bytes, plus
/// a nonce and timestamp for replay rejection. The payload itself is
/// expected to be end-to-end ciphertext produced by the session layer; this
/// envelope authenticates *who relayed the bytes on this hop*, matching the
/// `MediaFrame` trust model in this package.
///
/// Signing/verification are delegated to adapters over an audited
/// cryptography library — no custom crypto lives here.
///
/// Designed from the v2 blueprint role (no v1 equivalent; the v1 local mesh
/// frames were unauthenticated).
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

const int authenticatedEnvelopeVersion = 1;

/// Maximum payload accepted on a local link frame.
const int maxLocalPayloadBytes = 256 * 1024;

String generateEnvelopeNonce() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Adapter over an audited Ed25519 signer holding the local device key.
abstract interface class EnvelopeSigner {
  /// Identifier (fingerprint form) of the local signing key.
  String get keyId;

  Future<Uint8List> sign(Uint8List message);
}

/// Adapter over an audited Ed25519 verifier with access to the trusted
/// peer-key directory (populated by the app's pairing / consent flow).
abstract interface class EnvelopeVerifier {
  /// Returns true when [signature] over [message] verifies against the
  /// trusted public key registered for [keyId]. Unknown key ids must
  /// return false, never throw.
  Future<bool> verify({
    required String keyId,
    required Uint8List message,
    required Uint8List signature,
  });
}

final class AuthenticatedEnvelope {
  final int version;

  /// Random unique id for replay rejection.
  final String nonce;

  /// Key id of the sending device.
  final String senderKeyId;

  /// Sender wall-clock in Unix milliseconds; receivers enforce a freshness
  /// window.
  final int sentAtMs;

  /// Application payload (normally end-to-end ciphertext).
  final Uint8List payload;

  /// Ed25519 signature over [signedBytes].
  final Uint8List signature;

  AuthenticatedEnvelope({
    this.version = authenticatedEnvelopeVersion,
    required this.nonce,
    required this.senderKeyId,
    required this.sentAtMs,
    required List<int> payload,
    required List<int> signature,
  }) : payload = Uint8List.fromList(payload),
       signature = Uint8List.fromList(signature) {
    if (version != authenticatedEnvelopeVersion) {
      throw FormatException('Unsupported envelope version: $version');
    }
    if (nonce.isEmpty || nonce.length > 64) {
      throw const FormatException('nonce must be 1..64 characters.');
    }
    if (senderKeyId.isEmpty || senderKeyId.length > 128) {
      throw const FormatException('senderKeyId must be 1..128 characters.');
    }
    if (sentAtMs <= 0) {
      throw const FormatException('sentAtMs must be positive.');
    }
    if (this.payload.length > maxLocalPayloadBytes) {
      throw FormatException(
        'Payload of ${this.payload.length} bytes exceeds the local link '
        'limit of $maxLocalPayloadBytes.',
      );
    }
  }

  /// Canonical bytes covered by the signature: a length-prefixed
  /// concatenation, immune to field-boundary ambiguity.
  Uint8List signedBytes() {
    final builder = BytesBuilder(copy: false);
    void addField(List<int> bytes) {
      final length = ByteData(4)..setUint32(0, bytes.length);
      builder.add(length.buffer.asUint8List());
      builder.add(bytes);
    }

    addField(utf8.encode('ae-v$version'));
    addField(utf8.encode(nonce));
    addField(utf8.encode(senderKeyId));
    addField(utf8.encode(sentAtMs.toString()));
    addField(payload);
    return builder.toBytes();
  }

  /// Creates and signs an envelope with the local device key.
  static Future<AuthenticatedEnvelope> create({
    required EnvelopeSigner signer,
    required List<int> payload,
    required int nowMs,
  }) async {
    final unsigned = AuthenticatedEnvelope(
      nonce: generateEnvelopeNonce(),
      senderKeyId: signer.keyId,
      sentAtMs: nowMs,
      payload: payload,
      signature: const [],
    );
    final signature = await signer.sign(unsigned.signedBytes());
    return AuthenticatedEnvelope(
      nonce: unsigned.nonce,
      senderKeyId: unsigned.senderKeyId,
      sentAtMs: unsigned.sentAtMs,
      payload: payload,
      signature: signature,
    );
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'nonce': nonce,
    'senderKeyId': senderKeyId,
    'sentAtMs': sentAtMs,
    'payload': base64Encode(payload),
    'signature': base64Encode(signature),
  };

  List<int> toBytes() => utf8.encode(jsonEncode(toJson()));

  factory AuthenticatedEnvelope.fromBytes(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Exception catch (e) {
      throw FormatException('Envelope is not valid UTF-8 JSON: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Envelope root must be a JSON object.');
    }
    final version = decoded['v'];
    final nonce = decoded['nonce'];
    final senderKeyId = decoded['senderKeyId'];
    final sentAtMs = decoded['sentAtMs'];
    final payload = decoded['payload'];
    final signature = decoded['signature'];
    if (version is! int ||
        nonce is! String ||
        senderKeyId is! String ||
        sentAtMs is! int ||
        payload is! String ||
        signature is! String) {
      throw const FormatException('Envelope has missing or mistyped fields.');
    }
    try {
      return AuthenticatedEnvelope(
        version: version,
        nonce: nonce,
        senderKeyId: senderKeyId,
        sentAtMs: sentAtMs,
        payload: base64Decode(payload),
        signature: base64Decode(signature),
      );
    } on FormatException {
      rethrow;
    }
  }
}

/// Result of receiver-side envelope validation.
enum EnvelopeValidation {
  valid,
  badSignature,
  unknownSender,
  replayed,
  stale,
  malformed,
}

/// Validates incoming envelopes: signature, freshness window, and nonce
/// replay rejection with a bounded memory window.
class EnvelopeValidator {
  final EnvelopeVerifier _verifier;
  final Duration freshnessWindow;
  final int maxTrackedNonces;

  // Explicit LinkedHashMap (not the default `{}`, which happens to also be
  // insertion-ordered) so the `.keys.first` eviction below relies on a
  // documented, guaranteed insertion order rather than an implementation
  // detail of the map literal.
  final LinkedHashMap<String, int> _seenNonceExpiry =
      LinkedHashMap<String, int>();

  EnvelopeValidator({
    required EnvelopeVerifier verifier,
    this.freshnessWindow = const Duration(minutes: 2),
    this.maxTrackedNonces = 8192,
  }) : _verifier = verifier {
    if (maxTrackedNonces < 1) {
      throw RangeError.range(maxTrackedNonces, 1, null, 'maxTrackedNonces');
    }
  }

  Future<EnvelopeValidation> validate(
    AuthenticatedEnvelope envelope, {
    required int nowMs,
  }) async {
    final windowMs = freshnessWindow.inMilliseconds;
    if ((nowMs - envelope.sentAtMs).abs() > windowMs) {
      return EnvelopeValidation.stale;
    }

    final signatureOk = await _verifier.verify(
      keyId: envelope.senderKeyId,
      message: envelope.signedBytes(),
      signature: envelope.signature,
    );
    if (!signatureOk) {
      // The verifier contract returns false for unknown senders too; both
      // are rejected — the split status exists for diagnostics counters.
      return EnvelopeValidation.badSignature;
    }

    _purge(nowMs);
    final replayKey = '${envelope.senderKeyId}:${envelope.nonce}';
    if (_seenNonceExpiry.containsKey(replayKey)) {
      return EnvelopeValidation.replayed;
    }
    _seenNonceExpiry[replayKey] = nowMs + windowMs;
    while (_seenNonceExpiry.length > maxTrackedNonces) {
      _seenNonceExpiry.remove(_seenNonceExpiry.keys.first);
    }

    return EnvelopeValidation.valid;
  }

  void _purge(int nowMs) {
    _seenNonceExpiry.removeWhere((_, expiry) => expiry <= nowMs);
  }
}
