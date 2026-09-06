#!/usr/bin/env python3
"""Gate 1 — wire-format round-trip. No network. Design §7.1."""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from txt_query_wire import (  # noqa: E402
    FQDN_MAX,
    LABEL_MAX,
    b32_decode_pad,
    b32_encode_strip,
    encode_queries,
    parse_query_name,
    reassemble,
)

DOMAIN = "example.test"
failures = 0


def check(name: str, ok: bool, detail: str = "") -> int:
    status = "PASS" if ok else "FAIL"
    extra = f" {detail}" if detail else ""
    print(f"  {status} {name}{extra}")
    return 0 if ok else 1


def main() -> int:
    global failures
    print("gate_wire_format")
    for n, tag in ((29, "chat_29B"), (54, "rendezvous_54B")):
        payload = bytes(range(n))
        session, names = encode_queries(payload, DOMAIN)
        want_q = 1 if n == 29 else 2
        failures += check(f"{tag} query count", len(names) == want_q, f"got {len(names)}")
        parsed = []
        for qn in names:
            failures += check(f"{tag} FQDN<=253", len(qn) <= FQDN_MAX, str(len(qn)))
            for lab in qn.split("."):
                if len(lab) > LABEL_MAX:
                    failures += check(f"{tag} label<=63", False, f"{len(lab)} {lab[:20]}")
                    break
            else:
                failures += check(f"{tag} labels<=63", True)
            parsed.append(parse_query_name(qn, DOMAIN))
        nonces = [p.nonce for p in parsed]
        failures += check(f"{tag} unique nonce", len(set(nonces)) == len(nonces))
        failures += check(f"{tag} session stable", all(p.session_id == session.lower() for p in parsed))
        got = reassemble(parsed)
        failures += check(f"{tag} payload round-trip", got == payload)

    raw = bytes(range(39))
    enc = b32_encode_strip(raw)
    failures += check("39B label<=63", len(enc) <= LABEL_MAX, str(len(enc)))
    failures += check("Base32 exact", b32_decode_pad(enc) == raw)
    failures += check("Base32 survives case-fold", b32_decode_pad(enc.lower()) == raw)

    print("journey_txt_query_wire " + ("PASS" if failures == 0 else "FAIL"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
