#!/usr/bin/env python3
"""HamSeda token layer — REAL implementation (not an entropy estimate).

Works on any discrete token stream (here: EnCodec lowest-band columns,
raw 20 bits per 13.3ms frame). Both ends run the identical algorithm, so
the shared per-contact dictionary needs zero synchronization bytes.

Per frame (a column = tuple of codebook ids):
  known column -> '1' + adaptive index code (online frequency-ranked:
                  frequent sounds get short codes — the Morse principle,
                  updated identically on both sides after each frame)
  novel column -> '0' + fixed raw bits; both sides append it to the
                  dictionary by the same deterministic rule

The index code is a rank-based Elias-gamma-style code over the
frequency-sorted dictionary: rank r costs 2*floor(log2(r+1))+1 bits, so
the most frequent sound costs 1 bit. Fully decodable, fully symmetric.

Verifies BIT-EXACT reconstruction (decoder output == encoder input) and
reports real bps, plus the cross-call gain with a persisted dictionary.
"""
import json
import math
import sys


RAW_BITS_PER_ID = 10  # EnCodec codebook id width


class RankCoder:
    """Deterministic shared state: dictionary + frequency ranking."""

    def __init__(self):
        self.entries = []           # column tuples, insertion order
        self.index_of = {}          # column -> entry id
        self.freq = []              # per entry id
        self._rank_cache = None

    def _ranks(self):
        if self._rank_cache is None:
            order = sorted(
                range(len(self.entries)),
                key=lambda i: (-self.freq[i], i),
            )
            self._rank_cache = {e: r for r, e in enumerate(order)}
        return self._rank_cache

    def touch(self, entry_id):
        self.freq[entry_id] += 1
        self._rank_cache = None

    def add(self, column):
        self.index_of[column] = len(self.entries)
        self.entries.append(column)
        self.freq.append(1)
        self._rank_cache = None

    @staticmethod
    def gamma_bits(rank):
        return 2 * int(math.floor(math.log2(rank + 1))) + 1

    def to_json(self):
        return {'entries': [list(e) for e in self.entries], 'freq': self.freq}

    @classmethod
    def from_json(cls, data):
        coder = cls()
        for e, f in zip(data['entries'], data['freq']):
            coder.index_of[tuple(e)] = len(coder.entries)
            coder.entries.append(tuple(e))
            coder.freq.append(f)
        return coder


def encode(columns, coder, n_ids):
    """Returns (symbol stream, total bits). Mutates coder (shared rule)."""
    raw_bits = n_ids * RAW_BITS_PER_ID
    out, bits = [], 0
    for col in columns:
        entry_id = coder.index_of.get(col)
        if entry_id is not None:
            rank = coder._ranks()[entry_id]
            out.append(('K', rank))
            bits += 1 + RankCoder.gamma_bits(rank)
            coder.touch(entry_id)
        else:
            out.append(('N', col))
            bits += 1 + raw_bits
            coder.add(col)
    return out, bits


# ---- v2: order-1 per-row adaptive model -----------------------------------
class ContextRowCoder:
    """One codebook row: each id is rank-coded within the frequency table
    of its CONTEXT (the previous id in the same row). Novel context or
    novel id in context falls back to the row's global table, then raw.
    Deterministic and symmetric — decoder mirrors every update."""

    def __init__(self):
        self.ctx = {}      # prev_id -> {id: freq}
        self.glob = {}     # id -> freq

    @staticmethod
    def _rank_of(table, symbol):
        order = sorted(table, key=lambda s: (-table[s], s))
        for r, s in enumerate(order):
            if s == symbol:
                return r, len(order)
        return None, len(order)

    @staticmethod
    def _by_rank(table, rank):
        order = sorted(table, key=lambda s: (-table[s], s))
        return order[rank] if rank < len(order) else None

    def cost_and_update(self, prev_id, sym):
        """Returns bit cost of encoding sym after prev_id, then updates."""
        bits = 1  # context-hit flag
        table = self.ctx.get(prev_id)
        rank = None
        if table:
            rank, _n = self._rank_of(table, sym)
        if rank is not None:
            bits += RankCoder.gamma_bits(rank)
        else:
            bits += 1  # global-hit flag
            grank, _n = self._rank_of(self.glob, sym)
            if grank is not None:
                bits += RankCoder.gamma_bits(grank)
            else:
                bits += RAW_BITS_PER_ID
        self.ctx.setdefault(prev_id, {})[sym] = (
            self.ctx.get(prev_id, {}).get(sym, 0) + 1
        )
        self.glob[sym] = self.glob.get(sym, 0) + 1
        return bits

    def decode_and_update(self, prev_id, payload):
        """payload mirrors cost_and_update's branches for the test rig."""
        kind, val = payload
        if kind == 'C':
            sym = self._by_rank(self.ctx[prev_id], val)
        elif kind == 'G':
            sym = self._by_rank(self.glob, val)
        else:
            sym = val
        self.ctx.setdefault(prev_id, {})[sym] = (
            self.ctx.get(prev_id, {}).get(sym, 0) + 1
        )
        self.glob[sym] = self.glob.get(sym, 0) + 1
        return sym

    def encode_symbol(self, prev_id, sym):
        table = self.ctx.get(prev_id)
        if table:
            rank, _ = self._rank_of(table, sym)
            if rank is not None:
                return ('C', rank)
        grank, _ = self._rank_of(self.glob, sym)
        if grank is not None:
            return ('G', grank)
        return ('R', sym)

    def to_json(self):
        return {
            'ctx': {str(k): v for k, v in self.ctx.items()},
            'glob': self.glob,
        }

    @classmethod
    def from_json(cls, data):
        coder = cls()
        coder.ctx = {
            int(k): {int(s): f for s, f in v.items()}
            for k, v in data['ctx'].items()
        }
        coder.glob = {int(s): f for s, f in data['glob'].items()}
        return coder


def encode_v2(columns, coders):
    """Per-row order-1 coding. Returns (symbols, bits). Mutates coders."""
    bits = 0
    symbols = []
    prev = None
    for col in columns:
        frame_syms = []
        for row, sym in enumerate(col):
            prev_id = prev[row] if prev is not None else -1
            frame_syms.append(coders[row].encode_symbol(prev_id, sym))
            bits += coders[row].cost_and_update(prev_id, sym)
        symbols.append(frame_syms)
        prev = col
    return symbols, bits


def decode_v2(symbols, coders):
    cols = []
    prev = None
    for frame_syms in symbols:
        col = []
        for row, payload in enumerate(frame_syms):
            prev_id = prev[row] if prev is not None else -1
            col.append(coders[row].decode_and_update(prev_id, payload))
        col = tuple(col)
        cols.append(col)
        prev = col
    return cols


def decode(symbols, coder):
    """Mirror of encode: rebuilds the exact column sequence."""
    cols = []
    for kind, val in symbols:
        if kind == 'K':
            ranks = coder._ranks()
            by_rank = {r: e for e, r in ranks.items()}
            entry_id = by_rank[val]
            col = coder.entries[entry_id]
            coder.touch(entry_id)
        else:
            col = val
            coder.add(col)
        cols.append(col)
    return cols


def token_columns(wav_path):
    import torch
    import torchaudio
    from encodec import EncodecModel
    from encodec.utils import convert_audio

    model = EncodecModel.encodec_model_24khz()
    model.set_target_bandwidth(1.5)
    wav, sr = torchaudio.load(wav_path)
    wav = convert_audio(wav, sr, model.sample_rate, model.channels)
    with torch.no_grad():
        frames = model.encode(wav.unsqueeze(0))
    codes = frames[0][0][0]  # (n_q, T) single segment at 1.5kbps
    seconds = wav.shape[-1] / model.sample_rate
    cols = [tuple(codes[:, t].tolist()) for t in range(codes.shape[1])]
    return cols, codes.shape[0], seconds, model, frames


def decode_audio(model, frames, out_path):
    import torch
    import torchaudio

    with torch.no_grad():
        decoded = model.decode(frames)[0]
    torchaudio.save(out_path, decoded.clamp(-1, 1), model.sample_rate)


def main():
    call1_wav = sys.argv[1]
    out_audio = sys.argv[2] if len(sys.argv) > 2 else None

    cols, n_ids, sec, model, frames = token_columns(call1_wav)
    raw_bps = n_ids * RAW_BITS_PER_ID * len(cols) / sec

    # Same-speaker cross-call test: split the recording in half.
    half = len(cols) // 2
    cols1, cols2 = cols[:half], cols[half:]
    sec1, sec2 = sec * half / len(cols), sec * (len(cols) - half) / len(cols)

    # v1 (joint-column dictionary) on call 1, for comparison.
    enc1 = RankCoder()
    sym_v1, bits_v1 = encode(cols1, enc1, n_ids)
    assert decode(sym_v1, RankCoder()) == cols1, 'v1 decoder mismatch'

    # v2 (order-1 per-row) — call 1 fresh.
    coders = [ContextRowCoder() for _ in range(n_ids)]
    sym1, bits1 = encode_v2(cols1, coders)
    dec_coders = [ContextRowCoder() for _ in range(n_ids)]
    assert decode_v2(sym1, dec_coders) == cols1, 'v2 decoder mismatch call 1'
    persisted = json.dumps([c.to_json() for c in coders])

    # Call 2: fresh vs persisted model (same speaker, later speech).
    fresh = [ContextRowCoder() for _ in range(n_ids)]
    _, bits2_fresh = encode_v2(cols2, fresh)
    warm = [ContextRowCoder.from_json(d) for d in json.loads(persisted)]
    sym2, bits2_warm = encode_v2(cols2, warm)
    warm_dec = [ContextRowCoder.from_json(d) for d in json.loads(persisted)]
    assert decode_v2(sym2, warm_dec) == cols2, 'v2 decoder mismatch call 2'

    if out_audio:
        decode_audio(model, frames, out_audio)

    report = {
        'lane': 'HamSeda token layer over EnCodec 1.5k band — REAL, bit-exact',
        'raw_token_bps': round(raw_bps, 1),
        'v1_joint_dict_bps': round(bits_v1 / sec1, 1),
        'v2_order1_bps_call1': round(bits1 / sec1, 1),
        'v2_saving_vs_raw_pct': round(100 * (1 - (bits1 / sec1) / raw_bps), 1),
        'call2_same_speaker': {
            'bps_fresh_model': round(bits2_fresh / sec2, 1),
            'bps_persisted_model': round(bits2_warm / sec2, 1),
            'cross_call_gain_pct': round(
                100 * (1 - bits2_warm / bits2_fresh), 1),
        },
        'bit_exact_verified': True,
        'codec2_700C_bps': 700.0,
        'note': 'audio quality is EnCodec neural reconstruction of the real '
                'waveform; this layer is lossless on the token stream',
    }
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
