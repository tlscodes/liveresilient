/// Structured-mutation regression coverage for the signaling relay's
/// internal envelope decoder.
///
/// Duplicates the target logic in `tool/fuzz/targets_signaling_server.dart`
/// (see `test/support/fuzz_support.dart` for why it's a copy, not a shared
/// dependency) so `dart test` alone proves the contract: the decoder is
/// return-based and must never throw — only return `null` (malformed) or a
/// decoded map. Any thrown exception is a regression and fails the test
/// with a minimal, seed-based repro.
library;

import 'dart:convert';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/fuzz_support.dart';

const _seed = 20260716;
const _iterations = 12000;

class _SignalingFrameFuzzTarget extends FuzzTarget {
  @override
  String get name => 'signaling_frame';

  Map<String, Object?> buildValidTree(FuzzRng rng) => <String, Object?>{
    'callId': rng.token(rng.intIn(1, 128)),
    'type': rng.pick(const ['offer', 'answer', 'ice-candidate', 'bye']),
    'payload': <String, Object?>{
      'sdp': rng.hostileString(),
      'seq': rng.intIn(0, 1 << 30),
    },
  };

  @override
  FuzzCase generate(FuzzRng rng) {
    final valid = buildValidTree(rng);
    if (rng.chance(0.05)) {
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
    final decoded = decodeSignalingEnvelopeForFuzzing(input! as List<int>);
    return decoded == null ? FuzzOutcome.reject : FuzzOutcome.accept;
  }

  @override
  bool isContractError(Object error) => false; // return-based: never throws.
}

void main() {
  test(
    'signaling_frame: contract holds over $_iterations seeded mutations',
    () async {
      final target = _SignalingFrameFuzzTarget();
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
          '${summary.iterations} for target "signaling_frame" '
          '(seed=$_seed):\n$details',
        );
      }
      expect(summary.accepts + summary.rejects, summary.iterations);
    },
  );
}
