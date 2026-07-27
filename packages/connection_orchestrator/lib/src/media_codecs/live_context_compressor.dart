/// Live context-mixing compressor — original implementation, built for
/// this project (no zlib, no external codec, no dependency).
///
/// Architecture (our own, from first principles):
///   1. A bitwise binary arithmetic coder (32-bit carryless).
///   2. Six context models (orders 0-5): each hashes the last k bytes
///      plus the partial bits of the current byte into a probability
///      table that adapts per bit.
///   3. An adaptive logistic mixer: model predictions are mapped to the
///      logistic domain, combined with trained weights, and the mixed
///      probability drives the arithmetic coder. Weights update online
///      by gradient on coding loss, so the compressor LEARNS the stream
///      while compressing it — "live" in the literal sense: symmetric,
///      streaming, single pass, no pre-built dictionary.
///
/// Honest positioning: this family (context mixing) is the strongest
/// known general-purpose approach; this file is our own independent
/// design and code, tuned for the small documents this transport
/// carries. Every claimed number is measured by the tests, never quoted.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int _pBits = 12; // probabilities are 12-bit: 1..4095
const int _pOne = 1 << _pBits;

/// stretch(p) = ln(p/(1-p)) lookup, squash = inverse. Precomputed once.
final Float64List _stretchTable = (() {
  final t = Float64List(_pOne);
  for (var i = 1; i < _pOne; i++) {
    t[i] = math.log(i / (_pOne - i));
  }
  t[0] = t[1];
  return t;
})();

double _stretch(int p) => _stretchTable[p];

int _squash(double x) {
  if (x > 15) return _pOne - 1;
  if (x < -15) return 1;
  final p = (_pOne / (1 + math.exp(-x))).round();
  return p.clamp(1, _pOne - 1);
}

/// One hashed context model: a table of adaptive bit probabilities.
class _ContextModel {
  _ContextModel(this.order, int tableBits)
    : _table = Uint16List(1 << tableBits)
        ..fillRange(0, 1 << tableBits, _pOne >> 1),
      _mask = (1 << tableBits) - 1;

  final int order;
  final Uint16List _table;
  final int _mask;
  int _ctxHash = 0;
  int _slot = 0;

  /// Called once per byte boundary with the trailing byte history.
  void newByte(Uint8List history, int historyLen) {
    var h = order * 0x1000193;
    for (var k = 1; k <= order; k++) {
      final b = historyLen - k >= 0 ? history[(historyLen - k) & 0xFFFF] : 0;
      h = ((h ^ b) * 0x01000193) & 0x3FFFFFFF;
    }
    _ctxHash = h;
  }

  int predict(int partialByte) {
    _slot = (_ctxHash ^ (partialByte * 0x9E3779B1)) & _mask;
    return _table[_slot];
  }

  void update(int bit) {
    final p = _table[_slot];
    // Adaptive step: fast early, slow late (variable-rate counter).
    _table[_slot] = bit == 1 ? p + ((_pOne - p) >> 5) : p - (p >> 5);
  }
}

/// Adaptive logistic mixer over the model predictions.
class _Mixer {
  _Mixer(int n, int sets)
    : _n = n,
      _w = Float64List(n * sets)..fillRange(0, n * sets, 0.3),
      _t = Float64List(n);

  final int _n;
  final Float64List _w;
  final Float64List _t;
  double _p = 0.5;
  int _base = 0;

  /// [set] selects an independent weight vector (e.g. match-active vs
  /// not) so the mixer does not average away regime-specific trust.
  int mix(List<int> preds, int set) {
    _base = set * _n;
    var dot = 0.0;
    for (var i = 0; i < _n; i++) {
      _t[i] = _stretch(preds[i]);
      dot += _w[_base + i] * _t[i];
    }
    final p = _squash(dot);
    _p = p / _pOne;
    return p;
  }

  void update(int bit) {
    final err = bit - _p;
    const lr = 0.02;
    for (var i = 0; i < _n; i++) {
      _w[_base + i] += lr * err * _t[i];
    }
  }
}

/// Adaptive probability map (SSE): refines the mixer's output using a
/// small table indexed by (context, quantized stretch(p)), interpolating
/// between neighboring bins. Corrects systematic mixer bias.
class _Apm {
  _Apm(int contexts) : _t = Uint16List(contexts * 33) {
    for (var c = 0; c < contexts; c++) {
      for (var i = 0; i < 33; i++) {
        _t[c * 33 + i] = _squash((i - 16) / 2.0);
      }
    }
  }

  final Uint16List _t;
  int _idx = 0;
  int _w = 0;

  int refine(int p, int context) {
    final s = _stretch(p);
    final x = ((s.clamp(-8.0, 8.0) + 8) * 2); // 0..32
    final lo = x.floor().clamp(0, 31);
    _w = ((x - lo) * 64).round().clamp(0, 64);
    _idx = context * 33 + lo;
    final v = (_t[_idx] * (64 - _w) + _t[_idx + 1] * _w) >> 6;
    return v.clamp(1, _pOne - 1);
  }

  void update(int bit) {
    final target = bit == 1 ? _pOne - 1 : 0;
    _t[_idx] = (_t[_idx] + ((target - _t[_idx]) >> 6)) & 0xFFFF;
    _t[_idx + 1] = (_t[_idx + 1] + ((target - _t[_idx + 1]) >> 6)) & 0xFFFF;
  }
}

/// Shared model pipeline so encoder and decoder stay bit-identical.
class _Pipeline {
  _Pipeline()
    : _models = [
        _ContextModel(0, 9),
        _ContextModel(1, 16),
        _ContextModel(2, 18),
        _ContextModel(3, 18),
        _ContextModel(4, 18),
        _ContextModel(5, 18),
      ],
      _mixer = _Mixer(7, 4);

  final List<_ContextModel> _models;
  final _Mixer _mixer;
  final Uint8List _history = Uint8List(1 << 16);
  int _historyLen = 0;
  final List<int> _preds = List.filled(7, 0);

  // Match model: finds the most recent occurrence of the current 4-byte
  // context and predicts the byte that followed it — this is what wins
  // on long exact repeats, where pure context models plateau.
  final Uint32List _matchTable = Uint32List(1 << 16);
  int _matchPos = -1; // absolute position of predicted next byte
  int _matchLen = 0;
  int _expectedByte = 0;

  int get _h4 {
    var h = 0x811C9DC5;
    for (var k = 1; k <= 4; k++) {
      final b = _historyLen - k >= 0 ? _history[(_historyLen - k) & 0xFFFF] : 0;
      h = ((h ^ b) * 0x01000193) & 0x3FFFFFFF;
    }
    return h & 0xFFFF;
  }

  void newByte() {
    for (final m in _models) {
      m.newByte(_history, _historyLen);
    }
    if (_matchLen > 0 && _matchPos < _historyLen) {
      _expectedByte = _history[_matchPos & 0xFFFF];
    } else {
      _matchLen = 0;
    }
  }

  int predict(int partialByte) {
    for (var i = 0; i < _models.length; i++) {
      _preds[i] = _models[i].predict(partialByte);
    }
    var matchP = _pOne >> 1;
    if (_matchLen > 0) {
      // partialByte = 1-prefixed bits seen so far; verify consistency.
      final bitsSeen = partialByte.bitLength - 1;
      final seen = partialByte - (1 << bitsSeen);
      if (bitsSeen > 0 && (_expectedByte >> (8 - bitsSeen)) != seen) {
        _matchLen = 0;
      } else {
        final nextBit = (_expectedByte >> (7 - bitsSeen)) & 1;
        final conf = _matchLen > 64 ? 64 : _matchLen;
        final off = 1 + _pOne ~/ (2 + 4 * conf * conf);
        matchP = nextBit == 1 ? _pOne - off : off;
      }
    }
    _preds[6] = matchP.clamp(1, _pOne - 1);
    // Weight-set selection: 0 = no match, 1-3 by match strength.
    final set = _matchLen == 0
        ? 0
        : _matchLen < 8
        ? 1
        : _matchLen < 32
        ? 2
        : 3;
    final mixed = _mixer.mix(_preds, set);
    final lastByte = _historyLen > 0 ? _history[(_historyLen - 1) & 0xFFFF] : 0;
    return _apm.refine(mixed, lastByte);
  }

  final _Apm _apm = _Apm(256);

  void update(int bit) {
    for (final m in _models) {
      m.update(bit);
    }
    _mixer.update(bit);
    _apm.update(bit);
  }

  void pushByte(int byte) {
    if (_matchLen > 0) {
      if (byte == _expectedByte) {
        _matchPos++;
        _matchLen++;
      } else {
        _matchLen = 0;
      }
    }
    _history[_historyLen & 0xFFFF] = byte;
    _historyLen++;
    if (_historyLen >= 4) {
      final h = _h4;
      // Seek BEFORE overwriting: the stored entry is a PRIOR occurrence
      // of this 4-byte context (reading after the store would only ever
      // find ourselves, which silently disables the match model).
      if (_matchLen == 0) {
        final cand = _matchTable[h];
        if (cand > 0 &&
            cand - 1 < _historyLen &&
            _historyLen - (cand - 1) <= 0xFFFF) {
          _matchPos = cand - 1;
          _matchLen = 1;
        }
      }
      _matchTable[h] = _historyLen + 1; // (position of next byte) + 1
    }
  }
}

class LiveContextCompressor {
  const LiveContextCompressor();

  /// Compress [data]. Output: u32 length header + arithmetic-coded body.
  Uint8List compress(Uint8List data) {
    final pipe = _Pipeline();
    final out = BytesBuilder();
    var x1 = 0;
    var x2 = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      pipe.newByte();
      final byte = data[i];
      var partial = 1;
      for (var b = 7; b >= 0; b--) {
        final bit = (byte >> b) & 1;
        final p = pipe.predict(partial);
        final xmid = x1 + (((x2 - x1) * p) >> _pBits);
        if (bit == 1) {
          x2 = xmid;
        } else {
          x1 = xmid + 1;
        }
        while (((x1 ^ x2) & 0xFF000000) == 0) {
          out.addByte((x2 >> 24) & 0xFF);
          x1 = (x1 << 8) & 0xFFFFFFFF;
          x2 = ((x2 << 8) | 0xFF) & 0xFFFFFFFF;
        }
        pipe.update(bit);
        partial = (partial << 1) | bit;
      }
      pipe.pushByte(byte);
    }
    // Flush.
    for (var k = 0; k < 4; k++) {
      out.addByte((x1 >> 24) & 0xFF);
      x1 = (x1 << 8) & 0xFFFFFFFF;
    }
    final body = out.toBytes();
    final framed = Uint8List(4 + body.length);
    framed.buffer.asByteData().setUint32(0, data.length);
    framed.setRange(4, framed.length, body);
    return framed;
  }

  Uint8List decompress(Uint8List compressed) {
    final length = compressed.buffer
        .asByteData(compressed.offsetInBytes)
        .getUint32(0);
    final body = Uint8List.sublistView(compressed, 4);
    final pipe = _Pipeline();
    final out = Uint8List(length);
    var pos = 0;
    int nextByte() => pos < body.length ? body[pos++] : 0;
    var x1 = 0;
    var x2 = 0xFFFFFFFF;
    var x = 0;
    for (var k = 0; k < 4; k++) {
      x = ((x << 8) | nextByte()) & 0xFFFFFFFF;
    }
    for (var i = 0; i < length; i++) {
      pipe.newByte();
      var partial = 1;
      for (var b = 7; b >= 0; b--) {
        final p = pipe.predict(partial);
        final xmid = x1 + (((x2 - x1) * p) >> _pBits);
        int bit;
        if (x <= xmid) {
          bit = 1;
          x2 = xmid;
        } else {
          bit = 0;
          x1 = xmid + 1;
        }
        while (((x1 ^ x2) & 0xFF000000) == 0) {
          x1 = (x1 << 8) & 0xFFFFFFFF;
          x2 = ((x2 << 8) | 0xFF) & 0xFFFFFFFF;
          x = ((x << 8) | nextByte()) & 0xFFFFFFFF;
        }
        pipe.update(bit);
        partial = (partial << 1) | bit;
      }
      final byte = partial & 0xFF;
      out[i] = byte;
      pipe.pushByte(byte);
    }
    return out;
  }
}
