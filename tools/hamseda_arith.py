#!/usr/bin/env python3
"""HamSeda v3: adaptive arithmetic coding with a PPM-style order-1 model
over EnCodec token rows. TRUE bitstream (bytes out), bit-exact decode.

Model per codebook row (identical on both ends, updated after each
symbol): order-1 context table with escape to a global table with escape
to uniform raw. Frequencies increment by 1, halved at 65536 (fixed rule,
so encoder/decoder never diverge). Run-length: an identical full column
repeats as a single '1' bit in a dedicated repeat-flag context.

Usage: hamseda_arith.py <voice.wav> [decoded_out.wav]
"""
import json
import sys

from hamseda_token_codec import token_columns, decode_audio

MASK = 0xFFFFFFFF
TOP = 1 << 24
BOT = 1 << 16
RAW_SYMBOLS = 1024


class BitWriter:
    """Subbotin carryless range coder (32-bit), byte-aligned output."""

    def __init__(self):
        self.low, self.range = 0, MASK
        self.out = bytearray()

    def _normalize(self):
        while True:
            if (self.low ^ ((self.low + self.range) & MASK)) < TOP:
                pass
            elif self.range < BOT:
                self.range = (-self.low) & (BOT - 1)
            else:
                break
            self.out.append((self.low >> 24) & 0xFF)
            self.low = (self.low << 8) & MASK
            self.range = (self.range << 8) & MASK

    def encode(self, cum, freq, tot):
        r = self.range // tot
        self.low = (self.low + r * cum) & MASK
        self.range = r * freq
        self._normalize()

    def finish(self):
        for _ in range(4):
            self.out.append((self.low >> 24) & 0xFF)
            self.low = (self.low << 8) & MASK
        return bytes(self.out)


class BitReader:
    def __init__(self, data):
        self.data = data + b'\x00' * 8
        self.pos = 4
        self.low, self.range = 0, MASK
        self.code = int.from_bytes(self.data[:4], 'big')
        self._r = 1

    def _normalize(self):
        while True:
            if (self.low ^ ((self.low + self.range) & MASK)) < TOP:
                pass
            elif self.range < BOT:
                self.range = (-self.low) & (BOT - 1)
            else:
                break
            self.code = ((self.code << 8) | self.data[self.pos]) & MASK
            self.pos += 1
            self.low = (self.low << 8) & MASK
            self.range = (self.range << 8) & MASK

    def decode_freq(self, tot):
        self._r = self.range // tot
        return min(tot - 1, ((self.code - self.low) & MASK) // self._r)

    def consume(self, cum, freq):
        self.low = (self.low + self._r * cum) & MASK
        self.range = self._r * freq
        self._normalize()


class FreqTable:
    """Symbol -> freq with escape symbol (id -1). Deterministic halving."""

    def __init__(self):
        self.freq = {-1: 1}  # escape always present
        self.total = 1

    def add(self, sym):
        if sym not in self.freq:
            # PPM-C: escape mass tracks the number of distinct symbols.
            self.freq[-1] += 1
            self.total += 1
        self.freq[sym] = self.freq.get(sym, 0) + 32
        self.total += 32
        if self.total >= 1 << 16:
            new = {}
            total = 0
            for s, f in self.freq.items():
                nf = max(1, f // 2)
                new[s] = nf
                total += nf
            self.freq, self.total = new, total

    def interval(self, sym):
        cum = 0
        for s in sorted(self.freq):
            if s == sym:
                return cum, self.freq[s], self.total
            cum += self.freq[s]
        return None

    def symbol_at(self, point):
        cum = 0
        for s in sorted(self.freq):
            f = self.freq[s]
            if point < cum + f:
                return s, cum, f, self.total
            cum += f
        raise AssertionError('point outside table')

    def has(self, sym):
        return sym in self.freq


class RowModel:
    def __init__(self):
        self.ctx = {}
        self.glob = FreqTable()

    def tables_for(self, prev):
        return self.ctx.setdefault(prev, FreqTable())

    def update(self, prev, sym):
        self.tables_for(prev).add(sym)
        self.glob.add(sym)


def enc_symbol(w, model, prev, sym):
    t = model.tables_for(prev)
    if t.has(sym):
        cum, f, tot = t.interval(sym)
        w.encode(cum, f, tot)
    else:
        cum, f, tot = t.interval(-1)
        w.encode(cum, f, tot)
        g = model.glob
        if g.has(sym):
            cum, f, tot = g.interval(sym)
            w.encode(cum, f, tot)
        else:
            cum, f, tot = g.interval(-1)
            w.encode(cum, f, tot)
            w.encode(sym, 1, RAW_SYMBOLS)
    model.update(prev, sym)


def dec_symbol(r, model, prev):
    t = model.tables_for(prev)
    sym, cum, f, tot = t.symbol_at(r.decode_freq(tot=t.total))
    r.consume(cum, f)
    if sym == -1:
        g = model.glob
        sym, cum, f, tot = g.symbol_at(r.decode_freq(tot=g.total))
        r.consume(cum, f)
        if sym == -1:
            sym = r.decode_freq(tot=RAW_SYMBOLS)
            r.consume(sym, 1)
    model.update(prev, sym)
    return sym


class ColumnDict:
    """Per-contact persistent column dictionary: seen full columns get an
    id, coded via an adaptive frequency table with escape. Grows by the
    same deterministic rule on both ends — zero sync bytes."""

    def __init__(self):
        self.by_col = {}
        self.cols = []
        self.table = FreqTable()

    def add(self, col):
        cid = self.by_col.get(col)
        if cid is None:
            cid = len(self.cols)
            self.by_col[col] = cid
            self.cols.append(col)
        self.table.add(cid)
        return cid


def encode_stream(columns, n_rows, models=None, coldict=None):
    models = models or [RowModel() for _ in range(n_rows)]
    coldict = coldict or ColumnDict()
    w = BitWriter()
    prev = None
    for col in columns:
        cid = coldict.by_col.get(col)
        if cid is not None and coldict.table.has(cid):
            cum, f, tot = coldict.table.interval(cid)
            w.encode(cum, f, tot)
        else:
            cum, f, tot = coldict.table.interval(-1)
            w.encode(cum, f, tot)
            for row, sym in enumerate(col):
                enc_symbol(w, models[row], prev[row] if prev else -1, sym)
        coldict.add(col)
        prev = col
    return w.finish(), models, coldict


def decode_stream(data, n_frames, n_rows, models=None, coldict=None):
    models = models or [RowModel() for _ in range(n_rows)]
    coldict = coldict or ColumnDict()
    r = BitReader(data)
    cols = []
    prev = None
    for _ in range(n_frames):
        cid, cum, f, tot = coldict.table.symbol_at(
            r.decode_freq(tot=coldict.table.total))
        r.consume(cum, f)
        if cid == -1:
            col = tuple(
                dec_symbol(r, models[row], prev[row] if prev else -1)
                for row in range(n_rows)
            )
        else:
            col = coldict.cols[cid]
        coldict.add(col)
        cols.append(col)
        prev = col
    return cols


def main():
    src = sys.argv[1]
    out_audio = sys.argv[2] if len(sys.argv) > 2 else None
    cols, n_rows, sec, model, frames = token_columns(src)
    raw_bps = n_rows * 10 * len(cols) / sec

    half = len(cols) // 2
    cols1, cols2 = cols[:half], cols[half:]
    sec1 = sec * half / len(cols)
    sec2 = sec - sec1

    data1, models, coldict = encode_stream(cols1, n_rows)
    assert decode_stream(data1, len(cols1), n_rows) == cols1, 'call1 mismatch'

    data2_fresh, _, _ = encode_stream(cols2, n_rows)
    data2_warm, _, _ = encode_stream(cols2, n_rows, models, coldict)
    # decoder with the same warm state (rebuilt by decoding call 1 first)
    dmodels = [RowModel() for _ in range(n_rows)]
    ddict = ColumnDict()
    decode_stream(data1, len(cols1), n_rows, dmodels, ddict)
    assert decode_stream(
        data2_warm, len(cols2), n_rows, dmodels, ddict
    ) == cols2, 'warm call2 mismatch'

    if out_audio:
        decode_audio(model, frames, out_audio)

    bps1 = len(data1) * 8 / sec1
    report = {
        'lane': 'HamSeda v3 — PPM order-1 + adaptive arithmetic, true bitstream',
        'raw_token_bps': round(raw_bps, 1),
        'call1_bps': round(bps1, 1),
        'saving_vs_raw_pct': round(100 * (1 - bps1 / raw_bps), 1),
        'call2_same_speaker': {
            'bps_fresh': round(len(data2_fresh) * 8 / sec2, 1),
            'bps_warm': round(len(data2_warm) * 8 / sec2, 1),
            'cross_call_gain_pct': round(
                100 * (1 - len(data2_warm) / len(data2_fresh)), 1),
        },
        'bit_exact_verified': True,
        'vs_codec2_700_pct': round(100 * (1 - bps1 / 700.0), 1),
    }
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
