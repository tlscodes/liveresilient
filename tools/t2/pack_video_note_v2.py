#!/usr/bin/env python3
"""Video-note packager v2 — superset of tools/phase5/pack_video_note.py.

Wire (unchanged except the flags byte, appendix B + E):
  header 12B: [2B magic 'V1'][1B fps][2B w LE][2B h LE][4B audioOffset LE][1B flags]
  video:  per frame, 3B little-endian length + AV1 OBU frame payload (IVF stripped)
  audio:  audioOffset..EOF, raw audio bits whose codec is the flags low nibble:
            0 = Codec2 700C (v1 letters, flags 0 — open unchanged)
            1 = Codec2 1200     2 = Codec2 1600     3 = Codec2 2400     4 = Codec2 3200
            5 = Opus 6 kbit/s, 8 kHz mono, HARD CBR, 60 ms frames -> fixed 45 B packets
                concatenated with NO framing (the phone decodes packet by packet with
                opus_decode; the Mac rebuilds an Ogg stream with `opus-ogg` for ffmpeg)
  flags high nibble: reserved 0.

Subcommands:
  pack   <in.ivf> <in.audio> <out.bin> <fps> <w> <h> [audio_mode=0]
  unpack <in.bin> <out.ivf> <out.audio>      -> rebuilds IVF for dav1d; prints the mode name
  stats  <in.bin>                             -> total hdr video audio n_frames mode_name
  mode   <in.bin>                             -> mode name only (700C|1200|1600|2400|3200|opus)
  opus-extract <in.ogg> <out.pkt> [pkt_bytes=45]   -> raw packets out of ffmpeg's .opus; exits 4
                                                      if any packet is not pkt_bytes (CBR broke)
  opus-ogg     <in.pkt> <out.ogg> [pkt_bytes=45]   -> Ogg/Opus file ffmpeg can decode
"""
import struct
import sys
import zlib  # noqa: F401  (kept for parity with tooling that imports it)

MAGIC = b"V1"
HDR = 12
MODES = {0: "700C", 1: "1200", 2: "1600", 3: "2400", 4: "3200", 5: "opus", 6: "opusvbr"}
MODE_IDS = {v: k for k, v in MODES.items()}
OPUS_PKT = 45          # 6000 bit/s * 0.060 s / 8
OPUS_FRAME_48K = 2880  # 60 ms at 48 kHz granule units


def mode_id(x):
    if isinstance(x, int):
        return x
    s = str(x)
    if s.isdigit() and int(s) in MODES:
        return int(s)
    return MODE_IDS[s]


def parse_ivf(path):
    data = open(path, "rb").read()
    if data[:4] != b"DKIF":
        raise SystemExit("not an IVF file")
    w, h = struct.unpack("<HH", data[12:16])
    tb_den, tb_num = struct.unpack("<II", data[16:24])
    frames, i = [], 32
    while i + 12 <= len(data):
        (size,) = struct.unpack("<I", data[i:i + 4])
        frames.append(data[i + 12:i + 12 + size])
        i += 12 + size
    return w, h, tb_den, tb_num, frames


def pack(ivf, audio_path, out, fps, w, h, audio_mode=0):
    m = mode_id(audio_mode)
    if m not in MODES:
        raise SystemExit(f"unknown audio mode {audio_mode}")
    _, _, _, _, frames = parse_ivf(ivf)
    audio = open(audio_path, "rb").read()
    body = b"".join(len(f).to_bytes(3, "little") + f for f in frames)
    audio_off = HDR + len(body)
    hdr = MAGIC + bytes([int(fps)]) + struct.pack("<HH", int(w), int(h)) \
        + struct.pack("<I", audio_off) + bytes([m & 0x0F])
    assert len(hdr) == HDR
    open(out, "wb").write(hdr + body + audio)


def read_bin(path):
    data = open(path, "rb").read()
    if data[:2] != MAGIC:
        raise SystemExit("bad magic")
    fps = data[2]
    w, h = struct.unpack("<HH", data[3:7])
    (audio_off,) = struct.unpack("<I", data[7:11])
    mode = data[11] & 0x0F
    frames, i = [], HDR
    while i < audio_off:
        n = int.from_bytes(data[i:i + 3], "little")
        frames.append(data[i + 3:i + 3 + n])
        i += 3 + n
    return fps, w, h, frames, data[audio_off:], data, mode


def unpack(binpath, out_ivf, out_audio):
    fps, w, h, frames, audio, _, mode = read_bin(binpath)
    hdr = b"DKIF" + struct.pack("<HH", 0, 32) + b"AV01" \
        + struct.pack("<HH", w, h) + struct.pack("<II", fps, 1) \
        + struct.pack("<I", len(frames)) + b"\x00\x00\x00\x00"
    with open(out_ivf, "wb") as f:
        f.write(hdr)
        for k, fr in enumerate(frames):
            f.write(struct.pack("<IQ", len(fr), k) + fr)
    open(out_audio, "wb").write(audio)
    print(MODES.get(mode, f"unknown{mode}"))


def stats(binpath):
    _, _, _, frames, audio, data, mode = read_bin(binpath)
    video = sum(len(f) + 3 for f in frames)
    print(len(data), HDR, video, len(audio), len(frames), MODES.get(mode, f"unknown{mode}"))


# ---------------------------------------------------------------- Ogg/Opus helpers

def _ogg_pages(data):
    """Yield the packets of a single-stream Ogg file (page-continued packets joined)."""
    i, pending = 0, b""
    while i + 27 <= len(data):
        if data[i:i + 4] != b"OggS":
            raise SystemExit(f"bad Ogg page at {i}")
        nseg = data[i + 26]
        lacing = data[i + 27:i + 27 + nseg]
        p = i + 27 + nseg
        for lace in lacing:
            pending += data[p:p + lace]
            p += lace
            if lace < 255:
                yield pending
                pending = b""
        i = p


def opus_extract_var(in_ogg, out_pkt):
    """Nibble 6: every Opus packet of an Ogg/Opus file behind ONE length
    byte ([u8 len][packet], 1..255 B) — the voice letter's mode-6 packing
    minus its header, which the phone's buildVideoLetter writes too."""
    pkts = list(_ogg_pages(open(in_ogg, "rb").read()))
    if not pkts or not pkts[0].startswith(b"OpusHead"):
        raise SystemExit("not an Ogg/Opus file")
    audio = [p for p in pkts[2:]]
    bad = [len(p) for p in audio if not 1 <= len(p) <= 255]
    if bad:
        print(f"opus-extract-var: {len(bad)}/{len(audio)} packets outside 1..255 B (e.g. {bad[:5]})",
              file=sys.stderr)
        sys.exit(4)
    open(out_pkt, "wb").write(b"".join(bytes([len(p)]) + p for p in audio))
    print(len(audio), sum(len(p) for p in audio))


def opus_ogg_var(in_pkt, out_ogg, rate=16000, preskip=312):
    """The inverse of opus_extract_var: an Ogg/Opus file ffmpeg decodes
    (OpusHead input rate as a hint; granule 2880 per 60 ms packet)."""
    raw = open(in_pkt, "rb").read()
    pkts, p = [], 0
    while p < len(raw):
        n = raw[p]
        if n == 0 or p + 1 + n > len(raw):
            print(f"opus-ogg-var: tail truncated at {p} of {len(raw)} B", file=sys.stderr)
            break
        pkts.append(raw[p + 1:p + 1 + n])
        p += 1 + n
    head = b"OpusHead" + bytes([1, 1]) + struct.pack("<HIhB", int(preskip), int(rate), 0, 0)
    vendor = b"pack_video_note_v2"
    tags = b"OpusTags" + struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", 0)
    serial, seq = 0x56326, 0
    out = [_ogg_page([head], 0, serial, seq, 0x02)]
    seq += 1
    out.append(_ogg_page([tags], 0, serial, seq, 0))
    seq += 1
    granule = int(preskip)
    for k in range(0, len(pkts), 200):
        chunk = pkts[k:k + 200]
        granule += OPUS_FRAME_48K * len(chunk)
        last = k + 200 >= len(pkts)
        out.append(_ogg_page(chunk, granule, serial, seq, 0x04 if last else 0))
        seq += 1
    open(out_ogg, "wb").write(b"".join(out))
    print(len(pkts), len(raw))


def opus_extract(in_ogg, out_pkt, pkt_bytes=OPUS_PKT):
    pkt_bytes = int(pkt_bytes)
    pkts = list(_ogg_pages(open(in_ogg, "rb").read()))
    if not pkts or not pkts[0].startswith(b"OpusHead"):
        raise SystemExit("not an Ogg/Opus file")
    audio = [p for p in pkts[2:]]  # skip OpusHead, OpusTags
    bad = [len(p) for p in audio if len(p) != pkt_bytes]
    if bad:
        print(f"opus-extract: {len(bad)}/{len(audio)} packets not {pkt_bytes} B (e.g. {bad[:5]}) — CBR broke",
              file=sys.stderr)
        sys.exit(4)
    open(out_pkt, "wb").write(b"".join(audio))
    print(len(audio), pkt_bytes)


_CRC_TABLE = []
for _n in range(256):
    _r = _n << 24
    for _ in range(8):
        _r = ((_r << 1) ^ 0x04C11DB7) if (_r & 0x80000000) else (_r << 1)
    _CRC_TABLE.append(_r & 0xFFFFFFFF)


def _ogg_crc(buf):
    crc = 0
    for b in buf:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) & 0xFF) ^ b]
    return crc


def _ogg_page(packets, granule, serial, seq, flags):
    lacing = b""
    body = b""
    for p in packets:
        n = len(p)
        while n >= 255:
            lacing += b"\xff"
            n -= 255
        lacing += bytes([n])
        body += p
    hdr = b"OggS" + b"\x00" + bytes([flags]) + struct.pack("<qIII", granule, serial, seq, 0) \
        + bytes([len(lacing)]) + lacing
    page = bytearray(hdr + body)
    crc = _ogg_crc(page)
    page[22:26] = struct.pack("<I", crc)
    return bytes(page)


def opus_ogg(in_pkt, out_ogg, pkt_bytes=OPUS_PKT, rate=8000, preskip=312):
    pkt_bytes = int(pkt_bytes)
    raw = open(in_pkt, "rb").read()
    if len(raw) % pkt_bytes:
        print(f"opus-ogg: audio {len(raw)} B is not a multiple of {pkt_bytes} — tail dropped", file=sys.stderr)
    pkts = [raw[i:i + pkt_bytes] for i in range(0, len(raw) - len(raw) % pkt_bytes, pkt_bytes)]
    head = b"OpusHead" + bytes([1, 1]) + struct.pack("<HIhB", preskip, rate, 0, 0)
    vendor = b"pack_video_note_v2"
    tags = b"OpusTags" + struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", 0)
    serial, seq = 0x56321, 0
    out = [_ogg_page([head], 0, serial, seq, 0x02)]
    seq += 1
    out.append(_ogg_page([tags], 0, serial, seq, 0))
    seq += 1
    granule = preskip
    for k in range(0, len(pkts), 200):
        chunk = pkts[k:k + 200]
        granule += OPUS_FRAME_48K * len(chunk)
        last = k + 200 >= len(pkts)
        out.append(_ogg_page(chunk, granule, serial, seq, 0x04 if last else 0))
        seq += 1
    open(out_ogg, "wb").write(b"".join(out))
    print(len(pkts), pkt_bytes)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "pack":
        pack(*sys.argv[2:5], *sys.argv[5:8], *(sys.argv[8:9] or [0]))
    elif cmd == "unpack":
        unpack(*sys.argv[2:5])
    elif cmd == "stats":
        stats(sys.argv[2])
    elif cmd == "mode":
        print(MODES.get(read_bin(sys.argv[2])[6], "unknown"))
    elif cmd == "opus-extract":
        opus_extract(*sys.argv[2:5])
    elif cmd == "opus-ogg":
        opus_ogg(*sys.argv[2:5])
    elif cmd == "opus-extract-var":
        opus_extract_var(*sys.argv[2:4])
    elif cmd == "opus-ogg-var":
        opus_ogg_var(*sys.argv[2:5])
    else:
        raise SystemExit("unknown subcommand")
