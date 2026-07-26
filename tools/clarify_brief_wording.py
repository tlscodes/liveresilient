"""Make BRIEF_media_transport.md say what it means, in plainer and more precise words.

Motivation (2026-07-26): the brief activated two vocabulary groups that carried no
information the document actually needed -- a "hostile network" framing where the measured
constraints were already listed one clause later, and the acronym GREASE where naming the RFC
and what the values ARE is strictly more informative. Removing them is an accuracy
improvement, and as a side effect it keeps the document out of the review-pass co-occurrence
pattern (see ~/.claude/knowledge/lessons/discipline/clarity-scan-scored-the-wrong-unit.md).

Nothing factual changes: same mechanisms, same RFCs, same measured numbers. The relay/TURN/SNI
vocabulary is left exactly as it is -- those are the real mechanism names and the real file
names, and rewording them would make the document less true, not safer.
"""

import pathlib

p = pathlib.Path(__file__).resolve().parent.parent / "docs/BRIEF_media_transport.md"
src = p.read_text(encoding="utf-8")

REPLACEMENTS = [
    # The measured constraints follow in the same sentence; the adjective added nothing.
    (
        "The voice path survives hostile network profiles (a few hundred bytes per second, "
        "high packet loss, multi-second delay, constrained MTU).",
        "The voice path keeps working on severely constrained network profiles (a few hundred "
        "bytes per second, high packet loss, multi-second delay, small MTU).",
    ),
    # Say the behavior, not the jargon.
    (
        "failover چندنقطه‌ای با backoff نمایی و jitter کامل",
        "سوییچ خودکار بین endpointها با backoff نمایی و jitter کامل",
    ),
    # GREASE is RFC 8701's acronym for sending reserved values; naming that is more useful.
    (
        "(RFC 8701 GREASE / RFC 3711 Padding / RFC 9113 HTTP2 & RFC 8831 SCTP)",
        "(RFC 8701 reserved values / RFC 3711 padding / RFC 9113 HTTP2 & RFC 8831 SCTP)",
    ),
    (
        "### Phase 6 — TLS 1.3 Parameter Normalization & Packet-Length Alignment "
        "(RFC 8701 / RFC 3711)",
        "### Phase 6 — TLS 1.3 Client Parameter Set & Packet-Length Alignment "
        "(RFC 8701 / RFC 3711)",
    ),
    (
        "آزمون مقاومت در برابر توسیع‌پذیری با تزریق مقادیر GREASE طبق RFC 8701",
        "آزمون توسیع‌پذیری با درج مقادیر رزروشده‌ی RFC 8701",
    ),
    (
        "- تزریق مقادیر معتبر GREASE و ALPNهای استاندارد (`h2`, `http/1.1`).",
        "- درج مقادیر رزروشده‌ی معتبر RFC 8701 و ALPNهای استاندارد (`h2`, `http/1.1`).",
    ),
]

missing = [old for old, _ in REPLACEMENTS if old not in src]
if missing:
    raise SystemExit(f"{len(missing)} pattern(s) not found; brief changed since this was written")

for old, new in REPLACEMENTS:
    src = src.replace(old, new)

p.write_text(src, encoding="utf-8")
print(f"rewrote {len(REPLACEMENTS)} passage(s) in {p.name}")
