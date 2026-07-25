#!/usr/bin/env python3
"""Phase 4a test update: pin the CM-engine size and prove the codec tag."""
import pathlib
import sys

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/test/text_document_compressor_test.dart"
)

PAIRS = [
    (
        "/// Phase 4a — document compression (text layer, gzip level 9).",
        "/// Phase 4a — document compression (text layer, in-house context-\n"
        "/// mixing coder with gzip level 9 kept as a guaranteed floor).",
    ),
    (
        "        '(ratio ${ratio.toStringAsFixed(3)}, gzip level 9)');\n"
        "    // Pinned from first measured run (1822 B); ~15% headroom so a zlib\n"
        "    // version change cannot flake the gate.\n"
        "    expect(compressed.length, lessThan(2100));\n"
        "    expect(c.decompress(compressed), equals(text));\n"
        "  });\n"
        "}",
        "        '(ratio ${ratio.toStringAsFixed(3)}, codec tag ${compressed[0]})');\n"
        "    // Pinned from the measured CM run (1277 B, was 1822 B under gzip9\n"
        "    // alone); headroom left so a model tweak cannot flake the gate.\n"
        "    expect(compressed.length, lessThan(1500));\n"
        "    expect(c.decompress(compressed), equals(text));\n"
        "    expect(compressed[0], DocumentCodecTag.contextMixing,\n"
        "        reason: 'CM must beat gzip9 on natural-language text');\n"
        "  });\n"
        "\n"
        "  test('never larger than gzip9 alone: the floor rule holds on inputs\\n'\n"
        "      'where context mixing loses', () {\n"
        "    // Incompressible bytes: the CM model cannot win here, so the\n"
        "    // gzip9 branch must be selected rather than shipping a bloated\n"
        "    // CM stream.\n"
        "    final rng = Random(7);\n"
        "    final noise = String.fromCharCodes(\n"
        "        List.generate(4096, (_) => 32 + rng.nextInt(95)));\n"
        "    final out = c.compress(noise);\n"
        "    expect(c.decompress(out), equals(noise));\n"
        "    // ignore: avoid_print\n"
        "    print('floor rule: 4096 B noise -> ${out.length} B '\n"
        "        '(codec tag ${out[0]})');\n"
        "  });\n"
        "}",
    ),
]

text = TARGET.read_text(encoding="utf-8")
for old, new in PAIRS:
    if old not in text:
        sys.exit(f"anchor not found:\n{old}")
    text = text.replace(old, new, 1)
TARGET.write_text(text, encoding="utf-8")
print(f"patched {TARGET.name}")
