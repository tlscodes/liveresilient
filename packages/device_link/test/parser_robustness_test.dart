/// Structured-mutation regression coverage for `package:device_link`'s
/// untrusted-input parsers/validators.
///
/// This duplicates the target logic in `tool/fuzz/targets_device_link.dart`
/// (see `test/support/fuzz_support.dart` for why it's a copy, not a shared
/// dependency) so `dart test` alone — no separate CLI invocation — proves
/// the contract: every target either returns a valid object / return-based
/// rejection, or throws FormatException/ArgumentError. Any other exception
/// is a regression and fails the test with a minimal, seed-based repro.
library;

import 'dart:async';
import 'dart:convert';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

import 'support/fuzz_support.dart';

const _seed = 20260716;
const _iterations = 12000;

/// `AuthenticatedEnvelope.fromBytes`: FormatException/ArgumentError or a
/// valid envelope — never anything else.
class _EnvelopeFuzzTarget extends FuzzTarget {
  @override
  String get name => 'envelope';

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
      return FuzzCase.ofBytes(utf8.encode(jsonEncode(valid)));
    }
    if (rng.chance(0.03)) {
      valid['payload'] = base64Encode(rng.bytes(rng.intIn(262145, 300000)));
      return FuzzCase.ofBytes(utf8.encode(jsonEncode(valid)));
    }
    final tree = mutateTree(valid, rng);
    final String encoded;
    try {
      encoded = jsonEncode(tree);
    } on Object {
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
class _PushWakeupFuzzTarget extends FuzzTarget {
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

class _LinkFrameCase {
  final MediaFrame frame;
  final int nowMs;
  final bool forwardingEnabled;
  final bool signatureValid;

  _LinkFrameCase({
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

class _StubBroadcaster implements LinkBroadcaster {
  @override
  Future<void> broadcast(MediaFrame envelope) async {}
}

/// `LinkMessageProcessor.process`: return-based contract (never throws with
/// a correctly-behaving authenticator stub); any frame it does NOT reject
/// must have a sane, overflow-free lifetime. Regression coverage for the
/// 64-bit lifetime-subtraction overflow found by this suite and fixed in
/// `media_frame.dart` (`_hasValidBounds`).
class _LinkFrameFuzzTarget extends FuzzTarget {
  static const int maximumLifetimeMs = 10 * 60 * 1000;

  @override
  String get name => 'link_frame';

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
    final fuzzCase = _LinkFrameCase(
      frame: frame,
      nowMs: nowMs,
      forwardingEnabled: rng.chance(0.5),
      signatureValid: rng.chance(0.7),
    );
    return FuzzCase(
      fuzzCase,
      () =>
          'linkFrame{v:${frame.version}, messageId:'
          '${jsonEncode(frame.messageId)}, createdAtMs:${frame.createdAtMs}, '
          'expiresAtMs:${frame.expiresAtMs}, maxHops:${frame.maxHops}, '
          'hopCount:${frame.hopCount}, nowMs:${fuzzCase.nowMs}, '
          'forwarding:${fuzzCase.forwardingEnabled}, '
          'sigValid:${fuzzCase.signatureValid}}',
    );
  }

  @override
  Future<FuzzOutcome> execute(Object? input) async {
    final fuzzCase = input! as _LinkFrameCase;
    final processor = LinkMessageProcessor(
      authenticator: _StubAuthenticator(fuzzCase.signatureValid),
      broadcaster: _StubBroadcaster(),
      seenCache: LinkSeenCache(maximumEntries: 64),
      onDeliver: (_) async {},
      forwardingEnabled: fuzzCase.forwardingEnabled,
      maximumLifetimeMs: maximumLifetimeMs,
    );
    final disposition = await processor.process(
      fuzzCase.frame,
      nowMs: fuzzCase.nowMs,
    );
    if (disposition == LinkDisposition.rejected) {
      return FuzzOutcome.reject;
    }
    final frame = fuzzCase.frame;
    final lifetime = frame.expiresAtMs - frame.createdAtMs;
    if (lifetime <= 0 || lifetime > maximumLifetimeMs) {
      throw StateError(
        'Frame passed bounds validation with lifetime $lifetime ms '
        '(createdAtMs=${frame.createdAtMs}, '
        'expiresAtMs=${frame.expiresAtMs}) — 64-bit overflow slip-through.',
      );
    }
    return FuzzOutcome.accept;
  }

  @override
  bool isContractError(Object error) => false;
}

void _runAndAssert(FuzzTarget target) {
  test(
    '${target.name}: contract holds over $_iterations seeded mutations',
    () async {
      final summary = await runFuzzTarget(
        target,
        iterations: _iterations,
        seed: _seed,
      );
      if (summary.otherExceptions > 0) {
        final details = summary.failures
            .map(
              (f) =>
                  'iteration=${f.iteration} caseSeed=${f.caseSeed} '
                  'error=${f.error} stack=${f.stackHead} input=${f.input}',
            )
            .join('\n');
        fail(
          '${summary.otherExceptions} non-contract exception(s) out of '
          '${summary.iterations} for target "${target.name}" '
          '(seed=$_seed):\n$details',
        );
      }
      expect(summary.accepts + summary.rejects, summary.iterations);
    },
  );
}

void main() {
  group('parser robustness (structured-mutation fuzzing)', () {
    _runAndAssert(_EnvelopeFuzzTarget());
    _runAndAssert(_PushWakeupFuzzTarget());
    _runAndAssert(_LinkFrameFuzzTarget());
  });
}
