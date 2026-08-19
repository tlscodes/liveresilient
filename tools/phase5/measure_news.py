#!/usr/bin/env python3
"""Peak 6 measurer — news page wire size + parse round-trip.

Wire format measured (matches compact_news_codec.dart):
  canonical CBOR (definite lengths, fixed key order) -> brotli -q 11
The CBOR codec here is a minimal hand-rolled implementation of exactly the
subset the schema needs (uint, negative uint absent, tstr, map, nested map),
so the measurement does not depend on a pip package.
Prints: raw_bytes cbor_bytes wire_bytes image_repr_bytes roundtrip(ok|FAIL)
"""
import json
import subprocess
import sys


def enc_uint(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    if n < 256:
        return bytes([major << 5 | 24, n])
    if n < 65536:
        return bytes([major << 5 | 25]) + n.to_bytes(2, "big")
    return bytes([major << 5 | 26]) + n.to_bytes(4, "big")


def enc(v):
    if isinstance(v, bool):
        raise ValueError("bool not in schema")
    if isinstance(v, int):
        if v < 0:
            return enc_uint(1, -1 - v)
        return enc_uint(0, v)
    if isinstance(v, str):
        b = v.encode("utf-8")
        return enc_uint(3, len(b)) + b
    if isinstance(v, dict):
        out = enc_uint(5, len(v))
        for k, val in v.items():
            out += enc(k) + enc(val)
        return out
    raise ValueError(f"unsupported type {type(v)}")


def dec(b, i=0):
    ib = b[i]
    major, info = ib >> 5, ib & 0x1F
    i += 1
    if info < 24:
        n = info
    elif info == 24:
        n, i = b[i], i + 1
    elif info == 25:
        n, i = int.from_bytes(b[i:i + 2], "big"), i + 2
    elif info == 26:
        n, i = int.from_bytes(b[i:i + 4], "big"), i + 4
    else:
        raise ValueError("length form not in subset")
    if major == 0:
        return n, i
    if major == 1:
        return -1 - n, i
    if major == 3:
        return b[i:i + n].decode("utf-8"), i + n
    if major == 5:
        m = {}
        for _ in range(n):
            k, i = dec(b, i)
            v, i = dec(b, i)
            m[k] = v
        return m, i
    raise ValueError(f"major {major} not in subset")


def brotli(args, data):
    p = subprocess.run(["brotli", *args], input=data, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, check=True)
    return p.stdout


def main():
    src = sys.argv[1]
    raw = open(src, "rb").read()
    page = json.loads(raw)
    cbor = enc(page)
    wire = brotli(["-q", "11", "-c"], cbor)
    img = enc(page["image"])
    back_cbor = brotli(["-d", "-c"], wire)
    decoded, _ = dec(back_cbor)
    rt = "ok" if (back_cbor == cbor and decoded == page) else "FAIL"
    print(len(raw), len(cbor), len(wire), len(img), rt)


if __name__ == "__main__":
    main()
