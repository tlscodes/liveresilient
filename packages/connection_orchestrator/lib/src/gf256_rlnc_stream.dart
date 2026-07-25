/// Systematic Random Linear Network Coding over GF(2^8) — the
/// near-MDS upgrade of the phase-1 LT code, pure Dart.
///
/// Why this beats the LT core: an LT/soliton code needs extra symbols
/// because belief propagation only unlocks degree-1 pivots (measured
/// epsilon 1.33 in rateless_stream_test). Dense random rows over
/// GF(256) are decoded by Gaussian elimination, and a random m x m
/// matrix over GF(256) is singular with probability < 0.4%, so ANY m
/// distinct coded packets of a generation decode it with ~99.6%
/// probability — overhead collapses toward the information-theoretic
/// floor of 1.0.
///
/// Same wire contract as rateless_stream.dart: 53-byte datagrams
/// `u16 esi · u16 blockCount · payload(48) · u8 crc8`, systematic
/// prefix first, zero feedback, coefficients derived from the esi so
/// encoder and decoder never negotiate anything. Generations of up to
/// 64 blocks keep elimination O(64^3) worst-case per generation —
/// microseconds in practice, bounded memory always.
library;

import 'dart:typed_data';

const int _headerBytes = 4;
const int _crcBytes = 1;
// 256 keeps most transfers (<= ~12 KB) in a SINGLE generation, where
// the code is near-MDS end to end (epsilon ~= 1.00); larger transfers
// split into generations and pay a small cross-generation tail.
// Elimination stays O(256^3) worst case per generation — still fast.
const int generationSize = 256;

int _crc8(Uint8List bytes, int end) {
  var crc = 0;
  for (var i = 0; i < end; i++) {
    crc ^= bytes[i];
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
    }
  }
  return crc;
}

// ---- GF(2^8) arithmetic, polynomial 0x11D ----
final Uint8List _gfExp = Uint8List(512);
final Uint8List _gfLog = Uint8List(256);
final bool _gfReady = (() {
  var x = 1;
  for (var i = 0; i < 255; i++) {
    _gfExp[i] = x;
    _gfLog[x] = i;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 512; i++) {
    _gfExp[i] = _gfExp[i - 255];
  }
  return true;
})();

int gfMul(int a, int b) =>
    (a == 0 || b == 0) ? 0 : _gfExp[_gfLog[a] + _gfLog[b]];

int gfInv(int a) => _gfExp[255 - _gfLog[a]];

class _Rng {
  _Rng(int seed) : _s = (seed == 0 ? 0x9E3779B9 : seed) & 0xFFFFFFFF;
  int _s;
  int next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x;
    return x;
  }
}

/// Deterministic nonzero coefficient vector for a parity packet.
Uint8List coefficientsForEsi(int esi, int genLen) {
  final rng = _Rng(esi * 0x9E3779B1 + 0x85EBCA77);
  final c = Uint8List(genLen);
  var nonzero = false;
  for (var i = 0; i < genLen; i++) {
    c[i] = 1 + rng.next() % 255; // dense, never zero
    nonzero = true;
  }
  assert(nonzero);
  return c;
}

/// Generation index a parity esi targets: round-robin over generations.
int generationForEsi(int esi, int blockCount) {
  final gens = (blockCount + generationSize - 1) ~/ generationSize;
  return (esi - blockCount) % gens;
}

class RlncEncoder {
  RlncEncoder(Uint8List data, {this.blockSize = 48})
      : assert(blockSize >= 31 && blockSize <= 55) {
    assert(_gfReady);
    final framedLen = 4 + data.length;
    blockCount = (framedLen + blockSize - 1) ~/ blockSize;
    if (blockCount > 0xFFFF) {
      throw ArgumentError('data too large for u16 blockCount');
    }
    final padded = Uint8List(blockCount * blockSize);
    padded.buffer.asByteData().setUint32(0, data.length);
    padded.setRange(4, 4 + data.length, data);
    _blocks = List.generate(blockCount,
        (i) => Uint8List.sublistView(padded, i * blockSize, (i + 1) * blockSize));
  }

  final int blockSize;
  late final int blockCount;
  late final List<Uint8List> _blocks;
  int _nextEsi = 0;

  (int start, int len) _genRange(int gen) {
    final start = gen * generationSize;
    final len = (start + generationSize) > blockCount
        ? blockCount - start
        : generationSize;
    return (start, len);
  }

  Uint8List datagramAt(int esi) {
    if (esi > 0xFFFF) throw ArgumentError('esi exceeds u16');
    final payload = Uint8List(blockSize);
    if (esi < blockCount) {
      payload.setAll(0, _blocks[esi]);
    } else {
      final gen = generationForEsi(esi, blockCount);
      final (start, len) = _genRange(gen);
      final coeffs = coefficientsForEsi(esi, len);
      for (var j = 0; j < len; j++) {
        final c = coeffs[j];
        if (c == 0) continue;
        final b = _blocks[start + j];
        for (var k = 0; k < blockSize; k++) {
          payload[k] ^= gfMul(c, b[k]);
        }
      }
    }
    final out = Uint8List(_headerBytes + blockSize + _crcBytes);
    final bd = out.buffer.asByteData();
    bd.setUint16(0, esi);
    bd.setUint16(2, blockCount);
    out.setRange(_headerBytes, _headerBytes + blockSize, payload);
    out[out.length - 1] = _crc8(out, out.length - 1);
    return out;
  }

  Uint8List nextDatagram() => datagramAt(_nextEsi++);
}

class _Generation {
  _Generation(this.start, this.len, int blockSize)
      : rows = List<Uint8List?>.filled(len, null),
        payloads = List<Uint8List?>.filled(len, null);

  final int start;
  final int len;
  // Row-reduced storage: rows[p] has leading (pivot) column p.
  final List<Uint8List?> rows;
  final List<Uint8List?> payloads;
  int rank = 0;
  bool solved = false;

  /// Incremental elimination. Returns true if rank increased.
  bool add(Uint8List coeffs, Uint8List payload, int blockSize) {
    if (solved) return false;
    final c = Uint8List.fromList(coeffs);
    final p = Uint8List.fromList(payload);
    for (var col = 0; col < len; col++) {
      if (c[col] == 0) continue;
      final pivot = rows[col];
      if (pivot == null) {
        // Normalize so the leading coefficient is 1, then store.
        final inv = gfInv(c[col]);
        for (var j = col; j < len; j++) {
          c[j] = gfMul(c[j], inv);
        }
        for (var k = 0; k < blockSize; k++) {
          p[k] = gfMul(p[k], inv);
        }
        rows[col] = c;
        payloads[col] = p;
        rank++;
        return true;
      }
      final f = c[col];
      for (var j = col; j < len; j++) {
        c[j] ^= gfMul(f, pivot[j]);
      }
      final pp = payloads[col]!;
      for (var k = 0; k < blockSize; k++) {
        p[k] ^= gfMul(f, pp[k]);
      }
    }
    return false; // linearly dependent
  }

  /// Back-substitute once rank == len; returns the decoded blocks.
  List<Uint8List> solve(int blockSize) {
    for (var col = len - 1; col >= 0; col--) {
      final row = rows[col]!;
      final pay = payloads[col]!;
      for (var r = 0; r < col; r++) {
        final f = rows[r]![col];
        if (f == 0) continue;
        rows[r]![col] = 0;
        final pr = payloads[r]!;
        for (var k = 0; k < blockSize; k++) {
          pr[k] ^= gfMul(f, pay[k]);
        }
      }
      // row[col] is 1 by construction.
      assert(row[col] == 1);
    }
    solved = true;
    return [for (var i = 0; i < len; i++) payloads[i]!];
  }
}

class RlncDecoder {
  RlncDecoder() {
    assert(_gfReady);
  }

  int? _blockCount;
  int? _blockSize;
  List<_Generation>? _gens;
  List<Uint8List?>? _decoded;
  int _decodedCount = 0;

  bool get isComplete =>
      _blockCount != null && _decodedCount == _blockCount;

  int get decodedBlockCount => _decodedCount;

  /// Buffered (not yet solved) rows across generations — bounded by
  /// blockCount: each generation stores at most `len` reduced rows.
  int get pendingRowCount {
    final gens = _gens;
    if (gens == null) return 0;
    var n = 0;
    for (final g in gens) {
      if (!g.solved) n += g.rank;
    }
    return n;
  }

  bool addDatagram(Uint8List datagram) {
    if (datagram.length < _headerBytes + 1 + _crcBytes) return false;
    if (datagram[datagram.length - 1] !=
        _crc8(datagram, datagram.length - 1)) {
      return false;
    }
    final bd =
        datagram.buffer.asByteData(datagram.offsetInBytes, datagram.length);
    final esi = bd.getUint16(0);
    final blockCount = bd.getUint16(2);
    final blockSize = datagram.length - _headerBytes - _crcBytes;
    if (blockCount == 0) return false;
    if (_blockCount == null) {
      _blockCount = blockCount;
      _blockSize = blockSize;
      _decoded = List<Uint8List?>.filled(blockCount, null);
      final gens = (blockCount + generationSize - 1) ~/ generationSize;
      _gens = List.generate(gens, (g) {
        final start = g * generationSize;
        final len = (start + generationSize) > blockCount
            ? blockCount - start
            : generationSize;
        return _Generation(start, len, blockSize);
      });
    } else if (blockCount != _blockCount || blockSize != _blockSize) {
      return false;
    }
    if (isComplete) return true;
    final payload = Uint8List.sublistView(
        datagram, _headerBytes, _headerBytes + blockSize);
    if (esi < blockCount) {
      // Systematic: a unit row for its generation.
      final gen = _gens![esi ~/ generationSize];
      if (gen.solved || _decoded![esi] != null) return true;
      final unit = Uint8List(gen.len);
      unit[esi - gen.start] = 1;
      if (gen.add(unit, payload, blockSize)) _tryFinish(gen);
    } else {
      final gen = _gens![generationForEsi(esi, blockCount)];
      if (gen.solved) return true;
      final coeffs = coefficientsForEsi(esi, gen.len);
      if (gen.add(coeffs, payload, blockSize)) _tryFinish(gen);
    }
    return true;
  }

  void _tryFinish(_Generation gen) {
    if (gen.rank < gen.len) return;
    final blocks = gen.solve(_blockSize!);
    for (var i = 0; i < gen.len; i++) {
      if (_decoded![gen.start + i] == null) {
        _decoded![gen.start + i] = blocks[i];
        _decodedCount++;
      }
    }
  }

  Uint8List get data {
    if (!isComplete) throw StateError('decode incomplete');
    final n = _blockCount!;
    final bs = _blockSize!;
    final all = Uint8List(n * bs);
    for (var i = 0; i < n; i++) {
      all.setRange(i * bs, (i + 1) * bs, _decoded![i]!);
    }
    final len = all.buffer.asByteData().getUint32(0);
    return Uint8List.sublistView(all, 4, 4 + len);
  }
}
