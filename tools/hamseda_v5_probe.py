#!/usr/bin/env python3
"""Phase 5 probe — does a deeper predictive prior pay?

v5 candidate: column id coded in the table of the previous TWO column
ids (order-2), escaping to order-1, then global, then rows. Same
adaptive machinery; go/no-go rule: >=15% mean improvement over v4 on
the session curve, else the line stops here.
"""
import json
import sys

from hamseda_arith import BitWriter, FreqTable
import hamseda_v4 as v4


class V5State(v4.V4State):
    def __init__(self, n_rows):
        super().__init__(n_rows)
        self.ctx2 = {}  # (prev2, prev1) -> FreqTable

    def ctx2_table(self, key):
        t = self.ctx2.get(key)
        if t is None:
            t = FreqTable()
            self.ctx2[key] = t
        return t


def encode_v5(cols, st):
    w = BitWriter()
    prev = None
    p1 = -1
    p2 = -1
    for col in cols:
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
                        v4.enc_symbol(w, st.models[row],
                                      prev[row] if prev else -1, sym)
        # identical deterministic updates
        if cid is not None:
            t2.add(cid)
            t1.add(cid)
        st.dict.add(col)
        new_id = st.dict.by_col[col]
        if cid is None:
            t2.add(new_id)
            t1.add(new_id)
        prev, p2, p1 = col, p1, new_id
    return w.finish()


def curve(name, enc_fn, state_cls, cols, n_rows, sec, k=4):
    st = state_cls(n_rows)
    per = len(cols) // k
    out = []
    for i in range(k):
        chunk = cols[i * per:(i + 1) * per] if i < k - 1 else cols[(k-1)*per:]
        csec = sec * len(chunk) / len(cols)
        out.append(len(enc_fn(chunk, st)) * 8 / csec)
    out.append(len(enc_fn(cols, st)) * 8 / sec)  # warm repeat
    print(f'{name}: calls ' + '/'.join(f'{b:.0f}' for b in out[:-1]) +
          f' · warm {out[-1]:.0f} bps')
    return out


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    n_rows, sec = d['n_rows'], d['sec']

    def enc4(chunk, st):
        return v4._encode_adaptive(chunk, st)

    a = curve('v4 (order-1)', enc4, v4.V4State, cols, n_rows, sec)
    b = curve('v5 (order-2)', encode_v5, V5State, cols, n_rows, sec)
    gains = [100 * (1 - y / x) for x, y in zip(a, b)]
    mean = sum(gains) / len(gains)
    print('gain per point %: ' + '/'.join(f'{g:+.1f}' for g in gains))
    print(f'mean gain: {mean:+.1f}%  -> ' +
          ('GO: port order-2' if mean >= 15 else 'NO-GO: stay on v4'))


if __name__ == '__main__':
    main()
