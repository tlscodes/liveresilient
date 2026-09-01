import 'dart:typed_data';

import 'package:hamseda_codec/src/voice_note_codec.dart';
import 'package:test/test.dart';

Uint8List _frame700(int seed) {
  // 28 significant bits in 4 bytes; trailing 4 bits of byte 3 must stay zero.
  final f = Uint8List(4);
  f[0] = seed & 0xFF;
  f[1] = (seed * 7) & 0xFF;
  f[2] = (seed * 13) & 0xFF;
  f[3] = ((seed * 29) & 0xFF) & 0xF0;
  return f;
}

void main() {
  test('250 frames of 700C pack to ceil(250*28/8)+4 bytes', () {
    final frames = List.generate(250, _frame700);
    final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.c700);
    expect(wire.length, voiceNoteHeaderBytes + (250 * 28 + 7) ~/ 8); // 4 + 875
    expect(wire.length, 879);
  });

  test('bit-packed round-trip is exact for every frame', () {
    final frames = List.generate(250, _frame700);
    final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.c700);
    final back = unpackVoiceNote(wire);
    expect(back.length, frames.length);
    for (var i = 0; i < frames.length; i++) {
      expect(back[i], frames[i], reason: 'frame $i');
    }
  });

  test('wrong frame size fails cleanly', () {
    expect(
      () => packVoiceNote(frames: [Uint8List(3)], mode: VoiceNoteMode.c700),
      throwsA(isA<MalformedVoiceNote>()),
    );
  });

  test('truncated wire fails cleanly', () {
    final frames = List.generate(10, _frame700);
    final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.c700);
    expect(
      () => unpackVoiceNote(Uint8List.sublistView(wire, 0, wire.length - 2)),
      throwsA(isA<MalformedVoiceNote>()),
    );
  });
}
