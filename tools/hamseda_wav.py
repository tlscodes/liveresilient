#!/usr/bin/env python3
"""Run the HamSeda codec on a REAL speech WAV and write the decoded audio.

Usage: hamseda_wav.py <in_8k_mono.wav> <out_decoded.wav> [report.json]
Prints measured average bps and percent under the Codec2 700C record.
"""
import json
import struct
import sys
import wave

import math
import random

from voice_record_codec import (
    FRAME,
    LPC_ORDER,
    SR,
    hamseda_decode,
    hamseda_encode,
    spectral_correlation,
    train_codebook,
)


def hamseda_decode_hq(sent, seed_book):
    """Higher-quality synthesis from the SAME bitstream: continuous filter
    state and pitch phase across frames (no per-frame clicks), mixed
    pulse+noise excitation, interpolated spectra and smoothed gain."""
    book = [list(v) for v in seed_book]
    out = []
    last = None
    buf = [0.0] * LPC_ORDER
    phase = 0.0
    gain_state = 0.0
    rng = random.Random(3)
    for item in sent:
        if item[0] == 'S' or (item[0] == 'H' and last is None):
            # Comfort decay instead of hard zero.
            for _ in range(FRAME):
                gain_state *= 0.98
                out.append(rng.uniform(-1, 1) * gain_state * 0.02)
            continue
        if item[0] == 'H':
            coeffs, pitch, gain_q = last
        elif item[0] == 'I':
            coeffs, pitch, gain_q = book[item[1]], item[2], item[3]
        else:
            coeffs = [c * 0.3 for c in item[1]]
            book.append(list(coeffs))
            pitch, gain_q = item[2], item[3]
        prev_coeffs = last[0] if last else coeffs
        last = (coeffs, pitch, gain_q)
        target_gain = gain_q / 20.0
        f0 = SR / max(pitch, int(SR / 300))
        frame = []
        for i in range(FRAME):
            a = i / FRAME
            c = [p * (1 - a) + q * a for p, q in zip(prev_coeffs, coeffs)]
            gain_state += (target_gain - gain_state) * 0.02
            phase += f0 / SR
            voiced = 1.0 if phase % 1.0 < 0.12 else 0.0
            exc = 0.75 * voiced / 0.12 * 0.35 + 0.25 * rng.uniform(-1, 1)
            y = exc * gain_state - sum(
                c[j] * buf[j] for j in range(LPC_ORDER)
            )
            y = max(-4.0, min(4.0, y))
            buf = [y] + buf[:-1]
            frame.append(y)
        out.extend(frame)
    # Gentle de-emphasis smooths vocoder harshness.
    smoothed, prev = [], 0.0
    for s in out:
        prev = 0.6 * prev + 0.4 * s
        smoothed.append(prev)
    return smoothed


def read_wav(path):
    with wave.open(path, 'rb') as f:
        assert f.getnchannels() == 1 and f.getframerate() == 8000, \
            'need 8 kHz mono'
        raw = f.readframes(f.getnframes())
    n = len(raw) // 2
    samples = struct.unpack('<%dh' % n, raw)
    peak = max(abs(s) for s in samples) or 1
    return [s / peak for s in samples]


def write_wav(path, samples):
    peak = max(abs(s) for s in samples) or 1.0
    ints = [max(-32767, min(32767, int(s / peak * 30000))) for s in samples]
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(8000)
        f.writeframes(struct.pack('<%dh' % len(ints), *ints))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    sig = read_wav(src)
    seconds = len(sig) / 8000.0
    book = train_codebook(entries=64)

    sent, bits, _nf, learned, per_frame = hamseda_encode(sig, book)
    dec = hamseda_decode_hq(sent, book)
    write_wav(dst, dec)

    bps = bits / seconds
    codec2 = 700.0
    third = len(per_frame) // 3
    report = {
        'brand': 'HamSeda on REAL speech',
        'seconds': round(seconds, 1),
        'avg_bps': round(bps, 1),
        'first_third_bps': round(sum(per_frame[:third]) / (seconds / 3), 1),
        'last_third_bps': round(sum(per_frame[-third:]) / (seconds / 3), 1),
        'codec2_700C_bps': codec2,
        'percent_fewer_bits_than_record': round(100 * (1 - bps / codec2), 1),
        'compressed_bytes_total': round(bits / 8),
        'original_bytes_16bit': len(sig) * 2,
        'learned_codebook_size': len(learned),
        'quality_proxy_spectral_corr': round(spectral_correlation(sig, dec), 3),
        'frame_mix': {
            'novel_full': sum(1 for s in sent if s[0] == 'F'),
            'learned_index': sum(1 for s in sent if s[0] == 'I'),
            'hold': sum(1 for s in sent if s[0] == 'H'),
            'silent': sum(1 for s in sent if s[0] == 'S'),
        },
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 3:
        json.dump(report, open(sys.argv[3], 'w'), indent=1)


if __name__ == '__main__':
    main()
