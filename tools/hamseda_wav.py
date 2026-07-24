#!/usr/bin/env python3
"""Run the HamSeda codec on a REAL speech WAV and write the decoded audio.

Usage: hamseda_wav.py <in_8k_mono.wav> <out_decoded.wav> [report.json]
Prints measured average bps and percent under the Codec2 700C record.
"""
import json
import struct
import sys
import wave

from voice_record_codec import (
    hamseda_decode,
    hamseda_encode,
    spectral_correlation,
    train_codebook,
)


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
    dec = hamseda_decode(sent, book)
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
