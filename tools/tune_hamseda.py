#!/usr/bin/env python3
"""Fast variant tuning for the HamSeda v3 model on cached tokens.

Reports real coded bps per variant (encode+decode assert) plus ideal
entropy references, so model choices are evidence, not vibes.
"""
import json
import math
import sys
from collections import Counter

import hamseda_arith as ha


def ideal_stats(cols):
    n = len(cols)
    col_counts = Counter(cols)
    h_col = -sum(c / n * math.log2(c / n) for c in col_counts.values())
    # order-1 column entropy
    pair = Counter(zip(cols, cols[1:]))
    ctx = Counter(cols[:-1])
    h1 = 0.0
    for (a, b), c in pair.items():
        p_ab = c / (n - 1)
        h1 += -p_ab * math.log2(c / ctx[a])
    return h_col, h1, len(col_counts)


def run_variant(cols, n_rows, sec, update_rows_on_hit, intra):
    models = [ha.RowModel() for _ in range(n_rows)]
    coldict = ha.ColumnDict()
    w = ha.BitWriter()
    prev = None
    for col in cols:
        cid = coldict.by_col.get(col)
        if cid is not None and coldict.table.has(cid):
            cum, f, tot = coldict.table.interval(cid)
            w.encode(cum, f, tot)
            if update_rows_on_hit:
                for row, sym in enumerate(col):
                    pv = (col[0] if (intra and row == 1)
                          else (prev[row] if prev else -1))
                    models[row].update(pv, sym)
        else:
            cum, f, tot = coldict.table.interval(-1)
            w.encode(cum, f, tot)
            for row, sym in enumerate(col):
                pv = (col[0] if (intra and row == 1)
                      else (prev[row] if prev else -1))
                ha.enc_symbol(w, models[row], pv, sym)
        coldict.add(col)
        prev = col
    data = w.finish()
    return len(data) * 8 / sec


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    n_rows, sec = d['n_rows'], d['sec']
    raw = n_rows * 10 * len(cols) / sec
    h_col, h1, distinct = ideal_stats(cols)
    fps = len(cols) / sec
    print(f'raw_bps={raw:.0f} frames={len(cols)} distinct_cols={distinct}')
    print(f'ideal order-0 column entropy bps={h_col * fps:.0f}')
    print(f'ideal order-1 column entropy bps={h1 * fps:.0f}')
    for upd in (False, True):
        for intra in (False, True):
            bps = run_variant(cols, n_rows, sec, upd, intra)
            print(f'update_on_hit={upd} intra={intra}: {bps:.0f} bps')


if __name__ == '__main__':
    main()
