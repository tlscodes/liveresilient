#!/usr/bin/env python3
"""Peak 1 measurer — per-message wire size + lossless round-trip.

Wire format measured (matches compact_text_codec.dart):
  4B header [1B ver/flags][2B msgId][1B dictVer] + zstd(-19, trained dict) body
The zstd frame is measured as emitted (--single-thread --no-check would shave
4B; we keep the checksum OFF and magic ON: `zstd -19 -D dict` frame).
Small messages where compression does not help are stored raw with the
no-compress flag bit — the codec's real rule, measured here identically:
  wire = 4 + min(len(zstd_frame), len(raw))
Output TSV: id, raw_bytes, wire_bytes, roundtrip(ok|FAIL)
"""
import json
import subprocess
import sys

HEADER = 4


def zstd(args, data):
    p = subprocess.run(["zstd", *args], input=data, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, check=True)
    return p.stdout


def main():
    corpus, dict_path = sys.argv[1], sys.argv[2]
    print("id\traw_bytes\twire_bytes\troundtrip")
    for line in open(corpus, encoding="utf-8"):
        m = json.loads(line)
        raw = m["text"].encode("utf-8")
        comp = zstd(["-19", "--single-thread", "--no-check", "-D", dict_path, "-c"], raw)
        if len(comp) < len(raw):
            body, stored_comp = comp, True
        else:
            body, stored_comp = raw, False
        wire = HEADER + len(body)
        if stored_comp:
            back = zstd(["-d", "-D", dict_path, "-c"], body)
        else:
            back = body
        ok = "ok" if back == raw else "FAIL"
        print(f"{m['id']}\t{len(raw)}\t{wire}\t{ok}")


if __name__ == "__main__":
    main()
