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
# A query carrying this sequence number is a read-only poll: the server
# answers whatever downstream bytes the session holds and stores nothing,
# so polling can never overwrite a session's chunk 0 (review 2026-09-13,
# txt_query_client.py:185). Same width, same alphabet — no byte change.
POLL_SEQ = SEQ_MAX
MARKER = "q"
TUNNEL = "tunnel"
QTYPE_TXT = 16
QCLASS_IN = 1
OPT_TYPE = 41
EDNS0_UDP_SIZE = 1232  # RFC 9715 / DNS Flag Day 2020 — not 4096
RCODE_NOERROR = 0
RCODE_NXDOMAIN = 3
FRAME_HDR = 2

# Octets of an answer that are not the TXT rdata:
#     12  the header
#      4  qtype and qclass, after the question's owner name
#     12  the answer record: a 2-octet compression pointer as its owner name
#         (RFC 1035 section 4.1.4), then type, class, ttl and rdlength
#     11  the OPT record
# The question's owner name is counted apart, since its length is the
# caller's rather than a constant: a presentation name of L characters is
# L + 2 octets on the wire.
ANSWER_FIXED_OCTETS = 12 + 4 + 12 + 11
_WORST_CASE_RDATA_ROOM = EDNS0_UDP_SIZE - ANSWER_FIXED_OCTETS - (FQDN_MAX + 2)

# Derived, not chosen. The rdata carries the framed payload split into
# 255-octet strings, each paying its own length octet, so R octets of rdata
# carry R - ceil(R / 256) framed octets; the frame header costs FRAME_HDR
# more. Evaluated at FQDN_MAX this holds for every legal question name;
# max_downstream_payload_for() returns the octets a shorter name earns back.
DOWNSTREAM_BUDGET = (
    _WORST_CASE_RDATA_ROOM - (_WORST_CASE_RDATA_ROOM + 255) // 256 - FRAME_HDR
)


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
    # A label is octets on the wire, not characters, and only ASCII ones: a
    # non-ASCII domain used to pass both limits here and then raise
    # UnicodeEncodeError out of _encode_name, which is not the error type the
    # callers of this module catch. Refuse it here, and measure both limits in
    # the octets the encoder will actually write.
    octets = 0
    for lab in labels:
        try:
            raw = lab.encode("ascii")
        except UnicodeEncodeError as exc:
            raise WireError(f"non-ASCII label {lab!r}") from exc
        if not raw or len(raw) > LABEL_MAX:
            raise WireError(f"bad label {lab!r}")
        octets += len(raw)
    name = ".".join(labels)
    total = octets + len(labels) - 1  # the separating dots
    if total > FQDN_MAX:
        raise WireError(f"FQDN {total} > {FQDN_MAX}")
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
    # The sequence label has a fixed width for the same reason the two beside
    # it do: without the pin, 'aab', 'b' and 'ab' all decode to sequence 1 and
    # '' decodes to 0, so two names can claim the same chunk of one payload and
    # reassembly either raises a conflict or silently accepts the wrong bytes.
    if len(seq_l) != SEQ_CHARS:
        raise WireError(f"seq label {seq_l!r} is {len(seq_l)} chars, want {SEQ_CHARS}")
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


def name_wire_length(name: str) -> int:
    """Octets `name` occupies on the wire, the root label included."""
    total = 1
    for label in name.split("."):
        if label:
            total += 1 + len(label)
    return total


def max_downstream_payload_for(question_name: str) -> int:
    """The most an answer to `question_name` may carry inside EDNS0_UDP_SIZE.

    Uses the real name instead of the FQDN_MAX worst case DOWNSTREAM_BUDGET
    assumes, which is worth several hundred octets on a short zone.
    """
    room = EDNS0_UDP_SIZE - ANSWER_FIXED_OCTETS - name_wire_length(question_name)
    if room <= 0:
        return 0
    return max(room - (room + 255) // 256 - FRAME_HDR, 0)


def frame_down(payload: bytes, question_name: str | None = None) -> bytes:
    budget = (
        DOWNSTREAM_BUDGET
        if question_name is None
        else max_downstream_payload_for(question_name)
    )
    if len(payload) > budget:
        raise WireError(f"downstream {len(payload)} > {budget}")
    return frame_up(payload)


def unframe_down(framed: bytes) -> bytes:
    return unframe_up(framed)


def _encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.split("."):
        if not label:
            continue
        try:
            raw = label.encode("ascii")
        except UnicodeEncodeError as exc:
            # WireError is the only exception this module raises for input it
            # refuses; a codec error escaping here would bypass every caller.
            raise WireError(f"non-ASCII label {label!r}") from exc
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
        # Slicing past the end used to clamp silently, so a label claiming more
        # octets than the datagram holds produced a short name instead of an
        # error. And a label octet >= 0x80 raised UnicodeDecodeError, which is
        # not the exception type this module's callers catch.
        if pos + length > len(buf):
            raise WireError("label past end")
        try:
            labels.append(buf[pos : pos + length].decode("ascii"))
        except UnicodeDecodeError as exc:
            raise WireError("non-ASCII label") from exc
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
        if pos + length > len(rdata):
            raise WireError("truncated TXT string")
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
        # RFC 1035 section 4.1.4: the answer's owner name is a pointer back
        # to the question at offset 12, not a second uncompressed copy. The
        # second copy is legal but costs the whole name again, which is what
        # pushed answers at the budget past the size the query advertised.
        owner = b"\xc0\x0c"
        answer = owner + struct.pack(">HHIH", QTYPE_TXT, QCLASS_IN, 0, len(rdata)) + rdata
    return header + question + answer + _opt_rr()


@dataclass
class ParsedDnsAnswer:
    txid: int
    rcode: int
    payload: bytes | None
    # The question name carries the session id and nonce that a query-response
    # binding by txid alone cannot see. Kept so a caller can compare it against
    # the name it actually sent (RFC 5452 section 9.1), instead of trusting a
    # 16-bit transaction id on its own. None when the answer has no question.
    question_name: str | None = None


def parse_dns_answer_packet(packet: bytes) -> ParsedDnsAnswer:
    if len(packet) < 12:
        raise WireError("short header")
    txid, flags, qdcount, ancount = struct.unpack(">HHHH", packet[:8])
    rcode = flags & 0x0F
    pos = 12
    question_name: str | None = None
    for _ in range(qdcount):
        name, pos = _decode_name(packet, pos)
        if question_name is None:
            question_name = name
        pos += 4
    if ancount == 0:
        return ParsedDnsAnswer(txid, rcode, None, question_name)
    _, pos = _decode_name(packet, pos)
    if pos + 10 > len(packet):
        raise WireError("truncated answer")
    rtype, rclass, _ttl, rdlength = struct.unpack(">HHIH", packet[pos : pos + 10])
    pos += 10
    # Slicing a declared length the datagram does not hold used to return a
    # short payload instead of refusing the record.
    if pos + rdlength > len(packet):
        raise WireError("truncated rdata")
    if rtype != QTYPE_TXT:
        raise WireError(f"expected TXT answer, got {rtype}")
    return ParsedDnsAnswer(
        txid,
        rcode,
        _parse_txt_rdata(packet[pos : pos + rdlength]),
        question_name,
    )
