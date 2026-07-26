#!/usr/bin/env python3
"""Phase 4c refinement: carry the motion vector inside the coded stream.

Two raw header bytes per frame cost 2 bytes unconditionally, which loses
on static scenes where the vector is (0,0). Feeding the vector through
the context-mixing coder instead costs a few BITS when it is constant --
which it is for static or steadily-panning footage -- while keeping the
full generality of per-frame motion.
"""
import pathlib
import sys

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/media_codecs/flipbook_video_compressor.dart"
)

OLD_ENC = '''        final (dx, dy) = _searchMotion(q, prev);
        final td = _motionResidual(q, prev, dx, dy);
        final body = _cm.compress(td);
        // Two header bytes carry the vector so the decoder shifts the
        // same way; biased by 128 to stay in an unsigned byte.
        final tdc = Uint8List(body.length + 2);
        tdc[0] = dx + 128;
        tdc[1] = dy + 128;
        tdc.setRange(2, tdc.length, body);'''

NEW_ENC = '''        final (dx, dy) = _searchMotion(q, prev);
        final residual = _motionResidual(q, prev, dx, dy);
        // The vector rides at the head of the payload and goes through
        // the entropy coder with everything else: on static or steadily
        // panning footage it is the same two bytes every frame, so the
        // model reduces it to a few bits instead of a flat 2-byte tax.
        final td = Uint8List(residual.length + 2);
        td[0] = dx + 128;
        td[1] = dy + 128;
        td.setRange(2, td.length, residual);
        final tdc = _cm.compress(td);'''

OLD_DEC = '''        if (f.bytes.length < 2) {
          throw const FormatException('temporal frame missing motion header');
        }
        final dx = f.bytes[0] - 128;
        final dy = f.bytes[1] - 128;
        final td = _cm.decompress(Uint8List.sublistView(f.bytes, 2));
        q = Uint8List(td.length);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            q[i] = (td[i] + _shifted(prev, x, y, dx, dy)) & 0xFF;
          }
        }'''

NEW_DEC = '''        final payload = _cm.decompress(f.bytes);
        if (payload.length < 2) {
          throw const FormatException('temporal frame missing motion header');
        }
        final dx = payload[0] - 128;
        final dy = payload[1] - 128;
        final td = Uint8List.sublistView(payload, 2);
        q = Uint8List(td.length);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            q[i] = (td[i] + _shifted(prev, x, y, dx, dy)) & 0xFF;
          }
        }'''

text = TARGET.read_text(encoding="utf-8")
for old, new in ((OLD_ENC, NEW_ENC), (OLD_DEC, NEW_DEC)):
    if old not in text:
        sys.exit(f"anchor not found:\n{old[:70]}")
    text = text.replace(old, new, 1)
TARGET.write_text(text, encoding="utf-8")
print(f"patched {TARGET.name}")
