import 'dart:typed_data';

import 'package:broadcast_media/src/video_note_codec.dart';
import 'package:test/test.dart';

void main() {
  Uint8List frame(int n, int fill) =>
      Uint8List.fromList(List.filled(n, fill));

  VideoNote note() => VideoNote(
        fps: 3,
        width: 96,
        height: 64,
        videoFrames: [frame(2000, 1), frame(300, 2), frame(1, 3)],
        audioBits: frame(438, 9),
      );

  test('header is exactly 12 bytes with the documented layout', () {
    final wire = note().encode();
    expect(wire[0], 0x56);
    expect(wire[1], 0x31);
    expect(wire[2], 3);
    expect(wire[3] | (wire[4] << 8), 96);
    expect(wire[5] | (wire[6] << 8), 64);
    final audioOffset =
        wire[7] | (wire[8] << 8) | (wire[9] << 16) | (wire[10] << 24);
    expect(audioOffset, videoNoteHeaderBytes + (3 + 2000) + (3 + 300) + (3 + 1));
    expect(wire.length, audioOffset + 438);
  });

  test('encode -> decode round-trips frames and audio exactly', () {
    final n = note();
    final back = VideoNote.decode(n.encode());
    expect(back.fps, 3);
    expect(back.width, 96);
    expect(back.height, 64);
    expect(back.videoFrames.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(back.videoFrames[i], n.videoFrames[i], reason: 'frame $i');
    }
    expect(back.audioBits, n.audioBits);
  });

  test('container-like input is rejected by magic, not parsed', () {
    final mp4ish = Uint8List.fromList(
        [0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, ...List.filled(24, 0)]);
    expect(() => VideoNote.decode(mp4ish),
        throwsA(isA<MalformedVideoNote>()));
  });

  test('corrupt audioOffset and overrunning frame fail cleanly', () {
    final wire = note().encode();
    final badOffset = Uint8List.fromList(wire)..[7] = 0xFF..[8] = 0xFF;
    expect(() => VideoNote.decode(badOffset),
        throwsA(isA<MalformedVideoNote>()));
    final badLen = Uint8List.fromList(wire)..[videoNoteHeaderBytes + 1] = 0xFF;
    expect(() => VideoNote.decode(badLen),
        throwsA(isA<MalformedVideoNote>()));
  });
}
