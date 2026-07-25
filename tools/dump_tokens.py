#!/usr/bin/env python3
"""Dump EnCodec token columns of a wav to JSON once, for fast codec tuning."""
import json
import sys

from hamseda_token_codec import token_columns

cols, n_rows, sec, _m, _f = token_columns(sys.argv[1])
json.dump({'cols': [list(c) for c in cols], 'n_rows': n_rows, 'sec': sec},
          open(sys.argv[2], 'w'))
print(len(cols), 'frames', n_rows, 'rows', round(sec, 2), 's')
