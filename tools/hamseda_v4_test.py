#!/usr/bin/env python3
"""HamSeda v4 probe: column-level ORDER-1 PPM — the column id is coded
in the frequency table of the PREVIOUS column id (escape -> global
column table -> row models). Fully adaptive/symmetric like v3.

Also probes the single-codebook lane (row 0 only, 750bps raw band).
Reports real coded bps (encode+decode assert) on cached tokens.
"""
import json
import sys

import hamseda_arith as ha


class V4State:
    def __init__(self, n_rows):
        self.models = [ha.RowModel() for _ in range(n_rows)]
        self.dict = ha.ColumnDict()
        self.ctx = {}  # prev col id -> FreqTable over col ids

    def ctx_table(self, prev_id):
        t = self.ctx.get(prev_id)
        if t is None:
            t = ha.FreqTable()
            self.ctx[prev_id] = t
        return t


def encode(cols, n_rows, st):
    w = ha.BitWriter()
    prev = None
    prev_id = -1
    for col in cols:
        cid = st.dict.by_col.get(col)
        t = st.ctx_table(prev_id)
        if cid is not None and t.has(cid):
            cum, f, tot = t.interval(cid)
            w.encode(cum, f, tot)
        else:
            cum, f, tot = t.interval(-1)
            w.encode(cum, f, tot)
            if cid is not None and st.dict.table.has(cid):
                cum, f, tot = st.dict.table.interval(cid)
                w.encode(cum, f, tot)
            else:
                cum, f, tot = st.dict.table.interval(-1)
                w.encode(cum, f, tot)
                for row, sym in enumerate(col):
                    ha.enc_symbol(w, st.models[row],
                                  prev[row] if prev else -1, sym)
        if cid is not None:
            t.add(cid)
        st.dict.add(col)
        new_id = st.dict.by_col[col]
        if cid is None:
            t.add(new_id)
        prev, prev_id = col, new_id
    return w.finish()


def decode(data, n_frames, n_rows, st):
    r = ha.BitReader(data)
    out = []
    prev = None
    prev_id = -1
    for _ in range(n_frames):
        t = st.ctx_table(prev_id)
        sym, cum, f, tot = t.symbol_at(r.decode_freq(t.total))
        r.consume(cum, f)
        known = sym != -1
        if known:
            col = tuple(st.dict.cols[sym])
            cid = sym
        else:
            g = st.dict.table
            sym2, cum, f, tot = g.symbol_at(r.decode_freq(g.total))
            r.consume(cum, f)
            if sym2 != -1:
                col = tuple(st.dict.cols[sym2])
                cid = sym2
            else:
                col = tuple(
                    ha.dec_symbol(r, st.models[row],
                                  prev[row] if prev else -1)
                    for row in range(n_rows))
                cid = st.dict.by_col.get(col)
        if cid is not None:
            t.add(cid)
        st.dict.add(col)
        new_id = st.dict.by_col[col]
        if cid is None:
            t.add(new_id)
        out.append(col)
        prev, prev_id = col, new_id
    return out


def curve(cols, n_rows, sec, k=4):
    enc = V4State(n_rows)
    dec = V4State(n_rows)
    per = len(cols) // k
    for i in range(k):
        chunk = cols[i * per:(i + 1) * per] if i < k - 1 else cols[(k-1)*per:]
        csec = sec * len(chunk) / len(cols)
        data = encode(chunk, n_rows, enc)
        assert decode(data, len(chunk), n_rows, dec) == chunk, f'call {i+1}'
        print(f'  call {i+1}: {len(data)*8/csec:.0f} bps [bit-exact OK]')
    data = encode(cols, n_rows, enc)
    assert decode(data, len(cols), n_rows, dec) == cols, 'warm repeat'
    print(f'  fully-warm repeat: {len(data)*8/sec:.0f} bps [bit-exact OK]')


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    n_rows, sec = d['n_rows'], d['sec']
    print(f'v4 column-order-1, full band (raw {n_rows*10*len(cols)/sec:.0f}):')
    curve(cols, n_rows, sec)
    row0 = [(c[0],) for c in cols]
    print(f'v4 single-codebook lane (raw {10*len(cols)/sec:.0f}):')
    curve(row0, 1, sec)


if __name__ == '__main__':
    main()
