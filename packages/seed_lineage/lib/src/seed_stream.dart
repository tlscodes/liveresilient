/// Deterministic byte stream derived from a genealogy seed — the Dart twin of
/// the engine's `SeedStream` (engine/crates/jitter/src/lib.rs:24-82).
///
/// The construction is deliberately simple so two languages can agree on it:
///
/// ```text
/// block(n) := blake2b-256(seed || counter_le8)   with counter starting at 0
/// bytes    := block(0) || block(1) || ...        consumed 8 at a time
/// ```
///
/// A block yields exactly four `u64` draws; the fifth forces the next block.
/// That boundary is part of the contract — a different chunking would produce a
/// different stream from the same seed, so it is asserted by the cross-language
/// vector test rather than left implicit.
library;

import 'dart:typed_data';

import 'package:pointycastle/digests/blake2b.dart';

import '../seed_lineage.dart';

/// Label of the domain these streams descend from, matching the engine's
/// `JITTER_DOMAIN`.
const String jitterDomain = 'jitter';

class SeedStream {
  /// Builds a stream directly from an already-derived 32-byte seed.
  SeedStream.fromSeed(this._seed)
    : _block = Uint8List(seedLengthBytes),
      _used = seedLengthBytes {
    if (_seed.length != seedLengthBytes) {
      throw ArgumentError.value(
        _seed.length,
        'seed.length',
        'must be exactly $seedLengthBytes bytes',
      );
    }
  }

  /// Builds the stream for a logical path under the `jitter` domain, following
  /// the same genealogy the engine uses.
  factory SeedStream.forPath({
    required int rootSeed,
    required Uint8List manifestHash,
    required String logicalPath,
  }) {
    final domain = domainSeed(
      rootSeed: rootSeed,
      manifestHash: manifestHash,
      domain: jitterDomain,
    );
    return SeedStream.fromSeed(
      streamSeed(domainSeed: domain, logicalPath: logicalPath),
    );
  }

  final Uint8List _seed;
  Uint8List _block;
  int _used;
  int _counter = 0;

  void _refill() {
    final input = Uint8List(seedLengthBytes + 8)
      ..setRange(0, seedLengthBytes, _seed);
    final counterBytes = ByteData(8)..setUint64(0, _counter, Endian.little);
    input.setRange(
      seedLengthBytes,
      input.length,
      counterBytes.buffer.asUint8List(),
    );

    final digest = Blake2bDigest(digestSize: seedLengthBytes);
    digest.update(input, 0, input.length);
    final out = Uint8List(seedLengthBytes);
    digest.doFinal(out, 0);

    _block = out;
    _counter++;
    _used = 0;
  }

  /// Next 8 bytes of the stream as a little-endian unsigned 64-bit value.
  ///
  /// Dart has no unsigned 64-bit int: the value is returned as the same 64 bits
  /// in a signed int, so a draw above 2^63 comes back negative. Every consumer
  /// here goes through [nextBelow], which handles that explicitly; a caller
  /// using this raw must do the same.
  int nextU64() {
    if (_used + 8 > _block.length) _refill();
    final value = ByteData.sublistView(
      _block,
      _used,
      _used + 8,
    ).getUint64(0, Endian.little);
    _used += 8;
    return value;
  }

  /// Uniform integer in `[0, bound)`, matching the engine's Lemire
  /// multiply-shift with rejection so neither side carries modulo bias.
  ///
  /// The 128-bit product the engine computes in `u128` is done here with
  /// [BigInt]: Dart's native ints are 64-bit, so the high half would otherwise
  /// be silently discarded — and the high half IS the result.
  int nextBelow(int bound) {
    if (bound <= 0) {
      throw ArgumentError.value(bound, 'bound', 'must be positive');
    }
    final big2p64 = BigInt.one << 64;
    final bigBound = BigInt.from(bound);
    // threshold = bound.wrapping_neg() % bound, computed in unsigned space.
    final threshold = ((big2p64 - bigBound) % bigBound).toInt();
    while (true) {
      final x = nextU64();
      final unsigned = x < 0 ? big2p64 + BigInt.from(x) : BigInt.from(x);
      final product = unsigned * bigBound;
      final low = (product & (big2p64 - BigInt.one)).toInt();
      final lowUnsigned = low < 0
          ? big2p64 + BigInt.from(low)
          : BigInt.from(low);
      if (lowUnsigned >= BigInt.from(threshold)) {
        return (product >> 64).toInt();
      }
    }
  }
}
