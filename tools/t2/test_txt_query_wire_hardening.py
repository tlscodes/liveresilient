#!/usr/bin/env python3
"""Parse-side guards of txt_query_wire.py, from the 2026-09-13 review.

test_txt_query_wire.py already holds the round-trip gate; this file is the
refusal side of the same module — every input the parser must reject, and the
one exception type it is allowed to raise while rejecting it. Nothing here
changes the bytes the module emits: the last case pins an encoded name against
its literal, which is the same identity the Dart goldens check.

USAGE  python3 tools/t2/test_txt_query_wire_hardening.py   -> exit 0 on PASS
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import txt_query_wire as wire  # noqa: E402
from txt_query_wire import (  # noqa: E402
    POLL_SEQ,
    SEQ_CHARS,
    WireError,
    build_dns_answer_packet,
    build_dns_query_packet,
    build_query_name,
    parse_dns_answer_packet,
    parse_dns_query_packet,
    parse_query_name,
)

DOMAIN = "example.test"
NAME = "q.AA.AAAAAA.AAAA.0.tunnel.example.test"
failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    extra = f" {detail}" if detail else ""
    print(f"  {'PASS' if ok else 'FAIL'} {name}{extra}")
    if not ok:
        failures += 1


def refuses(name: str, fn) -> None:
    """The call must raise WireError — not a codec error, not nothing."""
    try:
        fn()
    except WireError as exc:
        check(name, True, f"WireError: {exc}")
    except Exception as exc:  # noqa: BLE001 - the point of the case
        check(name, False, f"raised {type(exc).__name__}: {exc}")
    else:
        check(name, False, "no exception")


def rdata_offset(question_name: str) -> int:
    """Where the TXT rdata starts in an answer built for `question_name`."""
    # header(12) + name + qtype/qclass(4) + owner pointer(2) + rr fixed(10)
    return 12 + len(wire._encode_name(question_name)) + 4 + 2 + 10


def main() -> int:
    print("gate_wire_hardening")

    # --- the answer carries the question name -----------------------------
    answer = build_dns_answer_packet(0x1234, NAME, wire.frame_down(b"hi"))
    parsed = parse_dns_answer_packet(answer)
    check("question_name populated", parsed.question_name == NAME, repr(parsed.question_name))
    empty = build_dns_answer_packet(0x1234, NAME, None, rcode=wire.RCODE_NXDOMAIN)
    check(
        "question_name on an answer with no record",
        parse_dns_answer_packet(empty).question_name == NAME,
    )

    # --- declared lengths are bounded by the datagram ----------------------
    # The OPT record is 11 octets; dropping it plus two rdata octets leaves
    # rdlength claiming more than the buffer holds.
    refuses("rdlength past end", lambda: parse_dns_answer_packet(answer[:-13]))

    at = rdata_offset(NAME)
    bad_txt = answer[:at] + bytes([250]) + answer[at + 1 :]
    refuses("TXT string past end", lambda: parse_dns_answer_packet(bad_txt))
    refuses("TXT string past end, rdata alone", lambda: wire._parse_txt_rdata(bytes([5, 65, 66])))

    # --- names decode strictly --------------------------------------------
    query = build_dns_query_packet(0x4321, NAME)
    non_ascii = query[:13] + b"\xff" + query[14:]
    refuses("non-ASCII label", lambda: parse_dns_query_packet(non_ascii))
    past_end = bytes([query[i] if i != 12 else 62 for i in range(20)])
    refuses("label past end", lambda: parse_dns_query_packet(past_end))

    # --- the sequence label has one legal width ---------------------------
    for seq_l in ("", "b", "aab"):
        refuses(
            f"seq label {seq_l!r} refused",
            lambda s=seq_l: parse_query_name(f"q.{s}.aaaaaa.aaaa.0.tunnel.{DOMAIN}", DOMAIN),
        )
    good = parse_query_name(f"q.ab.aaaaaa.aaaa.0.tunnel.{DOMAIN}", DOMAIN)
    check("seq label 'ab' still parses", good.seq == 1, f"seq={good.seq}")
    check("SEQ_CHARS unchanged", SEQ_CHARS == 2, str(SEQ_CHARS))

    # --- a non-ASCII domain is refused, in this module's own error type ----
    refuses(
        "non-ASCII domain in build_query_name",
        lambda: build_query_name(b"", 0, "AAAAAA", "AAAA", "exämple.test"),
    )
    refuses(
        "non-ASCII name in build_dns_query_packet",
        lambda: build_dns_query_packet(1, "exämple.test"),
    )

    # --- POLL_SEQ is an ordinary sequence number on the wire ---------------
    poll_name = build_query_name(b"", POLL_SEQ, "AAAAAA", "AAAA", DOMAIN)
    check("poll name parses", parse_query_name(poll_name, DOMAIN).seq == POLL_SEQ, poll_name)
    check("POLL_SEQ == SEQ_MAX", POLL_SEQ == wire.SEQ_MAX, str(POLL_SEQ))

    # --- the emitted bytes did not move ------------------------------------
    literal = build_query_name(bytes(range(4)), 1, "AAAAAA", "AAAA", DOMAIN)
    check(
        "encoded name byte-identical",
        literal == "q.AB.AAAAAA.AAAA.AAAQEAY.tunnel.example.test",
        literal,
    )

    print("journey_txt_query_wire_hardening " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
