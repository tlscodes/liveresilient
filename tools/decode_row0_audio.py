#!/usr/bin/env python3
"""Render the single-codebook (row 0 only) lane to audio for honest
quality labeling of the sub-700bps fresh-content numbers."""
import sys

import torch

from hamseda_token_codec import token_columns


def main():
    src, dst = sys.argv[1], sys.argv[2]
    _cols, _n, _sec, model, frames = token_columns(src)
    codes, scale = frames[0]
    one = codes[:, :1, :]  # keep only the first codebook stream
    with torch.no_grad():
        wav = model.decode([(one, scale)])[0]
    import torchaudio
    torchaudio.save(dst, wav.clamp(-1, 1), model.sample_rate)
    print('wrote', dst)


if __name__ == '__main__':
    main()
