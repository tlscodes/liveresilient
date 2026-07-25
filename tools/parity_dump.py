#!/usr/bin/env python3
"""Python side of the cross-language parity probe (matches
packages/hamseda_codec/tool/parity.dart output format)."""
import json
import sys

from hamseda_v4 import V4State, decode, encode


def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return format(h, 'x')


def main():
    d = json.load(open(sys.argv[1]))
    cols = [tuple(c) for c in d['cols']]
    st = V4State(d['n_rows'])
    cold = encode(cols, st)
    assert decode(cold, len(cols), V4State(d['n_rows'])) == cols
    warm = encode(cols, st)
    sec = d['sec']
    print('bit_exact=true')
    print(f'cold_bytes={len(cold)} fnv={fnv(cold)}')
    print(f'warm_bytes={len(warm)} fnv={fnv(warm)}')
    print(f'cold_bps={len(cold)*8/sec:.1f} warm_bps={len(warm)*8/sec:.1f}')


if __name__ == '__main__':
    main()
