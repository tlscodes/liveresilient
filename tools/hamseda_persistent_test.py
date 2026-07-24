#!/usr/bin/env python3
"""Persistent-codebook effect, measured across two real-speech calls.

Call 1 (yesterday): encode utterance A from a fresh seed codebook and
persist the grown book. Call 2 (today, same speaker): encode utterance B
twice — once from the fresh seed (a codec with no memory) and once from
the persisted book (HamSeda's cross-call memory). The bps difference is
the measured value of remembering the speaker, on real speech, with the
identical quality path (same codebook matching, lossless index layer).

Usage: hamseda_persistent_test.py <call1.wav> <call2.wav> [report.json]
"""
import json
import sys

from hamseda_wav import read_wav
from voice_record_codec import hamseda_encode, train_codebook


def bps_of(sig, book):
    _sent, bits, _nf, learned, _pf = hamseda_encode(sig, book)
    return bits / (len(sig) / 8000.0), learned


def main():
    call1 = read_wav(sys.argv[1])
    call2 = read_wav(sys.argv[2])
    seed = train_codebook(entries=64)

    bps1, learned_after_call1 = bps_of(call1, seed)
    bps2_fresh, _ = bps_of(call2, seed)
    bps2_known, _ = bps_of(call2, learned_after_call1)

    codec2 = 700.0
    report = {
        'test': 'HamSeda persistent codebook across two real-speech calls',
        'call1_bps_fresh_seed': round(bps1, 1),
        'call2_bps_no_memory': round(bps2_fresh, 1),
        'call2_bps_with_memory_of_call1': round(bps2_known, 1),
        'memory_gain_percent': round(100 * (1 - bps2_known / bps2_fresh), 1),
        'call2_with_memory_vs_codec2_percent': round(
            100 * (1 - bps2_known / codec2), 1),
        'codebook_size_after_call1': len(learned_after_call1),
        'note': (
            'identical decode path for both call-2 runs — the gain is '
            'lossless (index vs full frame), zero quality difference'
        ),
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 3:
        json.dump(report, open(sys.argv[3], 'w'), indent=1)


if __name__ == '__main__':
    main()
