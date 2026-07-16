/// Fuzz targets for `package:device_link` parsers/validators.
///
/// Targets:
///  - `envelope`     → [AuthenticatedEnvelope.fromBytes] (wire bytes).
///  - `push_wakeup`  → [PushWakeupPayload.decode] (raw push string).
///  - `mesh_frame`   → [MeshMessageProcessor.process] fed field-mutated
///    [MediaFrame]s through a correctly-behaving stub authenticator; the
///    contract here is *return-based*: any thrown exception is a finding,
///    and accepted frames must satisfy the processor's own lifetime bounds.
library;

import 'dart:async';
import 'dart:convert';

import 'package:device_link/device_link.dart';

import 'fuzz_engine.dart';

/// `AuthenticatedEnvelope.fromBytes`: FormatException/ArgumentError or a
/// valid envelope — never anything else.
class EnvelopeFuzzTarget extends FuzzTarget {
  @override
  String get name => 'envelope';

  /// A randomized *valid* envelope document (accept-path corpus).
  Map<String, Object?> buildValidTree(FuzzRng rng) => <String, Object?>{
    'v': 1,
    'nonce': rng.token(rng.intIn(1, 64)),
    'senderKeyId': rng.token(rng.intIn(1, 128)),
    'sentAtMs': rng.intIn(1, 4102444800000),
    'payload': base64Encode(rng.bytes(rng.nextInt(1024))),
    'signature': base64Encode(rng.bytes(64)),
  };

  @override
  FuzzCase generate(FuzzRng rng) {
    final valid = buildValidTree(rng);
    if (rng.chance(0.05)) {
      // Unmutated valid document — keeps the accept path exercised.
      return FuzzCase.ofBytes(utf8.encode(jsonEncode(valid)));
    }
    if (rng.chance(0.03)) {
      // Oversized payload crossing maxLocalPayloadBytes (256 KiB).
      valid['payload'] = base64Encode(rng.bytes(rng.intIn(262145, 300000)));
      return FuzzCase.ofBytes(utf8.encode(jsonEncode(valid)));
    }
    final tree = mutateTree(valid, rng);
    final String encoded;
    try {
      encoded = jsonEncode(tree);
    } on Object {
      // Mutation produced a non-encodable value (e.g. NaN): feed raw bytes.
      return FuzzCase.ofBytes(rng.bytes(rng.nextInt(128)));
    }
    if (rng.chance(0.35)) {
      return FuzzCase.ofBytes(mutateEncodedBytes(encoded, tree, rng));
    }
    return FuzzCase.ofBytes(utf8.encode(encoded));
  }

  @override
  FuzzOutcome execute(Object? input) {
    AuthenticatedEnvelope.fromBytes(input! as List<int>);
    return FuzzOutcome.accept;
  }
}

/// `PushWakeupPayload.decode`: FormatException or a valid payload.
class PushWakeupFuzzTarget extends FuzzTarget {
  @override
  String get name => 'push_wakeup';

  Map<String, Object?> buildValidTree(FuzzRng rng) {
    final issuedAtMs = rng.intIn(0, 4102444800000);
    return <String, Object?>{
      'schemaVersion': 1,
      'callId': rng.token(rng.intIn(8, 64)),
      'issuedAtMs': issuedAtMs,
      'expiresAtMs': issuedAtMs + rng.intIn(1, PushWakeupPayload.maxTtlMs),
    };
  }

  @override
  FuzzCase generate(FuzzRng rng) {
    final valid = buildValidTree(rng);
    if (rng.chance(0.05)) {
      return FuzzCase.ofString(jsonEncode(valid));
    }
    final tree = mutateTree(valid, rng);
    final String encoded;
    try {
      encoded = jsonEncode(tree);
    } on Object {
      return FuzzCase.ofString(rng.hostileString());
    }
    if (rng.chance(0.35)) {
      // String-level corruption (the decode API takes a String, so byte
      // mutations are replayed through a lossy latin-1 style projection).
      final bytes = mutateEncodedBytes(encoded, tree, rng);
      return FuzzCase.ofString(String.fromCharCodes(bytes));
    }
    return FuzzCase.ofString(encoded);
  }

  @override
  FuzzOutcome execute(Object? input) {
    PushWakeupPayload.decode(input! as String);
    return FuzzOutcome.accept;
  }
}

/// The concrete case fed to `MeshMessageProcessor.process`.
class MeshFrameCase {
  final MediaFrame frame;
  final int nowMs;
  final bool forwardingEnabled;
  final bool signatureValid;

  MeshFrameCase({
    required this.frame,
    required this.nowMs,
    required this.forwardingEnabled,
    required this.signatureValid,
  });
}

class _StubAuthenticator implements MediaFrameAuthenticator {
  final bool verdict;

  _StubAuthenticator(this.verdict);

  @override
  Future<bool> verify(MediaFrame envelope) async => verdict;

  @override
  Future<MediaFrame> createForwardedEnvelope(MediaFrame envelope) async =>
      MediaFrame(
        version: envelope.version,
        messageId: envelope.messageId,
        originKeyId: envelope.originKeyId,
        currentRelayKeyId: 'relay-self',
        createdAtMs: envelope.createdAtMs,
        expiresAtMs: envelope.expiresAtMs,
        maxHops: envelope.maxHops,
        hopCount: envelope.hopCount + 1,
        ciphertext: envelope.ciphertext,
        signature: envelope.signature,
      );
}

class _StubBroadcaster implements MeshBroadcaster {
  @override
  Future<void> broadcast(MediaFrame envelope) async {}
}

/// `MeshMessageProcessor.process` under hostile field values: it must
/// return a [MeshDisposition] (never throw — a correct authenticator stub is
/// wired in, so the StateError guard for misbehaving authenticators cannot
/// legitimately fire), and any *non-rejected* frame must have a sane
/// lifetime: `0 < expiresAtMs - createdAtMs <= maximumLifetimeMs` without
/// 64-bit overflow.
class MeshFrameFuzzTarget extends FuzzTarget {
  static const int maximumLifetimeMs = 10 * 60 * 1000;

  @override
  String get name => 'mesh_frame';

  String _idValue(FuzzRng rng) =>
      rng.chance(0.5) ? rng.token(rng.intIn(1, 22)) : rng.hostileString();

  int _timeValue(FuzzRng rng, int nowMs) =>
      rng.chance(0.5) ? nowMs + rng.intIn(-700000, 700000) : rng.boundaryInt();

  @override
  FuzzCase generate(FuzzRng rng) {
    final nowMs = rng.intIn(1, 4102444800000);
    final createdAtMs = _timeValue(rng, nowMs);
    final frame = MediaFrame(
      version: rng.chance(0.7) ? 1 : rng.boundaryInt(),
      messageId: _idValue(rng),
      originKeyId: _idValue(rng),
      currentRelayKeyId: _idValue(rng),
      createdAtMs: createdAtMs,
      expiresAtMs: rng.chance(0.4)
          ? createdAtMs + rng.intIn(-1000, maximumLifetimeMs + 1000)
          : _timeValue(rng, nowMs),
      maxHops: rng.chance(0.6) ? rng.intIn(-2, 10) : rng.boundaryInt(),
      hopCount: rng.chance(0.6) ? rng.intIn(-2, 10) : rng.boundaryInt(),
      ciphertext: rng.bytes(rng.nextInt(256)),
      signature: rng.bytes(rng.chance(0.5) ? 64 : rng.nextInt(96)),
    );
    final fuzzCase = MeshFrameCase(
      frame: frame,
      nowMs: nowMs,
      forwardingEnabled: rng.chance(0.5),
      signatureValid: rng.chance(0.7),
    );
    return FuzzCase(
      fuzzCase,
      () =>
          'meshFrame{v:${frame.version}, messageId:'
          '${jsonEncode(frame.messageId)}, createdAtMs:${frame.createdAtMs}, '
          'expiresAtMs:${frame.expiresAtMs}, maxHops:${frame.maxHops}, '
          'hopCount:${frame.hopCount}, nowMs:${fuzzCase.nowMs}, '
          'forwarding:${fuzzCase.forwardingEnabled}, '
          'sigValid:${fuzzCase.signatureValid}}',
    );
  }

  @override
  Future<FuzzOutcome> execute(Object? input) async {
    final fuzzCase = input! as MeshFrameCase;
    final processor = MeshMessageProcessor(
      authenticator: _StubAuthenticator(fuzzCase.signatureValid),
      broadcaster: _StubBroadcaster(),
      seenCache: MeshSeenCache(maximumEntries: 64),
      onDeliver: (_) async {},
      forwardingEnabled: fuzzCase.forwardingEnabled,
      maximumLifetimeMs: maximumLifetimeMs,
    );
    final disposition = await processor.process(
      fuzzCase.frame,
      nowMs: fuzzCase.nowMs,
    );
    if (disposition == MeshDisposition.rejected) {
      return FuzzOutcome.reject;
    }
    // Bounds invariant: anything the processor did NOT reject must have a
    // sane, overflow-free lifetime (this is the validation the bounds check
    // exists to provide).
    final frame = fuzzCase.frame;
    final lifetime = frame.expiresAtMs - frame.createdAtMs;
    if (lifetime <= 0 || lifetime > maximumLifetimeMs) {
      throw StateError(
        'Frame passed bounds validation with lifetime $lifetime ms '
        '(createdAtMs=${frame.createdAtMs}, '
        'expiresAtMs=${frame.expiresAtMs}) — 64-bit overflow bypass.',
      );
    }
    return FuzzOutcome.accept;
  }

  @override
  bool isContractError(Object error) => false; // return-based API: no throws.
}

/// All device_link fuzz targets.
List<FuzzTarget> deviceLinkFuzzTargets() => [
  EnvelopeFuzzTarget(),
  PushWakeupFuzzTarget(),
  MeshFrameFuzzTarget(),
];
