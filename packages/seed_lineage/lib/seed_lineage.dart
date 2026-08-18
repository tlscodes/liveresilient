/// Seed genealogy, identical to the engine project's Rust implementation
/// (engine/crates/manifest/src/lib.rs:79-89).
///
/// ```text
/// domain_seed(d) := blake2b-256(root_seed_le8 || manifest_hash || d)
/// stream_seed(p) := blake2b-256(domain_seed(d) || path_utf8(p))
/// ```
///
/// Two properties make this worth having in both languages rather than in one:
///
///  * Substreams are keyed by a LOGICAL PATH, not by the order in which they
///    happen to be created, so adding concurrency never perturbs the sequence
///    any single stream sees.
///  * Everything descends from one `rootSeed` and one manifest hash, so a run
///    is a pure function of those two values — no clock, no OS entropy.
///
/// The two implementations are pinned to the same cross-language vector (see
/// the test beside this file and the matching Rust test), because "both
/// projects are reproducible" means nothing unless they reproduce the SAME
/// bytes.
///
/// This is NOT for key material. It is a determinism spine for simulation and
/// test reproducibility; anything that must be unpredictable to an adversary
/// belongs to the security package's key schedule, not here.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/blake2b.dart';

export 'src/seed_stream.dart' show SeedStream, jitterDomain;
export 'src/size_targets.dart' show SizeTargets, padTo, shapingTargetsPath;

/// Length in bytes of every seed in the genealogy.
const int seedLengthBytes = 32;

Uint8List _blake2b256(List<Uint8List> parts) {
  final digest = Blake2bDigest(digestSize: seedLengthBytes);
  for (final part in parts) {
    digest.update(part, 0, part.length);
  }
  final out = Uint8List(seedLengthBytes);
  digest.doFinal(out, 0);
  return out;
}

/// Little-endian 8-byte encoding of [value], matching Rust's
/// `u64::to_le_bytes`. Dart ints are 64-bit two's complement, so a value with
/// the high bit set encodes identically to the Rust `u64` with the same bits.
Uint8List rootSeedBytes(int value) {
  final bytes = ByteData(8)..setUint64(0, value, Endian.little);
  return bytes.buffer.asUint8List();
}

/// Per-domain seed. [domain] is a stable ASCII label such as `jitter`.
///
/// [manifestHash] must be the 32-byte manifest digest; a different length is
/// rejected rather than silently padded, because a truncated hash would
/// produce seeds that look fine and match nothing.
Uint8List domainSeed({
  required int rootSeed,
  required Uint8List manifestHash,
  required String domain,
}) {
  if (manifestHash.length != seedLengthBytes) {
    throw ArgumentError.value(
      manifestHash.length,
      'manifestHash.length',
      'must be exactly $seedLengthBytes bytes',
    );
  }
  return _blake2b256([
    rootSeedBytes(rootSeed),
    manifestHash,
    Uint8List.fromList(ascii.encode(domain)),
  ]);
}

/// Per-substream seed within a domain, keyed by [logicalPath].
///
/// Two calls with the same `(domainSeed, logicalPath)` always return the same
/// bytes, regardless of when or on which isolate they happen.
Uint8List streamSeed({
  required Uint8List domainSeed,
  required String logicalPath,
}) {
  if (domainSeed.length != seedLengthBytes) {
    throw ArgumentError.value(
      domainSeed.length,
      'domainSeed.length',
      'must be exactly $seedLengthBytes bytes',
    );
  }
  return _blake2b256([
    domainSeed,
    Uint8List.fromList(utf8.encode(logicalPath)),
  ]);
}

/// Lowercase hex, matching the engine's `to_hex`.
String toHex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Parses lowercase or uppercase hex into bytes. Rejects odd-length input.
Uint8List fromHex(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError.value(hex, 'hex', 'must have an even length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Derives a 32-bit seed suitable for `dart:math`'s `Random(int)` from a
/// genealogy seed.
///
/// `Random` takes only the low 32 bits of its argument, so this states the
/// truncation explicitly instead of letting it happen invisibly: two stream
/// seeds differing only above bit 31 would otherwise produce the SAME
/// generator while looking distinct.
int toRandomSeed(Uint8List seed) {
  if (seed.length < 4) {
    throw ArgumentError.value(seed.length, 'seed.length', 'needs 4+ bytes');
  }
  return seed[0] | (seed[1] << 8) | (seed[2] << 16) | (seed[3] << 24);
}
