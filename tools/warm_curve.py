#!/usr/bin/env python3
"""Cross-call warm-up curve: split the recording into k sequential calls,
carry the per-contact state across calls, report per-call real coded bps.
Also an upper-bound probe: re-encoding the same speech fully warm."""
import json
import sys

import hamseda_arith as ha


def encode_call(cols, n_rows, models, coldict):
    data, _, _ = ha.encode_stream(cols, n_rows, models, coldict)
    return len(data) * 8


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    n_rows, sec = d['n_rows'], d['sec']
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    per = len(cols) // k
    models = [ha.RowModel() for _ in range(n_rows)]
    coldict = ha.ColumnDict()
    dmodels = [ha.RowModel() for _ in range(n_rows)]
    ddict = ha.ColumnDict()
    for i in range(k):
        chunk = cols[i * per:(i + 1) * per] if i < k - 1 else cols[(k-1)*per:]
        csec = sec * len(chunk) / len(cols)
        data, _, _ = ha.encode_stream(chunk, n_rows, models, coldict)
        assert ha.decode_stream(
            data, len(chunk), n_rows, dmodels, ddict) == chunk, (
            f'bit-exact FAILED at call {i+1}')
        print(f'call {i+1}: {len(data) * 8 / csec:.0f} bps '
              f'({len(chunk)} frames) [bit-exact OK]')
    # fully-warm bound: same speech again with the learned persistent state
    data, _, _ = ha.encode_stream(cols, n_rows, models, coldict)
    assert ha.decode_stream(
        data, len(cols), n_rows, dmodels, ddict) == cols, (
        'bit-exact FAILED on warm repeat')
    print(f'fully-warm repeat (converged dictionary, honest label): '
          f'{len(data) * 8 / sec:.0f} bps [bit-exact OK]')


if __name__ == '__main__':
    main()
