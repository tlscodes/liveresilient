#!/usr/bin/env python3
"""Phase 2 — official record protocol: sequential SESSIONS of real
voice through one persistent per-contact state; per-session real bps
with bit-exact assert, then the official metric:
    bps(fresh call | N minutes of history)

Usage: corpus_curve.py <tokens.json> [<tokens2.json> ...]
Each JSON is one recording session (from dump_tokens.py). With a single
file it is split into 20s pseudo-sessions (labeled as such — the honest
multi-recording corpus needs real separate recordings).
"""
import json
import sys

from hamseda_v4 import V4State, decode, encode


def load(path):
    d = json.load(open(path))
    return [tuple(c) for c in d['cols']], d['n_rows'], d['sec']


def main():
    sessions = []
    n_rows = None
    for p in sys.argv[1:]:
        cols, nr, sec = load(p)
        n_rows = nr
        sessions.append((p, cols, sec))
    if len(sessions) == 1:
        p, cols, sec = sessions[0]
        fps = len(cols) / sec
        per = int(20 * fps)
        sessions = [
            (f'{p}#part{i}', cols[i * per:(i + 1) * per],
             len(cols[i * per:(i + 1) * per]) / fps)
            for i in range((len(cols) + per - 1) // per)
        ]
        print('NOTE: single recording split into pseudo-sessions — '
              'official record needs real separate recordings.')
    enc = V4State(n_rows)
    dec = V4State(n_rows)
    hist_sec = 0.0
    print(f'{"session":32s} {"history":>9s} {"bps":>7s}')
    for name, cols, sec in sessions:
        if not cols:
            continue
        data = encode(cols, enc)
        assert decode(data, len(cols), dec) == cols, f'mismatch in {name}'
        bps = len(data) * 8 / sec
        print(f'{name[-32:]:32s} {hist_sec:8.0f}s {bps:7.0f}  [bit-exact OK]')
        hist_sec += sec
    print(f'total history: {hist_sec:.0f}s '
          f'({len(sessions)} sessions, all bit-exact)')


if __name__ == '__main__':
    main()
