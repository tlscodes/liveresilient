#!/usr/bin/env python3
"""Morse layer for HamSeda: entropy-code the codebook-index stream so the
speaker's most frequent sounds get the shortest codes — exactly Morse's
insight (E = one dot), applied to a personal sound alphabet.

Measures on real speech: fixed-width index bits vs Huffman-coded bits
(lossless, zero quality change), and the resulting total bps vs records.

Usage: morse_layer_test.py <call.wav> [report.json]
"""
import heapq
import json
import math
import sys
from collections import Counter

from hamseda_wav import read_wav
from voice_record_codec import BITS_FLAG, hamseda_encode, train_codebook


def huffman_lengths(freqs):
    heap = [(f, i, ()) for i, f in enumerate(freqs.values())]
    if len(heap) == 1:
        return {next(iter(freqs)): 1}
    heapq.heapify(heap)
    symbols = list(freqs.keys())
    lengths = {s: 0 for s in symbols}
    trees = {i: [symbols[i]] for i in range(len(symbols))}
    next_id = len(symbols)
    heap = [(f, i) for i, f in enumerate(freqs.values())]
    heapq.heapify(heap)
    while len(heap) > 1:
        f1, t1 = heapq.heappop(heap)
        f2, t2 = heapq.heappop(heap)
        for s in trees[t1] + trees[t2]:
            lengths[s] += 1
        trees[next_id] = trees[t1] + trees[t2]
        heapq.heappush(heap, (f1 + f2, next_id))
        next_id += 1
    return lengths


def main():
    sig = read_wav(sys.argv[1])
    seconds = len(sig) / 8000.0
    book = train_codebook(entries=64)
    sent, bits_fixed, _nf, learned, _pf = hamseda_encode(sig, book)

    indexes = [s[1] for s in sent if s[0] == 'I']
    freqs = Counter(indexes)
    fixed_index_bits = max(1, math.ceil(math.log2(len(learned))))
    lengths = huffman_lengths(freqs)
    huff_bits = sum(lengths[i] for i in indexes)
    fixed_bits = fixed_index_bits * len(indexes)

    bits_morse = bits_fixed - fixed_bits + huff_bits
    entropy = -sum(
        (c / len(indexes)) * math.log2(c / len(indexes))
        for c in freqs.values()
    )
    codec2 = 700.0
    report = {
        'test': 'Morse layer (Huffman over personal sound alphabet)',
        'index_frames': len(indexes),
        'distinct_sounds_used': len(freqs),
        'index_bits_fixed_each': fixed_index_bits,
        'index_bits_huffman_avg': round(huff_bits / len(indexes), 2),
        'index_stream_entropy_bits': round(entropy, 2),
        'bps_before_morse': round(bits_fixed / seconds, 1),
        'bps_with_morse': round(bits_morse / seconds, 1),
        'morse_gain_percent': round(100 * (1 - bits_morse / bits_fixed), 1),
        'vs_codec2_percent': round(100 * (1 - bits_morse / seconds / codec2), 1),
        'note': 'lossless — same frames decoded, only shorter codes',
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 2:
        json.dump(report, open(sys.argv[2], 'w'), indent=1)


if __name__ == '__main__':
    main()
