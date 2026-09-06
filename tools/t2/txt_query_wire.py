#!/usr/bin/env python3
"""Wire format for the DNS emergency valve.

Design: docs/dns-emergency-valve-design-2026-09-06.md §2, §3, §4.
Query name:

    q.<seq2>.<session6>.<nonce4>.<payload_b32>.tunnel.<domain>

Base32 is RFC 4648, unpadded, case-insensitive. DNS labels cannot carry '='.
"""

from __future__ import annotations

import base64
import secrets
import struct
from dataclasses import dataclass

LABEL_MAX = 63
FQDN_MAX = 253
RAW_PER_LABEL = 39  # 63 * 5 // 8
SEQ_CHARS = 2
SESSION_CHARS = 6
NONCE_CHARS = 4
SEQ_MAX = 1023
MARKER = "q"
TUNNEL = "tunnel"
QTYPE_TXT = 16
QCLASS_IN = 1
OPT_TYPE = 41
EDNS0_UDP_SIZE = 1232  # RFC 9715 / DNS Flag Day 2020 — not 4096
RCODE_NOERROR = 0
RCODE_NXDOMAIN = 3
FRAME_HDR = 2
DOWNSTREAM_BUDGET = 1150


class WireError(ValueError):
    pass


def b32_encode_strip(data: bytes) -> str:
    if not data:
        return "0"
    return base64.b32encode(data).decode("ascii").rstrip("=")


def b32_decode_pad(text: str) -> bytes:
    text = text.upper()
    if text == "0":
        return b""
    pad = (-len(text)) % 8
    try:
        return base64.b32decode(text + "=" * pad)
    except Exception as exc:
        raise WireError(f"bad Base32 {text!r}") from exc


B32ALPH = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def encode_int(n: int, width: int) -> str:
    if n < 0:
        raise WireError("negative")
    out = []
    x = n
    for _ in range(width):
        out.append(B32ALPH[x & 31])
        x >>= 5
    if x:
        raise WireError(f"{n} does not fit in {width} Base32 chars")
    return "".join(reversed(out))


def decode_int(label: str) -> int:
    n = 0
    for ch in label.upper():
        idx = B32ALPH.find(ch)
        if idx < 0:
            raise WireError(f"illegal Base32 char {ch!r}")
        n = (n << 5) | idx
    return n


def encode_seq(n: int) -> str:
    if not 0 <= n <= SEQ_MAX:
        raise WireError(f"seq {n} out of 0..{SEQ_MAX}")
    return encode_int(n, SEQ_CHARS)


def decode_seq(label: str) -> int:
    n = decode_int(label)
    if n > SEQ_MAX:
        raise WireError(f"seq {n} out of range")
    return n


def new_session_id() -> str:
    return encode_int(secrets.randbits(SESSION_CHARS * 5), SESSION_CHARS)


def new_nonce() -> str:
    return encode_int(secrets.randbits(NONCE_CHARS * 5), NONCE_CHARS)


def frame_up(payload: bytes) -> bytes:
    if len(payload) > 0xFFFF:
        raise WireError("payload exceeds u16")
    return len(payload).to_bytes(FRAME_HDR, "big") + payload


def unframe_up(framed: bytes) -> bytes:
    if len(framed) < FRAME_HDR:
        raise WireError("truncated frame")
    n = int.from_bytes(framed[:FRAME_HDR], "big")
    body = framed[FRAME_HDR:]
    if len(body) < n:
        raise WireError(f"incomplete frame have={len(body)} want={n}")
    return body[:n]


def split_chunks(framed: bytes) -> list[bytes]:
    if not framed:
        return [b""]
    return [framed[i : i + RAW_PER_LABEL] for i in range(0, len(framed), RAW_PER_LABEL)]


def build_query_name(chunk: bytes, seq: int, session_id: str, nonce: str, domain: str) -> str:
    payload_label = b32_encode_strip(chunk)
    if len(payload_label) > LABEL_MAX:
        raise WireError(f"payload label {len(payload_label)} > {LABEL_MAX}")
    domain = domain.strip(".").lower()
    labels = [MARKER, encode_seq(seq), session_id, nonce, payload_label, TUNNEL, *domain.split(".")]
    for lab in labels:
        if not lab or len(lab) > LABEL_MAX:
            raise WireError(f"bad label {lab!r}")
    name = ".".join(labels)
    if len(name) > FQDN_MAX:
        raise WireError(f"FQDN {len(name)} > {FQDN_MAX}")
    return name


@dataclass
class ParsedQuery:
    seq: int
    session_id: str
    nonce: str
    chunk: bytes
    domain: str
    name: str


def parse_query_name(name: str, expected_domain: str) -> ParsedQuery:
    expected_domain = expected_domain.strip(".").lower()
    suffix = f".{TUNNEL}.{expected_domain}"
    lowered = name.strip(".").lower()
    if not lowered.endswith(suffix.lstrip(".")):
        # accept either with or without leading marker check via endswith on full
        if not lowered.endswith(f"{TUNNEL}.{expected_domain}"):
            raise WireError(f"not a valve query for {expected_domain!r}: {name!r}")
    parts = lowered.split(".")
    zone = [TUNNEL, *expected_domain.split(".")]
    if parts[-len(zone) :] != zone:
        raise WireError(f"zone mismatch {parts[-len(zone):]}")
    head = parts[: -len(zone)]
    if len(head) != 5 or head[0] != MARKER:
        raise WireError(f"bad head {head}")
    _, seq_l, session_id, nonce, payload_l = head
    if len(session_id) != SESSION_CHARS or len(nonce) != NONCE_CHARS:
        raise WireError("session/nonce width")
    return ParsedQuery(
        seq=decode_seq(seq_l),
        session_id=session_id,
        nonce=nonce,
        chunk=b32_decode_pad(payload_l),
        domain=expected_domain,
        name=lowered,
    )


def encode_queries(payload: bytes, domain: str, session_id: str | None = None) -> tuple[str, list[str]]:
    session_id = session_id or new_session_id()
    names = []
    for seq, chunk in enumerate(split_chunks(frame_up(payload))):
        names.append(
            build_query_name(chunk, seq, session_id, new_nonce(), domain)
        )
    return session_id, names


def reassemble(parsed: list[ParsedQuery]) -> bytes:
    if not parsed:
        raise WireError("no chunks")
    by_seq = {}
    for p in parsed:
        if p.seq in by_seq and by_seq[p.seq] != p.chunk:
            raise WireError(f"conflict at seq {p.seq}")
        by_seq[p.seq] = p.chunk
    missing = [i for i in range(max(by_seq) + 1) if i not in by_seq]
    if missing:
        raise WireError(f"missing seq {missing}")
    return unframe_up(b"".join(by_seq[i] for i in range(max(by_seq) + 1)))


def frame_down(payload: bytes) -> bytes:
    if len(payload) > DOWNSTREAM_BUDGET:
        raise WireError(f"downstream {len(payload)} > {DOWNSTREAM_BUDGET}")
    return frame_up(payload)


def unframe_down(framed: bytes) -> bytes:
    return unframe_up(framed)


def _encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.split("."):
        if not label:
            continue
        raw = label.encode("ascii")
        if len(raw) > LABEL_MAX:
            raise WireError(f"label too long {label!r}")
        out.append(len(raw))
        out += raw
    out.append(0)
    return bytes(out)


def _decode_name(buf: bytes, offset: int, depth: int = 0) -> tuple[str, int]:
    if depth > 10:
        raise WireError("compression loop")
    labels: list[str] = []
    pos = offset
    jumped = False
    end = offset
    while True:
        if pos >= len(buf):
            raise WireError("name past end")
        length = buf[pos]
        if length == 0:
            if not jumped:
                end = pos + 1
            break
        if length & 0xC0 == 0xC0:
            if pos + 1 >= len(buf):
                raise WireError("truncated pointer")
            target = ((length & 0x3F) << 8) | buf[pos + 1]
            if not jumped:
                end = pos + 2
            jumped = True
            inner, _ = _decode_name(buf, target, depth + 1)
            labels.append(inner)
            break
        if length & 0xC0:
            raise WireError("bad label type")
        pos += 1
        labels.append(buf[pos : pos + length].decode("ascii"))
        pos += length
        if not jumped:
            end = pos
    return ".".join(labels), end


def _opt_rr(udp_payload_size: int = EDNS0_UDP_SIZE) -> bytes:
    return b"\x00" + struct.pack(">HHIH", OPT_TYPE, udp_payload_size, 0, 0)


def build_dns_query_packet(txid: int, name: str) -> bytes:
    header = struct.pack(">HHHHHH", txid & 0xFFFF, 0x0100, 1, 0, 0, 1)
    question = _encode_name(name) + struct.pack(">HH", QTYPE_TXT, QCLASS_IN)
    return header + question + _opt_rr()


@dataclass
class ParsedDnsQuery:
    txid: int
    name: str


def parse_dns_query_packet(packet: bytes) -> ParsedDnsQuery:
    if len(packet) < 12:
        raise WireError("short header")
    txid, _flags, qdcount = struct.unpack(">HHH", packet[:6])
    if qdcount != 1:
        raise WireError(f"qdcount {qdcount}")
    name, pos = _decode_name(packet, 12)
    if pos + 4 > len(packet):
        raise WireError("truncated question")
    qtype, qclass = struct.unpack(">HH", packet[pos : pos + 4])
    if qtype != QTYPE_TXT or qclass != QCLASS_IN:
        raise WireError(f"expected TXT/IN got {qtype}/{qclass}")
    return ParsedDnsQuery(txid, name)


def _txt_rdata(payload: bytes) -> bytes:
    if not payload:
        return b"\x00"
    out = bytearray()
    for i in range(0, len(payload), 255):
        piece = payload[i : i + 255]
        out.append(len(piece))
        out += piece
    return bytes(out)


def _parse_txt_rdata(rdata: bytes) -> bytes:
    out = bytearray()
    pos = 0
    while pos < len(rdata):
        length = rdata[pos]
        pos += 1
        out += rdata[pos : pos + length]
        pos += length
    return bytes(out)


def build_dns_answer_packet(
    txid: int,
    question_name: str,
    payload: bytes | None,
    rcode: int = RCODE_NOERROR,
) -> bytes:
    flags = 0x8400 | (rcode & 0x0F)  # QR + AA
    ancount = 1 if payload is not None and rcode == RCODE_NOERROR else 0
    header = struct.pack(">HHHHHH", txid & 0xFFFF, flags, 1, ancount, 0, 1)
    question = _encode_name(question_name) + struct.pack(">HH", QTYPE_TXT, QCLASS_IN)
    answer = b""
    if ancount:
        rdata = _txt_rdata(payload or b"")
        answer = _encode_name(question_name) + struct.pack(">HHIH", QTYPE_TXT, QCLASS_IN, 0, len(rdata)) + rdata
    return header + question + answer + _opt_rr()


@dataclass
class ParsedDnsAnswer:
    txid: int
    rcode: int
    payload: bytes | None


def parse_dns_answer_packet(packet: bytes) -> ParsedDnsAnswer:
    if len(packet) < 12:
        raise WireError("short header")
    txid, flags, qdcount, ancount = struct.unpack(">HHHH", packet[:8])
    rcode = flags & 0x0F
    pos = 12
    for _ in range(qdcount):
        _, pos = _decode_name(packet, pos)
        pos += 4
    if ancount == 0:
        return ParsedDnsAnswer(txid, rcode, None)
    _, pos = _decode_name(packet, pos)
    if pos + 10 > len(packet):
        raise WireError("truncated answer")
    rtype, rclass, _ttl, rdlength = struct.unpack(">HHIH", packet[pos : pos + 10])
    pos += 10
    if rtype != QTYPE_TXT:
        raise WireError(f"expected TXT answer, got {rtype}")
    return ParsedDnsAnswer(txid, rcode, _parse_txt_rdata(packet[pos : pos + rdlength]))
