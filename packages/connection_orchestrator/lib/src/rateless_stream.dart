/// Rateless (LT / Luby-transform) erasure code with a systematic prefix.
///
/// Wire format per datagram (36-60 bytes total for block sizes 31-55):
///   u16 esi (big-endian) · u16 blockCount (big-endian) · payload · u8 crc8
///
/// Datagrams with esi < blockCount carry the source block itself
/// (systematic prefix). Datagrams with esi >= blockCount carry an XOR
/// parity over a pseudo-random subset of source blocks; the subset is
/// derived deterministically from the esi, so encoder and decoder need
/// no coordination and the receiver never sends feedback.
///
/// The source data is framed internally as [u32 length][data][zero pad]
/// so the decoder recovers the exact byte length without extra wire
/// fields. CRC-8 uses polynomial 0x07 (CRC-8/ATM); this is the only CRC
/// in the stack — the padding lane (micro_datagram_lane) carries no CRC,
/// so its decode failures must be surfaced upstream, not inferred here.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int _headerBytes = 4; // esi + blockCount
const int _crcBytes = 1;

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

/// Deterministic PRNG (xorshift32) so encoder and decoder derive the
/// same parity subsets from the same esi.
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

  /// Uniform integer in [0, n).
  int nextInt(int n) => next() % n;

  /// Uniform double in [0, 1).
  double nextDouble() => next() / 4294967296.0;
}

/// Robust soliton degree distribution CDF for [blockCount] blocks
/// (c = 0.1, delta = 0.5).
List<double> _robustSolitonCdf(int n) {
  if (n == 1) return const [1.0];
  const c = 0.1;
  const delta = 0.5;
  final r = c * math.log(n / delta) * math.sqrt(n);
  final pivot = (n / r).floor().clamp(1, n);
  final rho = List<double>.filled(n + 1, 0);
  rho[1] = 1 / n;
  for (var d = 2; d <= n; d++) {
    rho[d] = 1 / (d * (d - 1));
  }
  final tau = List<double>.filled(n + 1, 0);
  for (var d = 1; d < pivot; d++) {
    tau[d] = r / (d * n);
  }
  if (pivot >= 1 && pivot <= n) tau[pivot] = r * math.log(r / delta) / n;
  var z = 0.0;
  for (var d = 1; d <= n; d++) {
    z += rho[d] + tau[d];
  }
  final cdf = List<double>.filled(n, 0);
  var acc = 0.0;
  for (var d = 1; d <= n; d++) {
    acc += (rho[d] + tau[d]) / z;
    cdf[d - 1] = acc;
  }
  cdf[n - 1] = 1.0;
  return cdf;
}

/// Derive the parity neighbor set for [esi] (>= blockCount).
List<int> neighborsForEsi(int esi, int blockCount, List<double> cdf) {
  final rng = _Rng(esi * 0x9E3779B1 + 0x85EBCA77);
  final u = rng.nextDouble();
  var degree = 1;
  while (degree < blockCount && cdf[degree - 1] < u) {
    degree++;
  }
  final picked = <int>{};
  while (picked.length < degree) {
    picked.add(rng.nextInt(blockCount));
  }
  return picked.toList()..sort();
}

class RatelessEncoder {
  RatelessEncoder(Uint8List data, {this.blockSize = 48})
      : assert(blockSize >= 31 && blockSize <= 55,
            'datagram must stay within 36-60 bytes') {
    final framedLen = 4 + data.length;
    blockCount = (framedLen + blockSize - 1) ~/ blockSize;
    if (blockCount > 0xFFFF) {
      throw ArgumentError('data too large for u16 blockCount');
    }
    final padded = Uint8List(blockCount * blockSize);
    padded.buffer.asByteData().setUint32(0, data.length);
    padded.setRange(4, 4 + data.length, data);
    _blocks = List.generate(
        blockCount,
        (i) => Uint8List.sublistView(
            padded, i * blockSize, (i + 1) * blockSize));
    _cdf = _robustSolitonCdf(blockCount);
  }

  final int blockSize;
  late final int blockCount;
  late final List<Uint8List> _blocks;
  late final List<double> _cdf;
  int _nextEsi = 0;

  /// Deterministic datagram for a given esi (0-based, unbounded).
  Uint8List datagramAt(int esi) {
    if (esi > 0xFFFF) throw ArgumentError('esi exceeds u16');
    final payload = Uint8List(blockSize);
    if (esi < blockCount) {
      payload.setAll(0, _blocks[esi]);
    } else {
      for (final i in neighborsForEsi(esi, blockCount, _cdf)) {
        final b = _blocks[i];
        for (var k = 0; k < blockSize; k++) {
          payload[k] ^= b[k];
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

  /// Next datagram in sequence: systematic blocks first, then parity.
  Uint8List nextDatagram() => datagramAt(_nextEsi++);
}

class RatelessDecoder {
  RatelessDecoder();

  int? _blockCount;
  int? _blockSize;
  List<Uint8List?>? _decoded;
  int _decodedCount = 0;
  List<double>? _cdf;
  final List<_PendingSymbol> _pending = [];

  bool get isComplete =>
      _blockCount != null && _decodedCount == _blockCount;

  /// Number of buffered coded symbols (bounded: never exceeds blockCount).
  int get pendingSymbolCount => _pending.length;

  int get decodedBlockCount => _decodedCount;

  /// Datagrams rejected because the trailing CRC-8 did not match.
  int get crcRejectCount => _crcRejectCount;
  int _crcRejectCount = 0;

  /// Datagrams rejected for structural reasons (too short, zero
  /// blockCount, or blockCount/blockSize disagreeing with the stream).
  int get structuralRejectCount => _structuralRejectCount;
  int _structuralRejectCount = 0;

  /// Feed one datagram. Returns true if it was accepted (CRC valid and
  /// structurally sound). Rejections are counted in [crcRejectCount] /
  /// [structuralRejectCount] so upstream telemetry can distinguish real
  /// channel loss from framing corruption instead of absorbing both
  /// silently.
  bool addDatagram(Uint8List datagram) {
    if (datagram.length < _headerBytes + 1 + _crcBytes) {
      _structuralRejectCount++;
      return false;
    }
    if (datagram[datagram.length - 1] !=
        _crc8(datagram, datagram.length - 1)) {
      _crcRejectCount++;
      return false;
    }
    final bd = datagram.buffer
        .asByteData(datagram.offsetInBytes, datagram.length);
    final esi = bd.getUint16(0);
    final blockCount = bd.getUint16(2);
    final blockSize = datagram.length - _headerBytes - _crcBytes;
    if (blockCount == 0) {
      _structuralRejectCount++;
      return false;
    }
    if (_blockCount == null) {
      _blockCount = blockCount;
      _blockSize = blockSize;
      _decoded = List<Uint8List?>.filled(blockCount, null);
      _cdf = _robustSolitonCdf(blockCount);
    } else if (blockCount != _blockCount || blockSize != _blockSize) {
      _structuralRejectCount++;
      return false;
    }
    if (isComplete) return true;
    final payload = Uint8List.fromList(
        datagram.sublist(_headerBytes, _headerBytes + blockSize));
    if (esi < blockCount) {
      _release(esi, payload);
    } else {
      final idx = <int>{};
      for (final i in neighborsForEsi(esi, blockCount, _cdf!)) {
        if (_decoded![i] != null) {
          _xorInto(payload, _decoded![i]!);
        } else {
          idx.add(i);
        }
      }
      if (idx.isEmpty) return true; // fully redundant
      if (idx.length == 1) {
        _release(idx.first, payload);
      } else {
        _store(_PendingSymbol(idx, payload));
      }
    }
    return true;
  }

  /// Recovered data; only valid when [isComplete].
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

  void _store(_PendingSymbol s) {
    for (final p in _pending) {
      if (p.idx.length == s.idx.length && p.idx.containsAll(s.idx)) {
        return; // duplicate coverage
      }
    }
    if (_pending.length >= _blockCount!) {
      // Bounded memory: drop the highest-degree symbol.
      var worst = 0;
      for (var i = 1; i < _pending.length; i++) {
        if (_pending[i].idx.length > _pending[worst].idx.length) worst = i;
      }
      if (_pending[worst].idx.length <= s.idx.length) return;
      _pending.removeAt(worst);
    }
    _pending.add(s);
  }

  void _release(int index, Uint8List block) {
    if (_decoded![index] != null) return;
    var frontier = <int, Uint8List>{index: block};
    while (frontier.isNotEmpty) {
      final next = <int, Uint8List>{};
      frontier.forEach((i, data) {
        if (_decoded![i] != null) return;
        _decoded![i] = data;
        _decodedCount++;
        for (var p = _pending.length - 1; p >= 0; p--) {
          final sym = _pending[p];
          if (sym.idx.remove(i)) {
            _xorInto(sym.data, data);
            if (sym.idx.length == 1) {
              final only = sym.idx.first;
              _pending.removeAt(p);
              if (_decoded![only] == null && !next.containsKey(only)) {
                next[only] = sym.data;
              }
            } else if (sym.idx.isEmpty) {
              _pending.removeAt(p);
            }
          }
        }
      });
      frontier = next;
    }
    if (isComplete) _pending.clear();
  }

  static void _xorInto(Uint8List target, Uint8List other) {
    for (var k = 0; k < target.length; k++) {
      target[k] ^= other[k];
    }
  }
}

class _PendingSymbol {
  _PendingSymbol(this.idx, this.data);
  final Set<int> idx;
  final Uint8List data;
}
