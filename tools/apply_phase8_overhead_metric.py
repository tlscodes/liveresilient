"""Phase 8 test: report framing overhead against ALL emitted datagram bytes.

The first draft divided wire bytes by the bytes of the datagrams that survived
the 60%-loss channel, which inflated the ratio by the loss factor. The honest
denominator is the queue's own bytesEmitted counter (every datagram it handed
out), so the printed number is the cost of padding + carrier framing alone.
"""

from pathlib import Path

p = Path(__file__).resolve().parent.parent / (
    "packages/connection_orchestrator/test/resilient_media_transport_test.dart"
)
src = p.read_text(encoding="utf-8")

before = src
src = src.replace(
    """          final carried = transport.receiveFromWire(wire);
          paddedPayloadBytes += carried.bytes.length;
""",
    """          final carried = transport.receiveFromWire(wire);
""",
)
src = src.replace(
    "      final overhead = wireBytes / paddedPayloadBytes;",
    "      // Every datagram the queue emitted, padded and framed, versus its\n"
    "      // raw size — the true cost of the wire path, loss-independent.\n"
    "      final overhead = wireBytes / transport.queue.bytesEmitted;",
)
src = src.replace(
    "'framing (${overhead.toStringAsFixed(2)}x the delivered datagram '\n"
    "          'bytes); ",
    "'framing (${overhead.toStringAsFixed(2)}x the raw datagram bytes); ",
)

if src == before:
    raise SystemExit("no replacement applied")
p.write_text(src, encoding="utf-8")
print("patched", p)
