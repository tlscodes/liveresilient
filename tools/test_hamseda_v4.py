#!/usr/bin/env python3
"""Phase 0 test suite for the hamseda_v4 reference library, run directly
on the USER'S real voice tokens. Exit 0 only if every check passes.

Usage: test_hamseda_v4.py /tmp/gift_tokens.json
"""
import json
import random
import sys

from hamseda_v4 import Session, V4State, decode, encode

PASS = 0
FAIL = 0


def check(name, ok, detail=''):
    global PASS, FAIL
    mark = 'PASS' if ok else 'FAIL'
    print(f'[{mark}] {name}' + (f' — {detail}' if detail else ''))
    PASS += ok
    FAIL += not ok


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    n_rows, sec = d['n_rows'], d['sec']

    # 1. cold bit-exact roundtrip on the real voice
    enc_st, dec_st = V4State(n_rows), V4State(n_rows)
    data = encode(cols, enc_st)
    out = decode(data, len(cols), dec_st)
    check('cold roundtrip bit-exact (real voice)', out == cols)
    cold_bps = len(data) * 8 / sec
    raw_bps = n_rows * 10 * len(cols) / sec
    check('cold worst-case capped at raw tokens (+2 bps flag overhead)',
          cold_bps <= raw_bps + 2, f'{cold_bps:.0f} vs raw {raw_bps:.0f} bps')

    # 2. both ends identical after a call
    check('encoder/decoder state identical',
          enc_st.to_json() == dec_st.to_json())

    # 3. JSON persistence: call 2 (same speech = warm bound) smaller + exact
    enc2 = V4State.from_json(enc_st.to_json())
    dec2 = V4State.from_json(dec_st.to_json())
    data2 = encode(cols, enc2)
    check('persisted-state call 2 bit-exact',
          decode(data2, len(cols), dec2) == cols)
    warm_bps = len(data2) * 8 / sec
    check('warm smaller than cold', len(data2) < len(data),
          f'{warm_bps:.0f} vs {cold_bps:.0f} bps')

    # 4. RECORD reproduction: warm full band < 100 bps
    check('RECORD warm full-band < 100 bps', warm_bps < 100,
          f'{warm_bps:.1f} bps')

    # 5. RECORD: row0 lane fresh-content calls under 700 bps
    row0 = [(c[0],) for c in cols]
    st = V4State(1)
    dst = V4State(1)
    per = len(row0) // 4
    fresh = []
    for i in range(4):
        chunk = row0[i * per:(i + 1) * per] if i < 3 else row0[3 * per:]
        csec = sec * len(chunk) / len(row0)
        db = encode(chunk, st)
        assert decode(db, len(chunk), dst) == chunk
        fresh.append(len(db) * 8 / csec)
    check('RECORD row0 fresh call under 700 bps', min(fresh[1:]) < 700,
          'calls: ' + '/'.join(f'{b:.0f}' for b in fresh))

    # 6. ack-gated sessions: 0/5/20% loss, zero divergence
    for rate in (0.0, 0.05, 0.20):
        rng = random.Random(42)
        s, rcv = Session(n_rows), Session(n_rows)
        lost = 0
        for i in range(0, len(cols), 25):
            block = cols[i:i + 25]
            db = s.encode_block(block)
            if rng.random() < rate:
                s.rollback()
                lost += 1
                continue
            got = rcv.decode_block(db, len(block))
            assert got == block, f'block@{i} loss={rate}'
            s.commit()
            rcv.commit()
        check(f'loss {int(rate*100)}%: zero state divergence',
              s.committed.to_json() == rcv.committed.to_json(),
              f'{lost} lost blocks')

    # 7. boundaries
    try:
        encode([(1, 2, 3)], V4State(2))
        check('wrong arity raises', False)
    except ValueError:
        check('wrong arity raises', True)
    corrupt = bytearray(data)
    corrupt[10] ^= 0xFF
    try:
        got = decode(bytes(corrupt), len(cols), V4State(n_rows))
        check('corrupt input detected (mismatch)', got != cols)
    except Exception:
        check('corrupt input detected (raised)', True)

    print(f'\n{PASS} passed, {FAIL} failed')
    sys.exit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
