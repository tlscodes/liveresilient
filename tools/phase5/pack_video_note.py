#!/usr/bin/env python3
"""Peak 4 packager — raw AV1 stream + Codec2 audio under a 12B header.

Container formats (MP4/MKV/WebM) burn kilobytes of metadata; the video note
wire is (appendix B + E):
  header 12B: [2B magic 0x56 0x31][1B fps][2B w LE][2B h LE]
              [4B audioOffset LE][1B flags]
  video:  per frame, 3B little-endian length + the AV1 OBU frame payload
          exactly as found in the encoder's IVF (IVF file/frame headers
          stripped — they are re-derivable)
  audio:  from audioOffset to EOF: bit-packed Codec2 700C (the voice-note
          packing WITHOUT its 4B header; mode/count are implied by fps-less
          audio at 700bps for the clip duration)

Subcommands:
  pack   <in.ivf> <in.c2bits> <out.bin> <fps> <w> <h>
  unpack <in.bin> <out.ivf> <out.c2bits>   (rebuilds a valid IVF for dav1d)
  stats  <in.bin>                          (prints: total hdr video audio n_frames)
"""
import struct
import sys

MAGIC = b"V1"
HDR = 12


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


def pack(ivf, c2bits, out, fps, w, h):
    _, _, _, _, frames = parse_ivf(ivf)
    audio = open(c2bits, "rb").read()
    body = b"".join(len(f).to_bytes(3, "little") + f for f in frames)
    audio_off = HDR + len(body)
    hdr = MAGIC + bytes([int(fps)]) + struct.pack("<HH", int(w), int(h)) \
        + struct.pack("<I", audio_off) + bytes([0])
    assert len(hdr) == HDR
    open(out, "wb").write(hdr + body + audio)


def read_bin(path):
    data = open(path, "rb").read()
    if data[:2] != MAGIC:
        raise SystemExit("bad magic")
    fps = data[2]
    w, h = struct.unpack("<HH", data[3:7])
    (audio_off,) = struct.unpack("<I", data[7:11])
    frames, i = [], HDR
    while i < audio_off:
        n = int.from_bytes(data[i:i + 3], "little")
        frames.append(data[i + 3:i + 3 + n])
        i += 3 + n
    return fps, w, h, frames, data[audio_off:], data


def unpack(binpath, out_ivf, out_c2):
    fps, w, h, frames, audio, _ = read_bin(binpath)
    hdr = b"DKIF" + struct.pack("<HH", 0, 32) + b"AV01" \
        + struct.pack("<HH", w, h) + struct.pack("<II", fps, 1) \
        + struct.pack("<I", len(frames)) + b"\x00\x00\x00\x00"
    with open(out_ivf, "wb") as f:
        f.write(hdr)
        for k, fr in enumerate(frames):
            f.write(struct.pack("<IQ", len(fr), k) + fr)
    open(out_c2, "wb").write(audio)


def stats(binpath):
    _, _, _, frames, audio, data = read_bin(binpath)
    video = sum(len(f) + 3 for f in frames)
    print(len(data), HDR, video, len(audio), len(frames))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "pack":
        pack(*sys.argv[2:5], *sys.argv[5:8])
    elif cmd == "unpack":
        unpack(*sys.argv[2:5])
    elif cmd == "stats":
        stats(sys.argv[2])
    else:
        raise SystemExit("unknown subcommand")
