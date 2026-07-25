#!/usr/bin/env python3
"""HamSeda v4/v5 — reference library.

Lossless adaptive codec for discrete voice-token columns with a
persistent per-contact memory. Both ends run the identical deterministic
update rule, so shared state needs zero synchronization bytes.

Model (four-level escape, order-2 -> order-1 -> global -> rows):
  column id in the table of the previous TWO column ids
    -> escape: table of the previous column id
      -> escape: global column table
        -> escape: per-row order-1 PPM-C symbols, raw uniform at leaf
All levels use adaptive frequency tables (PPM-C escape mass = distinct
count, halving at 2^16) over a Subbotin carryless range coder.
Worst-case cap: if the adaptive stream loses to plain 10-bit packing,
raw ships behind a 1-byte flag (state learns identically either way).

API:
  st = V4State(n_rows)
  data = encode(cols, st)                # mutates st
  cols = decode(data, n_frames, st)      # mirrors encoder updates
  st.to_json() / V4State.from_json(...)  # cross-call persistence
  Session(n_rows): encode_block/decode_block + commit/rollback (ack-gated)
"""
import copy
import json

from hamseda_arith import (
    BitReader,
    BitWriter,
    ColumnDict,
    FreqTable,
    RowModel,
    dec_symbol,
    enc_symbol,
)

__all__ = ['V4State', 'Session', 'encode', 'decode']


class V4State:
    """Full deterministic shared state of one contact relationship."""

    def __init__(self, n_rows):
        self.n_rows = n_rows
        self.models = [RowModel() for _ in range(n_rows)]
        self.dict = ColumnDict()
        self.ctx = {}  # prev column id (-1 for start) -> FreqTable of ids
        self.ctx2 = {}  # (prev2, prev1) column ids -> FreqTable of ids

    def ctx_table(self, prev_id):
        t = self.ctx.get(prev_id)
        if t is None:
            t = FreqTable()
            self.ctx[prev_id] = t
        return t

    def ctx2_table(self, key):
        t = self.ctx2.get(key)
        if t is None:
            t = FreqTable()
            self.ctx2[key] = t
        return t

    def clone(self):
        return copy.deepcopy(self)

    # -- persistence ---------------------------------------------------
    @staticmethod
    def _ft_json(t):
        return {'f': {str(k): v for k, v in t.freq.items()}, 't': t.total}

    @staticmethod
    def _ft_load(d):
        t = FreqTable()
        t.freq = {int(k): v for k, v in d['f'].items()}
        t.total = d['t']
        return t

    def to_json(self):
        return json.dumps({
            'n_rows': self.n_rows,
            'models': [
                {
                    'ctx': {str(k): self._ft_json(v)
                            for k, v in m.ctx.items()},
                    'glob': self._ft_json(m.glob),
                }
                for m in self.models
            ],
            'cols': [list(c) for c in self.dict.cols],
            'dict_table': self._ft_json(self.dict.table),
            'ctx': {str(k): self._ft_json(v) for k, v in self.ctx.items()},
            'ctx2': {f'{a},{b}': self._ft_json(v)
                     for (a, b), v in self.ctx2.items()},
        })

    @classmethod
    def from_json(cls, text):
        d = json.loads(text)
        st = cls(d['n_rows'])
        for m, md in zip(st.models, d['models']):
            m.ctx = {int(k): cls._ft_load(v) for k, v in md['ctx'].items()}
            m.glob = cls._ft_load(md['glob'])
        for c in d['cols']:
            col = tuple(c)
            st.dict.by_col[col] = len(st.dict.cols)
            st.dict.cols.append(col)
        st.dict.table = cls._ft_load(d['dict_table'])
        st.ctx = {int(k): cls._ft_load(v) for k, v in d['ctx'].items()}
        for k, v in d.get('ctx2', {}).items():
            a, b = k.split(',')
            st.ctx2[(int(a), int(b))] = cls._ft_load(v)
        return st


def _learn(st, t2, t1, cid_before, col):
    """Identical post-frame update on both ends."""
    if cid_before is not None:
        t2.add(cid_before)
        t1.add(cid_before)
    st.dict.add(col)
    new_id = st.dict.by_col[col]
    if cid_before is None:
        t2.add(new_id)
        t1.add(new_id)
    return new_id


def _update_walk(cols, st):
    """Applies exactly the state mutations encode() would, without
    producing bits — used by the raw-fallback path on both ends."""
    prev = None
    p1 = -1
    p2 = -1
    for col in cols:
        cid = st.dict.by_col.get(col)
        t2 = st.ctx2_table((p2, p1))
        t1 = st.ctx_table(p1)
        hit = cid is not None and (
            t2.has(cid) or t1.has(cid) or st.dict.table.has(cid))
        if not hit:
            for row, sym in enumerate(col):
                st.models[row].update(prev[row] if prev else -1, sym)
        prev = col
        p2, p1 = p1, _learn(st, t2, t1, cid, col)
    return


def encode(cols, st):
    """Encode columns against (and mutating) st. Returns bytes.

    Worst-case cap: the adaptive stream is compared against packed raw
    tokens; the smaller one ships behind a 1-byte flag, so a cold call
    can never cost more than raw + 1 byte. State updates are identical
    on both paths (the model learns either way)."""
    work = st.clone()
    adaptive = _encode_adaptive(cols, work)
    raw_bits = len(cols) * st.n_rows * 10
    if len(adaptive) * 8 <= raw_bits:
        st.__dict__.update(work.__dict__)
        return b'\x01' + adaptive
    # plain 10-bit packing: exact raw cost, zero coder overhead
    acc = 0
    nbits = 0
    out = bytearray()
    for col in cols:
        for sym in col:
            acc = (acc << 10) | sym
            nbits += 10
            while nbits >= 8:
                nbits -= 8
                out.append((acc >> nbits) & 0xFF)
    if nbits:
        out.append((acc << (8 - nbits)) & 0xFF)
    _update_walk(cols, st)
    return b'\x00' + bytes(out)


def decode(data, n_frames, st):
    """Decode n_frames columns, mirroring every encoder update."""
    flag, body = data[0], data[1:]
    if flag == 1:
        return _decode_adaptive(body, n_frames, st)
    if flag != 0:
        raise ValueError('corrupt stream: unknown flag byte')
    acc = 0
    nbits = 0
    pos = 0
    cols = []
    for _ in range(n_frames):
        col = []
        for _row in range(st.n_rows):
            while nbits < 10:
                acc = (acc << 8) | body[pos]
                pos += 1
                nbits += 8
            nbits -= 10
            col.append((acc >> nbits) & 0x3FF)
        cols.append(tuple(col))
    _update_walk(cols, st)
    return cols


def _encode_adaptive(cols, st):
    w = BitWriter()
    prev = None
    p1 = -1
    p2 = -1
    for col in cols:
        if len(col) != st.n_rows:
            raise ValueError(f'column arity {len(col)} != {st.n_rows}')
        cid = st.dict.by_col.get(col)
        t2 = st.ctx2_table((p2, p1))
        t1 = st.ctx_table(p1)
        if cid is not None and t2.has(cid):
            cum, f, tot = t2.interval(cid)
            w.encode(cum, f, tot)
        else:
            cum, f, tot = t2.interval(-1)
            w.encode(cum, f, tot)
            if cid is not None and t1.has(cid):
                cum, f, tot = t1.interval(cid)
                w.encode(cum, f, tot)
            else:
                cum, f, tot = t1.interval(-1)
                w.encode(cum, f, tot)
                if cid is not None and st.dict.table.has(cid):
                    cum, f, tot = st.dict.table.interval(cid)
                    w.encode(cum, f, tot)
                else:
                    cum, f, tot = st.dict.table.interval(-1)
                    w.encode(cum, f, tot)
                    for row, sym in enumerate(col):
                        enc_symbol(w, st.models[row],
                                   prev[row] if prev else -1, sym)
        prev = col
        p2, p1 = p1, _learn(st, t2, t1, cid, col)
    return w.finish()


def _decode_adaptive(data, n_frames, st):
    r = BitReader(data)
    out = []
    prev = None
    p1 = -1
    p2 = -1
    for _ in range(n_frames):
        t2 = st.ctx2_table((p2, p1))
        t1 = st.ctx_table(p1)
        sym, cum, f, tot = t2.symbol_at(r.decode_freq(t2.total))
        r.consume(cum, f)
        col = None
        cid = None
        if sym != -1:
            col = tuple(st.dict.cols[sym])
            cid = sym
        else:
            sym1, cum, f, tot = t1.symbol_at(r.decode_freq(t1.total))
            r.consume(cum, f)
            if sym1 != -1:
                col = tuple(st.dict.cols[sym1])
                cid = sym1
            else:
                g = st.dict.table
                sym2, cum, f, tot = g.symbol_at(r.decode_freq(g.total))
                r.consume(cum, f)
                if sym2 != -1:
                    col = tuple(st.dict.cols[sym2])
                    cid = sym2
                else:
                    col = tuple(
                        dec_symbol(r, st.models[row],
                                   prev[row] if prev else -1)
                        for row in range(st.n_rows))
                    cid = st.dict.by_col.get(col)
        out.append(col)
        prev = col
        p2, p1 = p1, _learn(st, t2, t1, cid, col)
    return out


class Session:
    """Ack-gated wrapper: state grows only from acknowledged blocks."""

    def __init__(self, n_rows=None, state=None):
        self.committed = state if state is not None else V4State(n_rows)
        self._pending = None

    def encode_block(self, cols):
        work = self.committed.clone()
        data = encode(cols, work)
        self._pending = work
        return data

    def decode_block(self, data, n_frames):
        work = self.committed.clone()
        cols = decode(data, n_frames, work)
        self._pending = work
        return cols

    def commit(self):
        if self._pending is None:
            raise RuntimeError('no pending block')
        self.committed = self._pending
        self._pending = None

    def rollback(self):
        self._pending = None
