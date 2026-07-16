/// Fuzz target for the signaling relay's internal envelope decoder.
///
/// `SignalingRelayServer` deliberately never parses or trusts frame
/// contents at runtime beyond extracting `callId` for room routing — the
/// wire format is otherwise opaque bytes relayed as-is. That one decode
/// step (`_decodeEnvelope`) is exercised here directly, through the
/// test/fuzz-only export `decodeSignalingEnvelopeForFuzzing`, with no live
/// socket involved. The contract is *return-based*, not throw-based: the
/// function must never throw, only return `null` (malformed) or a decoded
/// map — so, unlike the other targets, any thrown exception here is
/// automatically a finding.
library;

import 'dart:convert';

import 'package:signaling_server/signaling_server.dart';

import 'fuzz_engine.dart';

class SignalingFrameFuzzTarget extends FuzzTarget {
  @override
  String get name => 'signaling_frame';

  /// A randomized *valid* signaling envelope (accept-path corpus). The
  /// decoder itself only requires a JSON object; the extra fields mirror a
  /// realistic offer/answer/ICE frame so mutation exercises nesting depth
  /// comparable to the real protocol.
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

/// All signaling_server fuzz targets.
List<FuzzTarget> signalingServerFuzzTargets() => [SignalingFrameFuzzTarget()];
