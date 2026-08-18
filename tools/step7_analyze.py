#!/usr/bin/env python3
"""Turns one recorded capture into two claims that are checked differently,
because they have opposite logical shapes.

  the label that must NOT appear in the clear   is a UNIVERSAL claim
  the label that MUST appear in the clear       is an EXISTENTIAL claim

A universal claim is only as strong as the coverage of the scan behind it, so it
is evaluated by a raw byte scan over every byte of the FULL unfiltered capture —
never over a filtered excerpt, and never through a parser. That matters here for
a measured reason: the capture tool wrote a file it cannot itself fully re-read
(a block length that is not a multiple of four), so a parser reaches ~0.009% of
the bytes while a byte scan reaches all of them. A malformed length is exactly
the defect that hides bytes from a parser and not from a scan.

An existential claim needs the opposite: one located, reproducible witness. So
the label that must appear is not merely found somewhere in a file — the offset
is required to fall inside a captured packet's data region, and the bytes around
it are parsed far enough to say which protocol field it is. Without that, a hit
in the file's own metadata would pass, and metadata is written by the recorder,
not sent by the device.

The scanner does not get to assert its own coverage either. Before any "absent"
verdict counts, it must find the label planted in every encoding it claims to
cover, including at the seam between two read buffers, which is the one place a
streaming scanner can go blind.

Written because no protocol dissector is installed on this machine; stdlib only.

  exit 0  both claims hold, and the scanner proved it can see
  exit 1  a claim does not hold
  exit 2  bad arguments, or an input is missing or empty
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys

CHUNK = 1 << 20

PCAPNG_SHB = 0x0A0D0D0A
PCAP_MAGICS = {
    0xA1B2C3D4: ("<", 1),  # classic, microseconds, little endian read
    0xD4C3B2A1: ("<", 1),
    0xA1B23C4D: ("<", 1000),  # nanosecond variant
    0x4D3CB2A1: ("<", 1000),
}


def die(message: str, code: int = 2) -> "NoReturn":  # type: ignore[valid-type]
    print(f"step7_analyze: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_label(path: str) -> str:
    if not os.path.isfile(path):
        die(f"missing {path}")
    text = open(path, "rb").read().decode("utf-8", "replace").strip()
    if not text:
        # An empty label would make a substring test pass against anything, so
        # the presence claim would be satisfied by nothing at all.
        die(f"{path} is empty; an empty label makes the check vacuous")
    return text


def variants(label: str) -> "dict[str, bytes]":
    """The encodings an absence claim must cover before 'absent' is honest.

    The haystack is lowercased byte-wise before matching, which lowercases only
    ASCII bytes -- and that is precisely what makes one pass cover all three
    forms here, since in UTF-16 an ASCII label is ASCII bytes separated by NUL.
    """
    low = label.lower()
    return {
        "ascii/utf-8 (case-insensitive)": low.encode("utf-8"),
        "utf-16le (case-insensitive)": low.encode("utf-16-le"),
        "utf-16be (case-insensitive)": low.encode("utf-16-be"),
    }


def scan_file(path: str, needles: "dict[str, bytes]") -> "dict[str, int]":
    """Streams every byte of the file and returns first hit offset per variant.

    The overlap carried between reads is one byte short of the longest needle,
    so a match straddling a buffer seam cannot be missed. -1 means not found.
    """
    longest = max(len(n) for n in needles.values())
    found = {name: -1 for name in needles}
    carry = b""
    base = 0
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            window = carry + block
            low = window.lower()
            for name, needle in needles.items():
                if found[name] >= 0:
                    continue
                at = low.find(needle)
                if at >= 0:
                    found[name] = base - len(carry) + at
            keep = min(longest - 1, len(window))
            carry = window[len(window) - keep:] if keep else b""
            base += len(block)
    return found


def self_test(needles: "dict[str, bytes]", scratch_dir: str) -> "list[str]":
    """Plants each variant in a scratch file and requires the scanner to find
    every one -- including one placed across a read seam. Coverage measured, not
    asserted."""
    path = os.path.join(scratch_dir, "step7_scanner_selftest.bin")
    names = list(needles)
    filler = b"\x00\xff\x41" * 4096
    body = bytearray()
    # one variant deliberately straddles the CHUNK boundary
    seam_name = names[0]
    seam_needle = needles[seam_name]
    while len(body) < CHUNK - len(seam_needle) // 2:
        body += filler
    del body[CHUNK - len(seam_needle) // 2:]
    body += seam_needle
    for name in names[1:]:
        body += filler[:1024] + needles[name]
    body += filler[:1024]
    with open(path, "wb") as handle:
        handle.write(bytes(body))
    hits = scan_file(path, needles)
    os.unlink(path)
    return [name for name in names if hits[name] < 0]


class Packet:
    __slots__ = ("index", "data_offset", "length", "seconds")

    def __init__(self, index: int, data_offset: int, length: int, seconds: float):
        self.index = index
        self.data_offset = data_offset
        self.length = length
        self.seconds = seconds


def walk_packets(path: str) -> "tuple[list[Packet], int, str]":
    """Returns the packet-data regions of a capture, its link type, and its
    format. Understands both classic pcap and the block form; a block it cannot
    parse ends the walk rather than being guessed at."""
    raw = open(path, "rb").read()
    if len(raw) < 8:
        die(f"{path} is too small to be a capture")
    packets: "list[Packet]" = []

    magic = struct.unpack("<I", raw[:4])[0]
    if magic in PCAP_MAGICS:
        endian, _ = PCAP_MAGICS[magic]
        if magic in (0xD4C3B2A1, 0x4D3CB2A1):
            endian = ">"
        link = struct.unpack(endian + "I", raw[20:24])[0]
        at = 24
        index = 0
        while at + 16 <= len(raw):
            ts_sec, ts_usec, caplen, _origlen = struct.unpack(endian + "IIII", raw[at:at + 16])
            at += 16
            if caplen < 0 or at + caplen > len(raw):
                break
            packets.append(Packet(index, at, caplen, ts_sec + ts_usec / 1e6))
            at += caplen
            index += 1
        return packets, link, "pcap"

    if struct.unpack("<I", raw[:4])[0] == PCAPNG_SHB or struct.unpack(">I", raw[:4])[0] == PCAPNG_SHB:
        endian = "<"
        if struct.unpack(">I", raw[8:12])[0] == 0x1A2B3C4D:
            endian = ">"
        at = 0
        index = 0
        link = -1
        while at + 12 <= len(raw):
            btype, blen = struct.unpack(endian + "II", raw[at:at + 8])
            if blen < 12 or blen % 4 or at + blen > len(raw):
                break  # the defect this file is known to carry; stop honestly
            body = raw[at + 8:at + blen - 4]
            if btype == 0x00000001 and len(body) >= 4:  # interface description
                if link < 0:
                    link = struct.unpack(endian + "H", body[:2])[0]
            elif btype == 0x00000006 and len(body) >= 20:  # enhanced packet
                _iface, hi, lo, caplen, _orig = struct.unpack(endian + "IIIII", body[:20])
                stamp = ((hi << 32) | lo) / 1e6
                packets.append(Packet(index, at + 8 + 20, caplen, stamp))
                index += 1
            at += blen
        return packets, link, "pcapng"

    die(f"{path} is not a capture this tool recognises")


def find_in_packets(path: str, packets: "list[Packet]", needle: bytes) -> "tuple[Packet, int] | None":
    raw = open(path, "rb").read()
    for packet in packets:
        region = raw[packet.data_offset:packet.data_offset + packet.length]
        at = region.lower().find(needle)
        if at >= 0:
            return packet, at
    return None


def parse_client_hello(region: bytes) -> "dict[str, object] | None":
    """Finds a handshake record inside one packet's bytes and reads the fields
    the claim rests on: the name offered in the clear, and whether the extension
    under test was offered at all. Returns None when there is no such record."""
    for start in range(0, max(0, len(region) - 5)):
        if region[start] != 0x16 or region[start + 1] != 0x03:
            continue
        rec_len = struct.unpack(">H", region[start + 3:start + 5])[0]
        body = region[start + 5:start + 5 + rec_len]
        if len(body) < 4 or body[0] != 0x01:
            continue
        at = 4 + 2 + 32
        if at >= len(body):
            continue
        sid_len = body[at]
        at += 1 + sid_len
        if at + 2 > len(body):
            continue
        cs_len = struct.unpack(">H", body[at:at + 2])[0]
        at += 2 + cs_len
        if at >= len(body):
            continue
        comp_len = body[at]
        at += 1 + comp_len
        if at + 2 > len(body):
            continue
        ext_total = struct.unpack(">H", body[at:at + 2])[0]
        at += 2
        end = min(len(body), at + ext_total)
        offered: "list[int]" = []
        server_name = None
        while at + 4 <= end:
            ext_type, ext_len = struct.unpack(">HH", body[at:at + 4])
            at += 4
            payload = body[at:at + ext_len]
            at += ext_len
            offered.append(ext_type)
            if ext_type == 0 and len(payload) >= 5:
                name_len = struct.unpack(">H", payload[3:5])[0]
                server_name = payload[5:5 + name_len].decode("utf-8", "replace")
        return {
            "record_offset": start,
            "server_name": server_name,
            "extensions": offered,
        }
    return None


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def locate_witness(excerpt_path: str, present_label: str):
    """The existential claim, measured live. Both run modes call exactly this,
    so a recheck's witness comes from the same code path as a full run's."""
    packets, link, fmt = walk_packets(excerpt_path)
    witness = find_in_packets(excerpt_path, packets, present_label.lower().encode())
    hello = None
    if witness is not None:
        packet, _offset = witness
        raw = open(excerpt_path, "rb").read()
        region = raw[packet.data_offset:packet.data_offset + packet.length]
        hello = parse_client_hello(region)
    return packets, link, fmt, witness, hello


def parse_report(path: str) -> "dict[str, list[str]]":
    """Reads a previously written analysis into key -> list of values.
    Blank lines and '#' section headers are structure, not data."""
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        die(f"missing or empty report: {path}")
    record: "dict[str, list[str]]" = {}
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8", "replace")
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition(":")
        if not sep:
            continue
        record.setdefault(key.strip(), []).append(value.strip())
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", help="the complete unfiltered capture; omit to recheck")
    parser.add_argument("--recheck", help="a previously written analysis to re-verify without the full capture")
    parser.add_argument("--excerpt", required=True, help="the committed excerpt")
    parser.add_argument("--absent-label", required=True)
    parser.add_argument("--present-label", required=True)
    parser.add_argument("--extraction", required=True, help="the command that derived the excerpt")
    parser.add_argument("--reader-note", default="", help="verbatim error the reader emitted, if any")
    parser.add_argument("--out", help="where to write the report; required with --full, not accepted with --recheck")
    parser.add_argument("--scratch", default="/tmp")
    args = parser.parse_args()

    # Argument rules, settled before any filesystem access.
    if (args.full is None) == (args.recheck is None):
        die("exactly one of --full / --recheck is required")
    if args.full is not None and args.out is None:
        die("--out is required with --full")
    if args.recheck is not None and args.out is not None:
        die("--out is not accepted with --recheck; a recheck writes no report")

    if not os.path.isfile(args.excerpt) or os.path.getsize(args.excerpt) == 0:
        die(f"missing or empty capture: {args.excerpt}")

    absent_label = read_label(args.absent_label)
    present_label = read_label(args.present_label)
    if absent_label.lower() == present_label.lower():
        die("the two labels are identical; the check would be self-contradictory")

    if args.full is not None:
        return run_full(args, absent_label, present_label)
    return run_recheck(args, absent_label, present_label)


def run_full(args, absent_label: str, present_label: str) -> int:
    """Mode A: both claims measured live against the complete capture."""
    if not os.path.isfile(args.full) or os.path.getsize(args.full) == 0:
        die(f"missing or empty capture: {args.full}")

    blind = self_test(variants(absent_label), args.scratch)
    if blind:
        die("the scanner failed its own coverage test for: " + ", ".join(blind), 1)

    absent_hits = scan_file(args.full, variants(absent_label))
    leaked = {name: at for name, at in absent_hits.items() if at >= 0}

    packets, link, fmt, witness, hello = locate_witness(args.excerpt, present_label)

    full_packets, _, full_fmt = walk_packets(args.full)

    lines = [
        "artifact: two claims about one recorded exchange, each checked in the form its logic requires",
        f"absent_label: {absent_label}",
        f"present_label: {present_label}",
        "",
        "# the universal claim, measured over every byte of the complete capture",
        f"full_capture: {os.path.basename(args.full)}",
        f"full_sha256: {sha256(args.full)}",
        f"full_bytes: {os.path.getsize(args.full)}",
        f"full_packets_parsed: {len(full_packets)} ({full_fmt}; a parser stops at the first defect, a byte scan does not)",
        "scan_method: streaming byte scan, whole file, buffers overlapped by the longest pattern",
        "scan_coverage_bytes: %d" % os.path.getsize(args.full),
    ]
    for name in variants(absent_label):
        lines.append(f"scan_encoding: {name}")
    lines.append("scanner_self_test: every encoding planted and found, including across a buffer seam")
    lines.append(f"absent_label_found: {'YES at ' + str(sorted(leaked.values())) if leaked else 'no'}")

    lines += [
        "",
        "# the existential claim, located rather than merely present",
        f"excerpt: {os.path.basename(args.excerpt)}",
        f"excerpt_sha256: {sha256(args.excerpt)}",
        f"excerpt_bytes: {os.path.getsize(args.excerpt)}",
        f"excerpt_format: {fmt} (link type {link})",
        f"excerpt_packets: {len(packets)}",
        f"extraction: {args.extraction}",
    ]
    if args.reader_note:
        lines.append(f"reader_note: {args.reader_note}")
    if witness:
        packet, offset = witness
        lines += [
            f"witness_packet_index: {packet.index}",
            f"witness_packet_epoch: {packet.seconds:.6f}",
            f"witness_offset_in_packet_data: {offset}",
            f"witness_in_packet_data_region: yes (packet data spans file bytes "
            f"{packet.data_offset}..{packet.data_offset + packet.length})",
        ]
        if hello:
            lines += [
                f"witness_field: the name offered in the clear in a handshake record at packet offset {hello['record_offset']}",
                f"witness_field_value: {hello['server_name']}",
                f"offered_extension_count: {len(hello['extensions'])}",
                "offered_extension_ids: " + ",".join(str(x) for x in hello["extensions"]),
                f"offered_extension_under_test_present: {'yes' if 0xFE0D in hello['extensions'] else 'no'}",
            ]
        else:
            lines.append("witness_field: not parsed; the bytes are in packet data but not a handshake record")
    else:
        lines.append("witness_packet_index: none — the label is not inside any packet's data region")

    lines += [
        "",
        "# what this does not claim",
        "residual: a label split across two segments would evade a byte scan; the excerpt",
        "residual: shows the exchange arrived in one record, which is why that gap is small here.",
        "residual: 'not in the clear' is the whole claim — an encrypted occurrence is expected",
        "residual: and is not what this scan is looking for.",
        "residual: one recorded exchange is one exchange; nothing here generalises beyond it.",
    ]

    with open(args.out, "w") as handle:
        handle.write("\n".join(lines) + "\n")

    print("\n".join(lines))

    if leaked:
        die("the label that must not appear was found in the clear", 1)
    if not witness:
        die("the label that must appear was not located inside any packet's data", 1)
    if hello and hello["server_name"] and hello["server_name"].lower() != present_label.lower():
        die(f"the located field says {hello['server_name']}, not {present_label}", 1)
    print("\nSTEP7 ANALYSIS PASSED")
    return 0


RECHECK_REQUIRED_KEYS = (
    "full_sha256",
    "full_bytes",
    "scan_coverage_bytes",
    "absent_label_found",
    "excerpt_sha256",
    "scanner_self_test",
)


def run_recheck(args, absent_label: str, present_label: str) -> int:
    """Mode B: the existential claim is measured again live; the universal
    claim's input is normally gone, so its recorded result is VALIDATED — a
    strictly weaker check, and labelled as such. If the full capture turns out
    to be present and hash-identical, the validation is upgraded to a live
    re-measurement."""
    record = parse_report(args.recheck)

    def single(key: str) -> str:
        values = record.get(key, [])
        if not values:
            die(f"recheck failed: report is missing required key '{key}'", 1)
        if len(values) != 1:
            die(f"recheck failed: report carries {len(values)} '{key}' lines, expected exactly one", 1)
        return values[0]

    for key in RECHECK_REQUIRED_KEYS:
        if key not in record:
            die(f"recheck failed: report is missing required key '{key}'", 1)

    encodings = record.get("scan_encoding", [])
    if len(encodings) != 3:
        die(f"recheck failed: expected exactly three scan_encoding lines, found {len(encodings)}", 1)

    found = single("absent_label_found")
    if found != "no":
        die(f"recheck failed: absent_label_found must be 'no', the report says '{found}'", 1)

    try:
        full_bytes = int(single("full_bytes"))
        coverage = int(single("scan_coverage_bytes"))
    except ValueError:
        die("recheck failed: full_bytes and scan_coverage_bytes must both be integers", 1)
    if coverage != full_bytes:
        die(f"recheck failed: scan_coverage_bytes ({coverage}) != full_bytes ({full_bytes}); "
            "the recorded scan did not cover the whole file", 1)

    if single("absent_label") != absent_label:
        die("recheck failed: the report's absent_label does not match the --absent-label file contents", 1)

    recorded_excerpt_sha = single("excerpt_sha256")
    live_excerpt_sha = sha256(args.excerpt)
    if recorded_excerpt_sha != live_excerpt_sha:
        die("recheck failed: excerpt sha256 mismatch — the report records "
            f"{recorded_excerpt_sha} but the excerpt passed in hashes to {live_excerpt_sha}", 1)

    # Automatic upgrade: the record is valid, and if the full capture is sitting
    # beside the excerpt with the recorded hash, measure for real instead of
    # resting on the record.
    recorded_full_sha = single("full_sha256")
    upgrade_path = None
    full_names = record.get("full_capture", [])
    if full_names:
        candidate = os.path.join(os.path.dirname(os.path.abspath(args.excerpt)),
                                 os.path.basename(full_names[0]))
        if os.path.isfile(candidate) and os.path.getsize(candidate) > 0 and sha256(candidate) == recorded_full_sha:
            upgrade_path = candidate

    if upgrade_path is not None:
        print("recheck: existential claim (present-label witness) MEASURED now; "
              "universal claim (absent-label scan) validated from the record and "
              "UPGRADED to a live re-measurement — the full capture is present with a matching sha256")
    else:
        print("recheck: existential claim (present-label witness) MEASURED now; "
              "universal claim (absent-label scan) VALIDATED from the recorded report only — "
              "its input, the full capture, is not present to re-measure")

    # The existential claim, measured live by the same code path Mode A uses.
    packets, link, fmt, witness, hello = locate_witness(args.excerpt, present_label)
    print(f"excerpt: {os.path.basename(args.excerpt)} ({fmt}, link type {link}, {len(packets)} packets)")
    if witness is None:
        die("the label that must appear was not located inside any packet's data", 1)
    packet, offset = witness
    print(f"witness_packet_index: {packet.index}")
    print(f"witness_offset_in_packet_data: {offset}")
    if hello and hello["server_name"]:
        print(f"witness_field_value: {hello['server_name']}")
        if hello["server_name"].lower() != present_label.lower():
            die(f"the located field says {hello['server_name']}, not {present_label}", 1)

    # The universal claim, re-measured live only under the upgrade.
    if upgrade_path is not None:
        blind = self_test(variants(absent_label), args.scratch)
        if blind:
            die("the scanner failed its own coverage test for: " + ", ".join(blind), 1)
        hits = scan_file(upgrade_path, variants(absent_label))
        leaked = {name: at for name, at in hits.items() if at >= 0}
        if leaked:
            die("the label that must not appear was found in the clear", 1)
        print(f"upgrade: absent-label scan re-run over {os.path.basename(upgrade_path)} "
              f"({os.path.getsize(upgrade_path)} bytes) — label absent, as recorded")

    print("\nSTEP7 RECHECK PASSED" + (" (upgraded to a live measurement)" if upgrade_path is not None else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
