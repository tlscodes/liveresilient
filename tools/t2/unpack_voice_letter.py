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
    python3 unpack_voice_letter.py <in.letter> <out.c2|out.opus>
Exit 0 and writes out.c2 on a Codec2 letter (modes 1..5); on a mode-12
letter (Opus 6k NB CBR, 45 B per 60 ms frame, byte-aligned) it writes an
Ogg Opus file instead, which ffmpeg's own Opus decoder opens — an
independent second decoder beside the Dart FFI one:
    ffmpeg -i out.opus out.wav
Exit 2 naming the reason on anything else (reserved or unknown mode,
truncated, not a voice letter at all — a plain non-UTF8 binary letter
from an unrelated feature should fail here, not be guessed at).
"""
import struct
import sys

# The wire's mode nibble -> (c2dec mode name, bits per frame). Since
# 2026-09-21 the phone picks the highest mode its letters carry
# (voice_note_codec.dart VoiceNoteMode); before that everything was 700C.
MODES = {1: ("700C", 28), 2: ("1200", 48), 3: ("1600", 64), 4: ("2400", 48), 5: ("3200", 64),
         6: ("opusvbr", 0), 12: ("opus6k", 360)}
OPUS_INPUT_RATE = {6: 16000, 12: 8000}   # OpusHead hint; decoders output what they are asked
OPUS_GRANULE_PER_PACKET = 2880           # 60 ms in 48 kHz units, whatever the bandwidth
# Reserved nibbles (voice_note_codec.dart): named in the refusal.
RESERVED = {13: "Lyra v2 3.2k (reserved, not built)", 14: "Lyra v2 6k (reserved, not built)",
            15: "extension escape (reserved)"}
OPUS_FRAME_BYTES = 45
OPUS_FRAME_MS = 60


def _ogg_crc(data: bytes) -> int:
    """Ogg's CRC-32: polynomial 0x04c11db7, no reflection, init 0, no xor."""
    crc = 0
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else (crc << 1)
            crc &= 0xFFFFFFFF
    return crc


def _ogg_page(serial: int, seq: int, granule: int, packets: list, flags: int) -> bytes:
    segs = bytearray()
    body = bytearray()
    for p in packets:
        n = len(p)
        while n >= 255:
            segs.append(255)
            n -= 255
        segs.append(n)
        body += p
    head = bytearray(b"OggS") + struct.pack("<BBqIII", 0, flags, granule, serial, seq, 0)
    head += bytes([len(segs)]) + segs
    page = bytes(head) + bytes(body)
    crc = _ogg_crc(page)
    return page[:22] + struct.pack("<I", crc) + page[26:]


def opus_packets(data: bytes) -> list:
    """The Opus packets a mode-6 or mode-12 letter carries, TOC included.
    Mode 12: 45 B each, byte-aligned. Mode 6: [u8 len][len bytes] each,
    len 1..255 — every bound checked before it is read."""
    mode = data[0] & 0x0F
    count = data[1] | (data[2] << 8)
    body = data[4:]
    if mode == 12:
        if len(body) < count * OPUS_FRAME_BYTES:
            raise ValueError(f"truncated: {len(body)} B holds fewer than {count} Opus frames")
        return [body[i * OPUS_FRAME_BYTES:(i + 1) * OPUS_FRAME_BYTES] for i in range(count)]
    pkts, p = [], 0
    for i in range(count):
        if p >= len(body):
            raise ValueError(f"truncated: frame {i} of {count} has no length byte")
        n = body[p]
        p += 1
        if n == 0 or p + n > len(body):
            raise ValueError(f"truncated: frame {i} of {count} wants {n} B at {p}, body is {len(body)} B")
        pkts.append(body[p:p + n])
        p += n
    return pkts


def opus_ogg(data: bytes) -> bytes:
    """An Opus letter as Ogg Opus: OpusHead (mono, the encoder's input rate
    as a hint, pre-skip 0 ON PURPOSE — the Dart decoder skips nothing, so a
    sample-aligned comparison needs none here), OpusTags, one packet per
    page, granule 2880 per packet."""
    mode = data[0] & 0x0F
    pkts = opus_packets(data)
    serial = 0x4C455454  # 'LETT'
    head = b"OpusHead" + struct.pack("<BBHIhB", 1, 1, 0, OPUS_INPUT_RATE[mode], 0, 0)
    tags = b"OpusTags" + struct.pack("<I", 6) + b"letter" + struct.pack("<I", 0)
    out = bytearray(_ogg_page(serial, 0, 0, [head], 0x02))
    out += _ogg_page(serial, 1, 0, [tags], 0)
    for i, pkt in enumerate(pkts):
        last = 0x04 if i == len(pkts) - 1 else 0
        out += _ogg_page(serial, 2 + i, (i + 1) * OPUS_GRANULE_PER_PACKET, [pkt], last)
    return bytes(out)


def mode_of(data: bytes) -> str:
    """The c2dec mode name a letter's header names."""
    return MODES[data[0] & 0x0F][0]


def unpack(data: bytes) -> bytes:
    if len(data) < 4:
        raise ValueError(f"too short for a header: {len(data)} B")
    mode = data[0] & 0x0F
    if mode in RESERVED:
        raise ValueError(f"mode {mode} is {RESERVED[mode]}")
    if mode not in MODES:
        raise ValueError(f"mode {mode} is not a known voice-letter mode — not this format")
    if mode in OPUS_INPUT_RATE:
        return opus_ogg(data)
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
    if name.startswith("opus"):
        frames = data[1] | (data[2] << 8)
        rate = OPUS_INPUT_RATE[data[0] & 0x0F]
        print(f"unpacked {len(data)} B -> {len(c2)} B Ogg Opus, {frames} frames of {name} "
              f"(~{frames * OPUS_FRAME_MS / 1000:.2f}s at {OPUS_FRAME_MS}ms/frame); "
              f"decode with: ffmpeg -i {dst} -ar {rate} out.wav")
        return 0
    frame_bytes = (bits + 7) // 8
    frame_ms = 20 if name in ("3200", "2400") else 40
    frames = len(c2) // frame_bytes
    print(f"unpacked {len(data)} B -> {len(c2)} B, {frames} frames of {name} "
          f"(~{frames * frame_ms / 1000:.2f}s at {frame_ms}ms/frame)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
