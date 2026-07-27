/// Lossless per-contact adaptive token codec for neural voice streams.
///
/// Port of the verified Python reference (`tools/hamseda_arith.py`):
/// persistent column dictionary + PPM-C order-1 row models over a
/// Subbotin carryless range coder. Encoder and decoder run the identical
/// deterministic update rule, so the shared state needs zero sync bytes.
library;

import 'dart:typed_data';

const int _mask = 0xFFFFFFFF;
const int _top = 1 << 24;
const int _bot = 1 << 16;

/// Codebook id width of the wire alphabet (EnCodec: 1024 ids per row).
const int rawSymbols = 1024;

/// Deterministic growth bounds (identical on both ends, so capping can
/// never diverge state): once full, novel columns stop entering the
/// dictionary (they still transmit via row models) and novel order-2
/// contexts stop opening tables (their frames code through order-1).
/// Overridable for tests only.
int maxDictEntries = 4096;
int maxCtx2Tables = 16384;

/// Context id for a column outside the capped dictionary.
const int unknownId = -2;

class _RangeEncoder {
  int _low = 0;
  int _range = _mask;
  final BytesBuilder _out = BytesBuilder();

  void _normalize() {
    while (true) {
      if ((_low ^ ((_low + _range) & _mask)) < _top) {
        // top byte settled — emit it
      } else if (_range < _bot) {
        _range = (-_low) & (_bot - 1);
      } else {
        break;
      }
      _out.addByte((_low >> 24) & 0xFF);
      _low = (_low << 8) & _mask;
      _range = (_range << 8) & _mask;
    }
  }

  void encode(int cum, int freq, int tot) {
    final r = _range ~/ tot;
    _low = (_low + r * cum) & _mask;
    _range = r * freq;
    _normalize();
  }

  Uint8List finish() {
    for (var i = 0; i < 4; i++) {
      _out.addByte((_low >> 24) & 0xFF);
      _low = (_low << 8) & _mask;
    }
    return _out.takeBytes();
  }
}

class _RangeDecoder {
  final Uint8List _data;
  int _pos = 4;
  int _low = 0;
  int _range = _mask;
  int _code;
  int _r = 1;

  _RangeDecoder(Uint8List data)
    : _data = Uint8List(data.length + 8)..setRange(0, data.length, data),
      _code = 0 {
    _code = (_data[0] << 24) | (_data[1] << 16) | (_data[2] << 8) | _data[3];
  }

  void _normalize() {
    while (true) {
      if ((_low ^ ((_low + _range) & _mask)) < _top) {
        // top byte settled — pull the next
      } else if (_range < _bot) {
        _range = (-_low) & (_bot - 1);
      } else {
        break;
      }
      _code = ((_code << 8) | _data[_pos]) & _mask;
      _pos += 1;
      _low = (_low << 8) & _mask;
      _range = (_range << 8) & _mask;
    }
  }

  int decodeFreq(int tot) {
    _r = _range ~/ tot;
    final v = ((_code - _low) & _mask) ~/ _r;
    return v < tot - 1 ? v : tot - 1;
  }

  void consume(int cum, int freq) {
    _low = (_low + _r * cum) & _mask;
    _range = _r * freq;
    _normalize();
  }
}

/// Adaptive frequency table with a PPM-C escape symbol (id -1):
/// escape mass tracks the number of distinct symbols seen.
class FreqTable {
  final Map<int, int> freq;
  int total;

  FreqTable() : freq = {-1: 1}, total = 1;

  FreqTable._(this.freq, this.total);

  FreqTable clone() => FreqTable._(Map.of(freq), total);

  Map<String, dynamic> toJson() => {
    'f': freq.map((k, v) => MapEntry('$k', v)),
    't': total,
  };

  factory FreqTable.fromJson(Map<String, dynamic> j) => FreqTable._(
    (j['f'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(int.parse(k), v as int),
    ),
    j['t'] as int,
  );

  void add(int sym) {
    if (!freq.containsKey(sym)) {
      freq[-1] = freq[-1]! + 1;
      total += 1;
    }
    freq[sym] = (freq[sym] ?? 0) + 32;
    total += 32;
    if (total >= 1 << 16) {
      var newTotal = 0;
      for (final s in freq.keys.toList()) {
        final nf = freq[s]! ~/ 2 < 1 ? 1 : freq[s]! ~/ 2;
        freq[s] = nf;
        newTotal += nf;
      }
      total = newTotal;
    }
  }

  bool has(int sym) => freq.containsKey(sym);

  List<int> _sortedKeys() {
    final ks = freq.keys.toList()..sort();
    return ks;
  }

  /// (cum, freq, total) for [sym]; sym must be present.
  (int, int, int) interval(int sym) {
    var cum = 0;
    for (final s in _sortedKeys()) {
      if (s == sym) return (cum, freq[s]!, total);
      cum += freq[s]!;
    }
    throw StateError('symbol $sym not in table');
  }

  /// (sym, cum, freq, total) at cumulative [point].
  (int, int, int, int) symbolAt(int point) {
    var cum = 0;
    for (final s in _sortedKeys()) {
      final f = freq[s]!;
      if (point < cum + f) return (s, cum, f, total);
      cum += f;
    }
    throw StateError('point $point outside table (corrupt input?)');
  }
}

/// Order-1 model for one codebook row: context tables with escape to a
/// global table with escape to uniform raw.
class RowModel {
  final Map<int, FreqTable> ctx;
  final FreqTable glob;

  RowModel() : ctx = {}, glob = FreqTable();

  RowModel._(this.ctx, this.glob);

  RowModel clone() =>
      RowModel._(ctx.map((k, v) => MapEntry(k, v.clone())), glob.clone());

  Map<String, dynamic> toJson() => {
    'c': ctx.map((k, v) => MapEntry('$k', v.toJson())),
    'g': glob.toJson(),
  };

  factory RowModel.fromJson(Map<String, dynamic> j) => RowModel._(
    (j['c'] as Map<String, dynamic>).map(
      (k, v) =>
          MapEntry(int.parse(k), FreqTable.fromJson(v as Map<String, dynamic>)),
    ),
    FreqTable.fromJson(j['g'] as Map<String, dynamic>),
  );

  FreqTable tablesFor(int prev) => ctx.putIfAbsent(prev, FreqTable.new);

  void update(int prev, int sym) {
    tablesFor(prev).add(sym);
    glob.add(sym);
  }
}

/// Persistent per-contact dictionary of full token columns.
class ColumnDict {
  final Map<String, int> byCol;
  final List<List<int>> cols;
  final FreqTable table;

  ColumnDict() : byCol = {}, cols = [], table = FreqTable();

  ColumnDict._(this.byCol, this.cols, this.table);

  static String _key(List<int> col) => col.join(',');

  ColumnDict clone() => ColumnDict._(Map.of(byCol), [
    for (final c in cols) List.of(c),
  ], table.clone());

  Map<String, dynamic> toJson() => {'cols': cols, 'table': table.toJson()};

  factory ColumnDict.fromJson(Map<String, dynamic> j) {
    final cols = [for (final c in j['cols'] as List) List<int>.from(c as List)];
    final d = ColumnDict._(
      {for (var i = 0; i < cols.length; i++) _key(cols[i]): i},
      cols,
      FreqTable.fromJson(j['table'] as Map<String, dynamic>),
    );
    return d;
  }

  int? idOf(List<int> col) => byCol[_key(col)];

  void add(List<int> col) {
    final k = _key(col);
    var id = byCol[k];
    if (id == null) {
      id = cols.length;
      byCol[k] = id;
      cols.add(List.of(col));
    }
    table.add(id);
  }
}

/// The full deterministic shared state of one contact relationship.
///
/// v4 model: the column id is coded in the frequency table of the
/// PREVIOUS column id ([ctx]), escaping to the global column table,
/// escaping to per-row order-1 symbols.
class HamsedaState {
  final List<RowModel> models;
  final ColumnDict dict;
  final Map<int, FreqTable> ctx;
  final Map<String, FreqTable> ctx2; // 'prev2,prev1' -> table of ids

  HamsedaState(int nRows)
    : models = [for (var i = 0; i < nRows; i++) RowModel()],
      dict = ColumnDict(),
      ctx = {},
      ctx2 = {};

  HamsedaState._(this.models, this.dict, this.ctx, this.ctx2);

  int get nRows => models.length;

  FreqTable ctxTable(int prevId) => ctx.putIfAbsent(prevId, FreqTable.new);

  /// Returns null once the ctx2 cap is reached and this key is new —
  /// the frame then codes through order-1 (same rule on both ends).
  FreqTable? ctx2Table(int p2, int p1) {
    final key = '$p2,$p1';
    final existing = ctx2[key];
    if (existing != null) return existing;
    if (ctx2.length >= maxCtx2Tables) return null;
    final t = FreqTable();
    ctx2[key] = t;
    return t;
  }

  HamsedaState clone() => HamsedaState._(
    [for (final m in models) m.clone()],
    dict.clone(),
    ctx.map((k, v) => MapEntry(k, v.clone())),
    ctx2.map((k, v) => MapEntry(k, v.clone())),
  );

  Map<String, dynamic> toJson() => {
    'models': [for (final m in models) m.toJson()],
    'dict': dict.toJson(),
    'ctx': ctx.map((k, v) => MapEntry('$k', v.toJson())),
    'ctx2': ctx2.map((k, v) => MapEntry(k, v.toJson())),
  };

  factory HamsedaState.fromJson(Map<String, dynamic> j) => HamsedaState._(
    [
      for (final m in j['models'] as List)
        RowModel.fromJson(m as Map<String, dynamic>),
    ],
    ColumnDict.fromJson(j['dict'] as Map<String, dynamic>),
    ((j['ctx'] ?? <String, dynamic>{}) as Map<String, dynamic>).map(
      (k, v) =>
          MapEntry(int.parse(k), FreqTable.fromJson(v as Map<String, dynamic>)),
    ),
    ((j['ctx2'] ?? <String, dynamic>{}) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, FreqTable.fromJson(v as Map<String, dynamic>)),
    ),
  );
}

/// Applies exactly the state mutations encoding [col] would, without
/// producing bits — shared by the raw-fallback path on both ends.
int _learnColumn(
  HamsedaState st,
  FreqTable? t2,
  FreqTable t1,
  int? cidBefore,
  List<int> col,
) {
  if (cidBefore != null) {
    t2?.add(cidBefore);
    t1.add(cidBefore);
    st.dict.add(col); // bump the existing id's global frequency
    return cidBefore;
  }
  if (st.dict.cols.length >= maxDictEntries) {
    return unknownId; // capped: column stays outside the dictionary
  }
  st.dict.add(col);
  final newId = st.dict.idOf(col)!;
  t2?.add(newId);
  t1.add(newId);
  return newId;
}

void _updateWalk(List<List<int>> cols, HamsedaState st) {
  List<int>? prev;
  var p1 = -1;
  var p2 = -1;
  for (final col in cols) {
    final cid = st.dict.idOf(col);
    final t2 = st.ctx2Table(p2, p1);
    final t1 = st.ctxTable(p1);
    final hit =
        cid != null &&
        ((t2?.has(cid) ?? false) || t1.has(cid) || st.dict.table.has(cid));
    if (!hit) {
      for (var row = 0; row < col.length; row++) {
        st.models[row].update(prev?[row] ?? -1, col[row]);
      }
    }
    prev = col;
    p2 = p1;
    p1 = _learnColumn(st, t2, t1, cid, col);
  }
}

void _encSymbol(_RangeEncoder w, RowModel m, int prev, int sym) {
  final t = m.tablesFor(prev);
  if (t.has(sym)) {
    final (cum, f, tot) = t.interval(sym);
    w.encode(cum, f, tot);
  } else {
    final (cum, f, tot) = t.interval(-1);
    w.encode(cum, f, tot);
    if (m.glob.has(sym)) {
      final (gc, gf, gt) = m.glob.interval(sym);
      w.encode(gc, gf, gt);
    } else {
      final (gc, gf, gt) = m.glob.interval(-1);
      w.encode(gc, gf, gt);
      w.encode(sym, 1, rawSymbols);
    }
  }
  m.update(prev, sym);
}

int _decSymbol(_RangeDecoder r, RowModel m, int prev) {
  final t = m.tablesFor(prev);
  var (sym, cum, f, _) = t.symbolAt(r.decodeFreq(t.total));
  r.consume(cum, f);
  if (sym == -1) {
    final g = m.glob;
    final (gs, gc, gf, _) = g.symbolAt(r.decodeFreq(g.total));
    r.consume(gc, gf);
    sym = gs;
    if (sym == -1) {
      sym = r.decodeFreq(rawSymbols);
      r.consume(sym, 1);
    }
  }
  m.update(prev, sym);
  return sym;
}

/// Encodes [columns] against (and mutating) [state]. Symmetric with
/// [decodeColumns]: running both from equal states keeps them equal.
///
/// Worst-case cap: the adaptive stream is compared against packed raw
/// tokens; the smaller ships behind a 1-byte flag, so a cold call never
/// costs more than raw + 1 byte. State learns identically on both paths.
Uint8List encodeColumns(List<List<int>> columns, HamsedaState state) {
  for (final col in columns) {
    if (col.length != state.nRows) {
      throw ArgumentError('column arity ${col.length} != ${state.nRows}');
    }
  }
  final work = state.clone();
  final adaptive = _encodeAdaptive(columns, work);
  final rawBits = columns.length * state.nRows * 10;
  if (adaptive.length * 8 <= rawBits) {
    state.models.setAll(0, work.models);
    state.dict.byCol
      ..clear()
      ..addAll(work.dict.byCol);
    state.dict.cols
      ..clear()
      ..addAll(work.dict.cols);
    state.dict.table.freq
      ..clear()
      ..addAll(work.dict.table.freq);
    state.dict.table.total = work.dict.table.total;
    state.ctx
      ..clear()
      ..addAll(work.ctx);
    state.ctx2
      ..clear()
      ..addAll(work.ctx2);
    return Uint8List.fromList([1, ...adaptive]);
  }
  // plain 10-bit packing: exact raw cost, zero coder overhead
  final out = BytesBuilder()..addByte(0);
  var acc = 0;
  var nbits = 0;
  for (final col in columns) {
    for (final sym in col) {
      acc = (acc << 10) | sym;
      nbits += 10;
      while (nbits >= 8) {
        nbits -= 8;
        out.addByte((acc >> nbits) & 0xFF);
      }
    }
  }
  if (nbits > 0) out.addByte((acc << (8 - nbits)) & 0xFF);
  _updateWalk(columns, state);
  return out.takeBytes();
}

Uint8List _encodeAdaptive(List<List<int>> columns, HamsedaState st) {
  final w = _RangeEncoder();
  List<int>? prev;
  var p1 = -1;
  var p2 = -1;
  for (final col in columns) {
    final cid = st.dict.idOf(col);
    final t2 = st.ctx2Table(p2, p1);
    final t1 = st.ctxTable(p1);
    if (cid != null && t2 != null && t2.has(cid)) {
      final (cum, f, tot) = t2.interval(cid);
      w.encode(cum, f, tot);
    } else {
      if (t2 != null) {
        final (cum, f, tot) = t2.interval(-1);
        w.encode(cum, f, tot);
      }
      if (cid != null && t1.has(cid)) {
        final (c1, f1, n1) = t1.interval(cid);
        w.encode(c1, f1, n1);
      } else {
        final (c1, f1, n1) = t1.interval(-1);
        w.encode(c1, f1, n1);
        if (cid != null && st.dict.table.has(cid)) {
          final (gc, gf, gt) = st.dict.table.interval(cid);
          w.encode(gc, gf, gt);
        } else {
          final (gc, gf, gt) = st.dict.table.interval(-1);
          w.encode(gc, gf, gt);
          for (var row = 0; row < col.length; row++) {
            _encSymbol(w, st.models[row], prev?[row] ?? -1, col[row]);
          }
        }
      }
    }
    prev = col;
    p2 = p1;
    p1 = _learnColumn(st, t2, t1, cid, col);
  }
  return w.finish();
}

/// Decodes [nFrames] columns from [data] against (and mutating) [state].
List<List<int>> decodeColumns(Uint8List data, int nFrames, HamsedaState state) {
  if (data.isEmpty) throw StateError('empty stream');
  final flag = data[0];
  final body = Uint8List.sublistView(data, 1);
  if (flag == 1) return _decodeAdaptive(body, nFrames, state);
  if (flag != 0) throw StateError('corrupt stream: unknown flag byte');
  var acc = 0;
  var nbits = 0;
  var pos = 0;
  final cols = <List<int>>[];
  for (var i = 0; i < nFrames; i++) {
    final col = <int>[];
    for (var row = 0; row < state.nRows; row++) {
      while (nbits < 10) {
        if (pos >= body.length) throw StateError('truncated raw stream');
        acc = (acc << 8) | body[pos];
        pos += 1;
        nbits += 8;
      }
      nbits -= 10;
      col.add((acc >> nbits) & 0x3FF);
    }
    cols.add(col);
  }
  _updateWalk(cols, state);
  return cols;
}

List<int> _dictColAt(HamsedaState st, int id) {
  if (id >= st.dict.cols.length) {
    throw StateError('dictionary id $id out of range (corrupt input?)');
  }
  return List.of(st.dict.cols[id]);
}

List<List<int>> _decodeAdaptive(Uint8List data, int nFrames, HamsedaState st) {
  final r = _RangeDecoder(data);
  final out = <List<int>>[];
  List<int>? prev;
  var p1 = -1;
  var p2 = -1;
  for (var i = 0; i < nFrames; i++) {
    final t2 = st.ctx2Table(p2, p1);
    final t1 = st.ctxTable(p1);
    int sym;
    if (t2 != null) {
      final (s, cum, f, _) = t2.symbolAt(r.decodeFreq(t2.total));
      r.consume(cum, f);
      sym = s;
    } else {
      sym = -1; // capped: level 2 was never coded
    }
    List<int> col;
    int? cid;
    if (sym != -1) {
      col = _dictColAt(st, sym);
      cid = sym;
    } else {
      final (s1, c1, f1, _) = t1.symbolAt(r.decodeFreq(t1.total));
      r.consume(c1, f1);
      if (s1 != -1) {
        col = _dictColAt(st, s1);
        cid = s1;
      } else {
        final g = st.dict.table;
        final (gs, gc, gf, _) = g.symbolAt(r.decodeFreq(g.total));
        r.consume(gc, gf);
        if (gs != -1) {
          col = _dictColAt(st, gs);
          cid = gs;
        } else {
          col = [
            for (var row = 0; row < st.nRows; row++)
              _decSymbol(r, st.models[row], prev?[row] ?? -1),
          ];
          cid = st.dict.idOf(col);
        }
      }
    }
    out.add(col);
    prev = col;
    p2 = p1;
    p1 = _learnColumn(st, t2, t1, cid, col);
  }
  return out;
}

/// Ack-gated session: state grows only from acknowledged blocks, so a
/// lost block can never diverge the two ends. The sender encodes each
/// block against the committed state; [commit] applies it only on ack.
class HamsedaSession {
  HamsedaState _committed;
  HamsedaState? _pending;

  HamsedaSession(int nRows) : _committed = HamsedaState(nRows);

  HamsedaSession.fromState(HamsedaState state) : _committed = state;

  HamsedaState get committed => _committed;

  /// Encode a block against the committed state; call [commit] on ack
  /// or [rollback] on loss.
  Uint8List encodeBlock(List<List<int>> columns) {
    final work = _committed.clone();
    final data = encodeColumns(columns, work);
    _pending = work;
    return data;
  }

  /// Decode a delivered block and stage the state update.
  List<List<int>> decodeBlock(Uint8List data, int nFrames) {
    final work = _committed.clone();
    final cols = decodeColumns(data, nFrames, work);
    _pending = work;
    return cols;
  }

  void commit() {
    final p = _pending;
    if (p == null) throw StateError('no pending block to commit');
    _committed = p;
    _pending = null;
  }

  void rollback() {
    _pending = null;
  }
}
