#!/usr/bin/env python3
"""Inverts voice_note_codec.dart's packVoiceNote(): turns a tight-packed
DNS-valve voice letter back into the per-frame padded layout `c2dec`
expects, so a letter the responder wrote to disk can actually be decoded
and played back on this Mac.

Wire format (voice_note_codec.dart, unchanged here, read not guessed):
  [0]    ver (high nibble) | mode (low nibble)   mode: 1=700C, 2=1200
  [1..2] frameCount, little-endian u16
  [3]    flags (reserved, 0)
  [4..]  frames bit-packed CONTIGUOUSLY, MSB-first, NOT byte aligned:
         700C frames are 28 bits each -> N frames occupy ceil(N*28/8) bytes.

`c2dec` (the CLI codec2 tool already used by valve_media_probe.sh) reads
one frame as ceil(bits_per_frame/8) bytes, MSB-first, zero-padded in the
low bits — exactly what `Codec2.encodeFrame` in codec2_ffi.dart produces
per frame before packVoiceNote tightens it. This script re-pads each
frame back to that shape.

Usage:
    python3 unpack_voice_letter.py <in.letter> <out.c2>
Exit 0 and writes out.c2 on a mode-1 (700C) letter; exit 2 naming the
reason on anything else (wrong mode, truncated, not a voice letter at
all — a plain non-UTF8 binary letter from an unrelated feature should
fail here, not be guessed at).
"""
import sys

# The wire's mode nibble -> (c2dec mode name, bits per frame). Since
# 2026-09-21 the phone picks the highest mode its letters carry
# (voice_note_codec.dart VoiceNoteMode); before that everything was 700C.
MODES = {1: ("700C", 28), 2: ("1200", 48), 3: ("1600", 64), 4: ("2400", 48), 5: ("3200", 64)}


def mode_of(data: bytes) -> str:
    """The c2dec mode name a letter's header names."""
    return MODES[data[0] & 0x0F][0]


def unpack(data: bytes) -> bytes:
    if len(data) < 4:
        raise ValueError(f"too short for a header: {len(data)} B")
    mode = data[0] & 0x0F
    if mode not in MODES:
        raise ValueError(f"mode {mode} is not a known voice-letter mode — not this format")
    BITS_PER_FRAME_700C = MODES[mode][1]
    FRAME_BYTES_700C = (BITS_PER_FRAME_700C + 7) // 8
    frame_count = data[1] | (data[2] << 8)
    packed = data[4:]
    need_bits = frame_count * BITS_PER_FRAME_700C
    if len(packed) * 8 < need_bits:
        raise ValueError(
            f"truncated: {len(packed)} B holds fewer than {frame_count} "
            f"frames ({need_bits} bits needed)"
        )
    out = bytearray()
    bitpos = 0
    for _ in range(frame_count):
        frame = bytearray(FRAME_BYTES_700C)
        for b in range(BITS_PER_FRAME_700C):
            byte_i, bit_i = bitpos >> 3, 7 - (bitpos & 7)
            if (packed[byte_i] >> bit_i) & 1:
                frame[b >> 3] |= 1 << (7 - (b & 7))
            bitpos += 1
        out += frame
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: unpack_voice_letter.py <in.letter> <out.c2>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()
    try:
        c2 = unpack(data)
    except ValueError as error:
        print(f"not a decodable voice letter: {error}", file=sys.stderr)
        return 2
    with open(dst, "wb") as f:
        f.write(c2)
    name, bits = MODES[data[0] & 0x0F]
    frame_bytes = (bits + 7) // 8
    frame_ms = 20 if name in ("3200", "2400") else 40
    frames = len(c2) // frame_bytes
    print(f"unpacked {len(data)} B -> {len(c2)} B, {frames} frames of {name} "
          f"(~{frames * frame_ms / 1000:.2f}s at {frame_ms}ms/frame)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
