#!/usr/bin/env python3
"""Neural real-voice lane: the user's ACTUAL waveform through EnCodec at
its lowest band, decoded back — no regeneration, no cloning; the wire
carries a compressed measurement of the real voice, timbre intact.

Also measures the HamSeda lossless-layer headroom on the real token
stream: token-frame repetition rate + first-order entropy vs raw width,
i.e. how many percent our dictionary+Morse layers can shave LOSSLESSLY.

Usage: neural_lane_test.py <in.wav any rate> <out.wav> [report.json]
"""
import json
import math
import subprocess
import sys
import tempfile
from collections import Counter

import torch
import torchaudio
from encodec import EncodecModel
from encodec.utils import convert_audio


def main():
    src, dst = sys.argv[1], sys.argv[2]
    model = EncodecModel.encodec_model_24khz()
    model.set_target_bandwidth(1.5)  # lowest band: 2 codebooks x 10 bits / 13.3ms

    wav, sr = torchaudio.load(src)
    wav = convert_audio(wav, sr, model.sample_rate, model.channels)
    with torch.no_grad():
        frames = model.encode(wav.unsqueeze(0))
        decoded = model.decode(frames)[0]
    torchaudio.save(dst, decoded.clamp(-1, 1), model.sample_rate)

    codes = torch.cat([f[0] for f in frames], dim=-1)[0]  # (n_q, T)
    n_q, steps = codes.shape
    seconds = wav.shape[-1] / model.sample_rate
    raw_bits = n_q * 10 * steps
    raw_bps = raw_bits / seconds

    # HamSeda headroom on the REAL token stream (lossless layers):
    cols = [tuple(codes[:, t].tolist()) for t in range(steps)]
    repeats = sum(1 for a, b in zip(cols, cols[1:]) if a == b)
    freqs = Counter(cols)
    entropy = -sum(
        (c / steps) * math.log2(c / steps) for c in freqs.values()
    )
    entropy_bps = entropy * steps / seconds  # ideal per-frame dictionary code
    report = {
        'lane': 'neural real-voice (EnCodec 24kHz @ lowest band)',
        'seconds': round(seconds, 1),
        'wire_bps_raw_tokens': round(raw_bps, 1),
        'token_frames': steps,
        'identical_consecutive_frames_pct': round(100 * repeats / steps, 1),
        'distinct_token_frames': len(freqs),
        'per_frame_raw_bits': n_q * 10,
        'per_frame_entropy_bits': round(entropy, 2),
        'hamseda_lossless_headroom_pct': round(
            100 * (1 - entropy / (n_q * 10)), 1),
        'projected_bps_with_hamseda_layers': round(entropy_bps, 1),
        'codec2_700C_bps': 700.0,
        'note': (
            'decoded audio is the REAL waveform reconstruction (no '
            'regeneration); headroom is single-call first-order entropy — '
            'cross-call persistent dictionary adds more'
        ),
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 3:
        json.dump(report, open(sys.argv[3], 'w'), indent=1)


if __name__ == '__main__':
    main()
