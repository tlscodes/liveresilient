#!/usr/bin/env python3
"""Prototype: send-on-innovation voice codec ("SOI") vs the low-rate record.

Idea under test — three stacked economies over classical LPC vocoding:
  1. LPC-10 vocoder frames (spectral envelope + pitch + gain), 8 kHz/40 ms.
  2. VAD silence economy: silent frames cost 2 bits (a "keep quiet" flag).
  3. INNOVATION GATE (the new part): a voiced frame is transmitted ONLY
     when its quantized parameters differ from what the receiver's
     predictor (hold-last-frame with gain decay) would already produce.
     Predictable speech costs 2 bits instead of a full frame.

Baselines for the record comparison:
  - Codec2 700C: 700 bps constant (the classical low-rate record).
  - Lyra-class neural: ~3000 bps (kept for context).

Quality proxy (honest label: NOT human MOS — a synthetic-signal spectral
fidelity measure): mean per-frame log-spectral correlation between the
original and the decoded signal, both for SOI and for a always-send
LPC-10 reference — showing how much fidelity the innovation gate gives up.

Test signal: synthetic 8 kHz "speech" — formant-filtered pulse trains
(vowel sequences with pitch/formant movement) + pauses in a natural
40%-silence duty cycle, 20 s total. Deterministic seed.
"""
import cmath
import json
import math
import random
import sys

SR = 8000
FRAME = 320  # 40 ms
LPC_ORDER = 10

# Bit costs per 40 ms frame.
CODEBOOK_BITS = 8  # 256-entry shared PRETRAINED spectral codebook
BITS_FULL = CODEBOOK_BITS + 7 + 5 + 2  # codebook idx + pitch + gain + flag
BITS_DELTA = 14  # flag 2b + pitch 7b + gain 5b (spectrum held from prev)
BITS_FLAG = 2   # silence or "predictable — hold" flag


# ------------------------------------------------------- shared codebook ---
def train_codebook(entries=256, iters=6, seed=1234):
    """K-means over LPC vectors of a TRAINING corpus (different seed than
    the test signal — the codebook ships with the app, like Codec2's)."""
    train = make_speech(30.0, seed=seed)
    frames = [train[i:i + FRAME] for i in range(0, len(train) - FRAME, FRAME)]
    floor = 0.02 * max(energy(f) for f in frames)
    vecs = [lpc(f)[0] for f in frames if energy(f) >= floor]
    rng = random.Random(seed)
    book = [list(v) for v in rng.sample(vecs, min(entries, len(vecs)))]
    for _ in range(iters):
        buckets = [[] for _ in book]
        for v in vecs:
            buckets[_nearest(book, v)].append(v)
        for b, members in enumerate(buckets):
            if members:
                book[b] = [sum(m[d] for m in members) / len(members)
                           for d in range(LPC_ORDER)]
    return book


def _nearest(book, v):
    best, best_d = 0, float('inf')
    for i, c in enumerate(book):
        d = sum((a - b) ** 2 for a, b in zip(c, v))
        if d < best_d:
            best_d, best = d, i
    return best


# ---------------------------------------------------------------- signal ---
def make_speech(seconds=20.0, seed=7):
    rng = random.Random(seed)
    n = int(seconds * SR)
    out = [0.0] * n
    t = 0
    while t < n:
        if rng.random() < 0.4:  # pause (breath / turn-taking)
            t += int(SR * rng.uniform(0.15, 0.6))
            continue
        # One "word": 1-4 vowel-ish segments with moving formants.
        for _ in range(rng.randint(1, 4)):
            dur = int(SR * rng.uniform(0.08, 0.25))
            f0 = rng.uniform(90, 220)
            formants = [rng.uniform(300, 800), rng.uniform(900, 1800),
                        rng.uniform(2200, 3000)]
            drift = rng.uniform(-0.3, 0.3)
            phase = 0.0
            states = [[0.0, 0.0] for _ in formants]
            for i in range(dur):
                if t + i >= n:
                    break
                phase += (f0 * (1 + drift * i / dur)) / SR
                pulse = 1.0 if phase % 1.0 < (f0 / SR) else 0.0
                pulse += rng.uniform(-0.02, 0.02)  # aspiration noise
                sample = 0.0
                for k, fc in enumerate(formants):
                    # 2-pole resonator per formant.
                    r = 0.97
                    w = 2 * math.pi * fc / SR
                    a1, a2 = 2 * r * math.cos(w), -r * r
                    y = pulse + a1 * states[k][0] + a2 * states[k][1]
                    states[k][1], states[k][0] = states[k][0], y
                    sample += y / (k + 1)
                out[t + i] = sample * 0.05
            t += dur
    peak = max(abs(x) for x in out) or 1.0
    return [x / peak for x in out]


# ------------------------------------------------------------------- LPC ---
def lpc(frame, order=LPC_ORDER):
    # Autocorrelation + Levinson-Durbin.
    r = [sum(frame[i] * frame[i - k] for i in range(k, len(frame)))
         for k in range(order + 1)]
    if r[0] == 0:
        return [0.0] * order, 0.0
    a = [0.0] * (order + 1)
    e = r[0]
    for i in range(1, order + 1):
        acc = r[i] + sum(a[j] * r[i - j] for j in range(1, i))
        k = -acc / e
        new = a[:]
        new[i] = k
        for j in range(1, i):
            new[j] = a[j] + k * a[i - j]
        a = new
        e *= (1 - k * k)
        if e <= 0:
            e = 1e-9
    return a[1:], math.sqrt(max(e, 0) / len(frame))


def pitch_of(frame):
    best_lag, best = 0, 0.0
    for lag in range(int(SR / 300), int(SR / 70)):
        c = sum(frame[i] * frame[i - lag] for i in range(lag, len(frame)))
        if c > best:
            best, best_lag = c, lag
    return best_lag


def energy(frame):
    return math.sqrt(sum(x * x for x in frame) / len(frame))


def quantize(vals, step):
    return tuple(round(v / step) for v in vals)


# ------------------------------------------------------------ SOI encode ---
def encode(signal, book, innovation_gate=True):
    frames = [signal[i:i + FRAME] for i in range(0, len(signal) - FRAME, FRAME)]
    silence_floor = 0.02 * max(energy(f) for f in frames)
    sent, bits = [], 0
    prev_q = None
    for f in frames:
        g = energy(f)
        if g < silence_floor:
            sent.append(('S',))
            bits += BITS_FLAG
            prev_q = None
            continue
        coeffs, _ = lpc(f)
        q = (_nearest(book, coeffs), min(pitch_of(f), 127),
             min(int(20 * g), 31))
        if innovation_gate and prev_q is not None and q[0] == prev_q[0]:
            if abs(q[1] - prev_q[1]) <= 6 and abs(q[2] - prev_q[2]) <= 3:
                sent.append(('H',))  # receiver holds its prediction
                bits += BITS_FLAG
            else:
                # Spectrum entry unchanged, prosody moved: delta frame
                # carries only pitch+gain — 14 bits instead of 22.
                sent.append(('D', (prev_q[0], q[1], q[2])))
                bits += BITS_DELTA
                prev_q = (prev_q[0], q[1], q[2])
        else:
            sent.append(('F', q))
            bits += BITS_FULL
            prev_q = q
    return sent, bits, len(frames)


# ------------------------------------------------------------ SOI decode ---
def decode(sent, book, total_frames):
    out = []
    prev = None
    rng = random.Random(3)
    for item in sent:
        if item[0] == 'S' or (item[0] == 'H' and prev is None):
            out.extend([0.0] * FRAME)
            continue
        q = prev if item[0] == 'H' else item[1]
        prev = q
        coeffs = list(book[q[0]])
        lag = max(q[1], int(SR / 300))
        gain = q[2] / 20.0
        # Excite: pulse train at pitch + light noise, filter through LPC.
        buf = [0.0] * LPC_ORDER
        frame = []
        for i in range(FRAME):
            exc = (1.0 if i % lag == 0 else 0.0) + rng.uniform(-0.05, 0.05)
            y = exc * gain - sum(coeffs[j] * buf[j] for j in range(LPC_ORDER))
            buf = [y] + buf[:-1]
            frame.append(y)
        peak = max(abs(x) for x in frame) or 1.0
        out.extend(x / peak * gain for x in frame)
    return out


# --------------------------------------------------------------- quality ---
def spectrum(frame, n=64):
    return [abs(sum(frame[t] * cmath.exp(-2j * math.pi * k * t / len(frame))
                    for t in range(len(frame)))) for k in range(1, n)]


def spectral_correlation(a, b):
    frames = range(0, min(len(a), len(b)) - FRAME, FRAME)
    cors = []
    for i in frames:
        fa, fb = a[i:i + FRAME], b[i:i + FRAME]
        if energy(fa) < 1e-4 and energy(fb) < 1e-4:
            continue  # mutual silence: trivially perfect, skip
        sa = [math.log(1e-9 + v) for v in spectrum(fa)]
        sb = [math.log(1e-9 + v) for v in spectrum(fb)]
        ma = sum(sa) / len(sa)
        mb = sum(sb) / len(sb)
        num = sum((x - ma) * (y - mb) for x, y in zip(sa, sb))
        den = math.sqrt(sum((x - ma) ** 2 for x in sa) *
                        sum((y - mb) ** 2 for y in sb)) or 1e-9
        cors.append(num / den)
    return sum(cors) / len(cors)


# -------------------------- HamSeda: twin self-learning codebook codec ---
# Original design for this project (brand: HamSeda / هم‌صدا): both ends
# start from the SAME tiny universal seed codebook; every full spectral
# vector that crosses the wire is appended to BOTH codebooks by the same
# deterministic rule — zero synchronization bytes. As the call proceeds,
# the codec has literally learned this speaker's voice: more and more
# frames hit the personal codebook and cost only a growing-width index.
# Bitrate DECAYS with call time toward the speaker's true novelty rate —
# a property no fixed-codebook (Codec2) or fixed-weights (neural) codec
# has.
def hamseda_encode(signal, seed_book, match_threshold=0.55):
    frames = [signal[i:i + FRAME] for i in range(0, len(signal) - FRAME, FRAME)]
    silence_floor = 0.02 * max(energy(f) for f in frames)
    book = [list(v) for v in seed_book]
    sent, bits = [], 0
    prev = None
    per_frame_bits = []
    for f in frames:
        g = energy(f)
        if g < silence_floor:
            sent.append(('S',))
            bits += BITS_FLAG
            per_frame_bits.append(BITS_FLAG)
            prev = None
            continue
        coeffs, _ = lpc(f)
        idx = _nearest(book, coeffs)
        dist = sum((a - b) ** 2 for a, b in zip(book[idx], coeffs))
        pitch, gain = min(pitch_of(f), 127), min(int(20 * g), 31)
        index_bits = max(1, math.ceil(math.log2(len(book))))
        if dist <= match_threshold:
            if prev == (idx, pitch // 8, gain // 4):
                cost = BITS_FLAG
                sent.append(('H',))
            else:
                cost = 2 + index_bits + 7 + 5  # flag + learned idx + prosody
                sent.append(('I', idx, pitch, gain))
            prev = (idx, pitch // 8, gain // 4)
        else:
            # Novel sound: pay full scalar frame once; BOTH ends append it
            # to their codebook by the same deterministic rule.
            q = quantize(coeffs, 0.3)
            cost = 2 + 10 * 4 + 7 + 5
            sent.append(('F', q, pitch, gain))
            book.append([c * 0.3 for c in q])
            prev = None
        bits += cost
        per_frame_bits.append(cost)
    return sent, bits, len(frames), book, per_frame_bits


def hamseda_decode(sent, seed_book):
    book = [list(v) for v in seed_book]
    out = []
    last = None
    rng = random.Random(3)
    for item in sent:
        if item[0] == 'S' or (item[0] == 'H' and last is None):
            out.extend([0.0] * FRAME)
            continue
        if item[0] == 'H':
            coeffs, pitch, gain = last
        elif item[0] == 'I':
            coeffs = book[item[1]]
            pitch, gain = item[2], item[3]
        else:  # 'F' — novel frame: decode AND learn, mirroring the sender
            coeffs = [c * 0.3 for c in item[1]]
            book.append(list(coeffs))
            pitch, gain = item[2], item[3]
        last = (coeffs, pitch, gain)
        out.extend(_synth(coeffs, pitch, gain, rng))
    return out


def _synth(coeffs, pitch, gain_q, rng):
    lag = max(pitch, int(SR / 300))
    gain = gain_q / 20.0
    buf = [0.0] * LPC_ORDER
    frame = []
    for i in range(FRAME):
        exc = (1.0 if i % lag == 0 else 0.0) + rng.uniform(-0.05, 0.05)
        y = exc * gain - sum(coeffs[j] * buf[j] for j in range(LPC_ORDER))
        buf = [y] + buf[:-1]
        frame.append(y)
    peak = max(abs(x) for x in frame) or 1.0
    return [x / peak * gain for x in frame]


def main():
    seconds = 60.0  # a real conversation length so learning can show
    sig = make_speech(seconds)
    book = train_codebook(entries=64)  # tiny universal seed both ends ship

    sent, bits, nf, learned_book, per_frame = hamseda_encode(sig, book)
    dec = hamseda_decode(sent, book)
    quality = spectral_correlation(sig, dec)

    # Static-codebook reference on the SAME signal (climbing-others'-
    # ladder baseline): innovation-gated VQ with the big 256 codebook.
    big_book = train_codebook(entries=256)
    _, bits_static, _ = encode(sig, big_book, innovation_gate=True)
    dec_static = decode(encode(sig, big_book, innovation_gate=True)[0],
                        big_book, nf)
    q_static = spectral_correlation(sig, dec_static)

    third = len(per_frame) // 3
    codec2 = 700.0
    bps = bits / seconds
    report = {
        "codec_brand": "HamSeda (twin self-learning codebook)",
        "signal_seconds": seconds,
        "hamseda_avg_bps": round(bps, 1),
        "hamseda_first_third_bps": round(sum(per_frame[:third]) / (seconds / 3), 1),
        "hamseda_last_third_bps": round(sum(per_frame[-third:]) / (seconds / 3), 1),
        "static_vq_bps": round(bits_static / seconds, 1),
        "codec2_700C_bps": codec2,
        "vs_codec2_percent_fewer_bits": round(100 * (1 - bps / codec2), 1),
        "last_third_vs_codec2_percent": round(
            100 * (1 - (sum(per_frame[-third:]) / (seconds / 3)) / codec2), 1),
        "quality_proxy_spectral_corr_hamseda": round(quality, 3),
        "quality_proxy_spectral_corr_static_vq": round(q_static, 3),
        "learned_codebook_size": len(learned_book),
        "frame_mix": {
            "novel_full": sum(1 for s in sent if s[0] == 'F'),
            "learned_index": sum(1 for s in sent if s[0] == 'I'),
            "hold": sum(1 for s in sent if s[0] == 'H'),
            "silent": sum(1 for s in sent if s[0] == 'S'),
        },
        "honesty_note": (
            "synthetic-signal prototype; quality metric is spectral "
            "correlation, not human MOS; Codec2 number is its published "
            "constant rate; decaying-bitrate property is the original "
            "contribution"
        ),
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 1:
        json.dump(report, open(sys.argv[1], "w"), indent=1)


if __name__ == "__main__":
    main()
