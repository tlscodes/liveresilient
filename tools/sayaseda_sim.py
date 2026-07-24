#!/usr/bin/env python3
"""SayaSeda (سایه‌صدا) — correction-stream voice architecture, measured.

The invention (original to this project): during a call, NO audio crosses
the wire. Both devices run the SAME frozen on-device predictor (the app's
offline model) over the SAME conversation context, so both compute the
SAME next-word prediction. The sender's device transcribes the speaker
locally and compares each spoken word against the twin's prediction:

  - twin guessed right  -> transmit 1 bit ("your shadow was right")
  - twin guessed wrong  -> transmit the correction (the actual word,
                           entropy-coded) + 1 flag bit

The receiver replays the corrected prediction stream through the local
voice engine with the speaker's stored voice signature, plus a coarse
prosody envelope channel (pitch/energy contour, 48 bps constant, sent so
the regenerated voice keeps the speaker's melody and emotion).

This is not a waveform codec, not a vocoder, not a ladder tweak: the
channel carries PREDICTION ERROR OF A SHARED MODEL OF THE SPEAKER.
As the twin knows the speaker better, the call costs fewer bits — the
floor is the true novelty of what is being said.

This simulator measures the correction-stream bitrate with a REAL
predictor (ollama, temperature 0 -> both ends deterministic) over a
scripted natural conversation, and reports bps vs the low-rate records.
Honesty: word-timing is modeled at natural speech rate (150 wpm);
transcription is assumed correct (ASR errors would surface as ordinary
corrections); quality is architecturally bounded by the voice engine,
not measured here.
"""
import json
import math
import sys
import urllib.request

MODEL = "qwen3:0.6b"
WPM = 150.0
PROSODY_BPS = 48.0  # coarse pitch+energy contour channel
FLAG_BITS = 1.0

CONVERSATION = (
    "hey are you home yet? "
    "no the traffic on the bridge is completely stopped. "
    "okay do you want me to start cooking dinner without you? "
    "yes please start without me I will be at least one more hour. "
    "alright I will make the rice now and keep your food warm. "
    "thank you my love how are the kids doing tonight? "
    "they finished their homework and now they are watching cartoons. "
    "good tell them I will read the story when I arrive. "
    "I will tell them drive safely and call me when you are close. "
    "I promise I will call you when I reach the main square."
)


def predict_next(context: str) -> str:
    body = json.dumps({
        "model": MODEL,
        "prompt": (
            "Continue this phone conversation with the SINGLE most likely "
            "next word only, lowercase, no punctuation, no quotes:\n"
            + context
        ),
        "stream": False,
        "think": False,
        "options": {"temperature": 0.0, "num_predict": 4, "seed": 1},
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/generate", body)
    with urllib.request.urlopen(req, timeout=300) as r:
        text = json.load(r).get("response", "")
    words = [w.strip(".,!?'\"").lower() for w in text.split() if w.strip()]
    return words[0] if words else ""


def word_bits(word: str) -> float:
    # Entropy-coded correction: ~2.2 bits/char (English letter entropy
    # with a word model) + 4 bits length prefix.
    return 4 + 2.2 * len(word)


def main() -> None:
    words = [w.strip(".,!?").lower() for w in CONVERSATION.split()]
    hits, total_bits = 0, 0.0
    context_words: list[str] = []
    for w in words:
        context = " ".join(context_words[-60:])
        guess = predict_next(context) if context_words else ""
        if guess == w:
            hits += 1
            total_bits += FLAG_BITS
        else:
            total_bits += FLAG_BITS + word_bits(w)
        context_words.append(w)

    minutes = len(words) / WPM
    seconds = minutes * 60
    correction_bps = total_bits / seconds
    total_bps = correction_bps + PROSODY_BPS

    codec2 = 700.0
    report = {
        "brand": "SayaSeda (سایه‌صدا) — shared-twin correction stream",
        "predictor": MODEL,
        "conversation_words": len(words),
        "twin_hit_rate_percent": round(100 * hits / len(words), 1),
        "correction_stream_bps": round(correction_bps, 1),
        "prosody_channel_bps": PROSODY_BPS,
        "sayaseda_total_bps": round(total_bps, 1),
        "codec2_700C_bps": codec2,
        "hamseda_measured_bps": 297.1,
        "vs_codec2_percent_fewer_bits": round(100 * (1 - total_bps / codec2), 1),
        "vs_hamseda_percent_fewer_bits": round(100 * (1 - total_bps / 297.1), 1),
        "honesty_note": (
            "real-predictor measurement over a scripted natural dialog; "
            "assumes correct local transcription and a local voice engine "
            "with stored voice signature; prosody channel is a design "
            "constant, not yet measured"
        ),
    }
    print(json.dumps(report, indent=1))
    if len(sys.argv) > 1:
        json.dump(report, open(sys.argv[1], "w"), indent=1)


if __name__ == "__main__":
    main()
