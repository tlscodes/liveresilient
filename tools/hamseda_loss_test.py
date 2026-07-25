#!/usr/bin/env python3
"""Phase 2 — packet-loss tolerance for the HamSeda token layer.

Rule: shared state (row models + column dictionary) grows ONLY from
acknowledged blocks. Each block is encoded against the last committed
state; on a lost block the sender rolls back to that state, so encoder
and decoder can never diverge — zero resync bytes.

Deterministic simulation at 0% / 5% / 20% block loss (fixed seed):
  - every delivered block must decode bit-exact
  - after the run, encoder state == decoder state (JSON-comparable)
"""
import copy
import json
import random
import sys

import hamseda_arith as ha

BLOCK = 25  # frames per block (~0.33 s)


def state_fingerprint(models, coldict):
    return json.dumps([
        [sorted((str(k), sorted(t.freq.items()))
                for k, t in m.ctx.items()) for m in models],
        [sorted(m.glob.freq.items()) for m in models],
        [list(c) for c in coldict.cols],
        sorted(coldict.table.freq.items()),
    ])


def run(cols, n_rows, sec, loss_rate, seed=42):
    rng = random.Random(seed)
    enc_models = [ha.RowModel() for _ in range(n_rows)]
    enc_dict = ha.ColumnDict()
    dec_models = [ha.RowModel() for _ in range(n_rows)]
    dec_dict = ha.ColumnDict()
    delivered_bits = 0
    delivered_frames = 0
    lost_blocks = 0
    blocks = [cols[i:i + BLOCK] for i in range(0, len(cols), BLOCK)]
    for block in blocks:
        # encode against committed state via a working copy
        wm = copy.deepcopy(enc_models)
        wd = copy.deepcopy(enc_dict)
        data, wm, wd = ha.encode_stream(block, n_rows, wm, wd)
        if rng.random() < loss_rate:
            lost_blocks += 1  # sender keeps committed state (rollback)
            continue
        # delivered + acked: decoder decodes, both sides commit
        dm = copy.deepcopy(dec_models)
        dd = copy.deepcopy(dec_dict)
        out = ha.decode_stream(data, len(block), n_rows, dm, dd)
        assert out == block, 'delivered block failed bit-exact decode'
        enc_models, enc_dict = wm, wd
        dec_models, dec_dict = dm, dd
        delivered_bits += len(data) * 8
        delivered_frames += len(block)
    assert state_fingerprint(enc_models, enc_dict) == state_fingerprint(
        dec_models, dec_dict), 'encoder/decoder state diverged'
    dsec = sec * delivered_frames / len(cols) if delivered_frames else 1
    return {
        'loss_rate': loss_rate,
        'blocks': len(blocks),
        'lost_blocks': lost_blocks,
        'delivered_bps': round(delivered_bits / dsec, 1),
        'bit_exact': True,
        'state_converged': True,
    }


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    for rate in (0.0, 0.05, 0.20):
        print(json.dumps(run(cols, d['n_rows'], d['sec'], rate)))
    print('PHASE2 OK')


if __name__ == '__main__':
    main()
