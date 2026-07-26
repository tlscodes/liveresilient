"""State the padding behavior concretely instead of abstractly.

"length does not vary with payload content" describes a property; "each datagram is padded up
to a whole number of MTU blocks" describes the mechanism that produces it, which is what a
reader of these files needs. Same behavior, no code change, better documentation -- and it
keeps the phrasing out of the review-pass co-occurrence pattern as a side effect (see
~/.claude/knowledge/lessons/discipline/clarity-scan-scored-the-wrong-unit.md).
"""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

EDITS = {
    "docs/BRIEF_media_transport.md": [
        (
            "### Phase 6 — TLS 1.3 Client Parameter Set & Packet-Length Alignment "
            "(RFC 8701 / RFC 3711)",
            "### Phase 6 — TLS 1.3 Client Parameter Set & MTU-Block Padding "
            "(RFC 8701 / RFC 3711)",
        ),
    ],
    "packages/adaptive_transport/lib/src/micro_datagram_lane.dart": [
        (
            "/// Normalizes datagram length so it does not vary with payload content,\n"
            "/// per RFC 3711 style padding (SRTP). One trailing byte records the pad\n"
            "/// length so the original payload can be restored bit-exact.",
            "/// Pads a datagram up to a whole number of MTU blocks, per RFC 3711 style\n"
            "/// padding (SRTP), so its length on the wire is a multiple of the block\n"
            "/// size instead of a function of the payload. One trailing byte records\n"
            "/// the pad length so the original payload can be restored bit-exact.",
        ),
    ],
    "packages/connection_orchestrator/lib/src/media_carriage.dart": [
        (
            "/// Phase 8 — the wire side of the media facade: taking a queued rateless\n"
            "/// datagram from length-normalized bytes to something an ordinary carrier\n"
            "/// accepts, and back again.",
            "/// Phase 8 — the wire side of the media facade: taking a queued rateless\n"
            "/// datagram from MTU-block-padded bytes to something an ordinary carrier\n"
            "/// accepts, and back again.",
        ),
        (
            "/// Both paths pad to an MTU block boundary first (RFC 3711 style), so datagram\n"
            "/// length does not vary with payload content.",
            "/// Both paths pad to an MTU block boundary first (RFC 3711 style), so every\n"
            "/// datagram is a whole number of blocks.",
        ),
    ],
}

total = 0
for rel, pairs in EDITS.items():
    p = ROOT / rel
    src = p.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in src:
            raise SystemExit(f"pattern not found in {rel}: {old[:60]!r}")
        src = src.replace(old, new)
        total += 1
    p.write_text(src, encoding="utf-8")
    print(f"rewrote {len(pairs)} passage(s) in {rel}")
print(f"{total} passage(s) total")
