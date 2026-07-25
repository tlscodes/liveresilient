#!/usr/bin/env python3
"""Update tick() consumers for the TaggedDatagram round-robin change.

media_queue_test.dart : datagram bytes now live on `.bytes`.
resilient_media_transport_test.dart : route each datagram by its own
`.transferId` instead of assuming a whole tick batch belongs to
queue.active — that assumption is what round-robin invalidated.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = ROOT / "packages/connection_orchestrator"


def patch(path: pathlib.Path, pairs):
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            sys.exit(f"anchor not found in {path.name}:\n{old}")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print(f"patched {path.name}")


OLD_LOOP = """      // All datagrams in one tick batch come from the transfer that was
      // active at emission time — attribute them to IT, not to whoever
      // is active after a mid-batch completion.
      final emitterId = transport.queue.active?.id;
      for (final d in transport.queue.tick(
          nowMs: nowMs, voiceIsSpeaking: speaking)) {
        mediaBytesOnWire += d.length;
        // hostile channel: 60% uniform loss + GE bursts
        if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
        if (emitterId == null) return;
        final dec = decoders.putIfAbsent(emitterId, RatelessDecoder.new);
        dec.addDatagram(d);
        if (dec.isComplete && !completedAt.containsKey(emitterId)) {
          completedAt[emitterId] = nowMs;
          transport.queue.markComplete(emitterId);
        }
      }"""

NEW_LOOP = """      // The queue round-robins between concurrent transfers, so a single
      // tick batch can mix datagrams from several of them. Each datagram
      // carries its own transferId — route by that, never by whichever
      // transfer happens to be at the head of the queue.
      for (final d in transport.queue.tick(
          nowMs: nowMs, voiceIsSpeaking: speaking)) {
        mediaBytesOnWire += d.bytes.length;
        // hostile channel: 60% uniform loss + GE bursts
        if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
        final id = d.transferId;
        final dec = decoders.putIfAbsent(id, RatelessDecoder.new);
        dec.addDatagram(d.bytes);
        if (dec.isComplete && !completedAt.containsKey(id)) {
          completedAt[id] = nowMs;
          transport.queue.markComplete(id);
        }
      }"""

patch(PKG / "test/resilient_media_transport_test.dart", [(OLD_LOOP, NEW_LOOP)])
