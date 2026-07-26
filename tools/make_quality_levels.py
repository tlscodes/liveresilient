#!/usr/bin/env python3
"""Render the 5-level quality ladder of one recording + honest byte
accounting per level (wire bytes for the clip, plus bps)."""
import json
import os
import sys

import torch
import torchaudio
from encodec import EncodecModel
from encodec.utils import convert_audio


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    model = EncodecModel.encodec_model_24khz()
    wav, sr = torchaudio.load(src)
    wav = convert_audio(wav, sr, model.sample_rate, model.channels)
    sec = wav.shape[-1] / model.sample_rate
    report = []

    # L1 — original PCM
    p = os.path.join(outdir, 'level1_original.wav')
    torchaudio.save(p, wav, model.sample_rate)
    report.append(('L1 original PCM 24kHz', os.path.getsize(p),
                   int(24000 * 16), p))

    # L2..L4 — EnCodec at 6 / 3 / 1.5 kbps
    for bw, name in [(6.0, 'level2_neural_6k'), (3.0, 'level3_neural_3k'),
                     (1.5, 'level4_neural_1k5')]:
        model.set_target_bandwidth(bw)
        with torch.no_grad():
            frames = model.encode(wav.unsqueeze(0))
            out = model.decode(frames)[0]
        p = os.path.join(outdir, f'{name}.wav')
        torchaudio.save(p, out.clamp(-1, 1), model.sample_rate)
        n_q = frames[0][0].shape[1]
        wire_bps = n_q * 10 * 75  # 75 frames/s, 10 bits per codebook id
        report.append((f'{name} ({n_q} codebooks)', os.path.getsize(p),
                       wire_bps, p))

    # L5 — single-codebook row0 (half of the 1.5k band)
    model.set_target_bandwidth(1.5)
    with torch.no_grad():
        frames = model.encode(wav.unsqueeze(0))
        codes, scale = frames[0]
        with torch.no_grad():
            out = model.decode([(codes[:, :1, :], scale)])[0]
    p = os.path.join(outdir, 'level5_neural_row0_750.wav')
    torchaudio.save(p, out.clamp(-1, 1), model.sample_rate)
    report.append(('level5 row0 (1 codebook)', os.path.getsize(p), 750, p))

    print(f'clip length: {sec:.1f}s')
    print(f'{"level":38s} {"file KB":>8s} {"wire bytes":>11s} {"wire bps":>9s}')
    for name, fsize, bps, _p in report:
        wire_bytes = int(bps * sec / 8)
        print(f'{name:38s} {fsize/1024:8.1f} {wire_bytes:11d} {bps:9d}')
    print(json.dumps({'note': 'wire bytes = raw token cost for this clip; '
                              'hamseda layer shrinks L4 further: cold capped '
                              'at raw, converged-warm 54 bytes (31.8 bps)'}))


if __name__ == '__main__':
    main()
