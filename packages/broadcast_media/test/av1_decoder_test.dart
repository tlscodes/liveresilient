/// Host-side proof of the dav1d decode path against the REAL phase-5 wire
/// artifacts (measured-on-host; the device loads the same dav1d revision
/// from the vendored framework — bindings are generated from that clone's
/// headers).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/av1_decoder.dart';
import 'package:broadcast_media/src/video_note_codec.dart';
import 'package:test/test.dart';

Uint8List _artifact(String name) {
  final f = File('../../tools/phase5/artifacts/$name');
  expect(f.existsSync(), isTrue, reason: 'phase-5 artifact missing: $name');
  return f.readAsBytesSync();
}

void main() {
  test('video_note_15k.bin: all 15 frames decode at 128x96', () {
    final note = VideoNote.decode(_artifact('video_note_15k.bin'));
    final frames = decodeAv1Frames(note.videoFrames);
    expect(frames.length, note.videoFrames.length);
    expect(frames.length, 15,
        reason: 'the phase-5 wire carries 15 frames (gate_4 log)');
    for (final f in frames) {
      expect(f.width, 128);
      expect(f.height, 96);
      expect(f.rgba.length, 128 * 96 * 4);
    }
    // real content, not a black screen: some luma variance must exist
    final first = frames.first.rgba;
    final distinct = <int>{for (var i = 0; i < first.length; i += 4) first[i]};
    expect(distinct.length, greaterThan(8),
        reason: 'decoded pixels must vary — a constant frame means a broken '
            'stride/convert path');
  });

  test('photo_ref_3k.avif: mdat payload decodes to the 120x160 photo', () {
    final tu = avifMdatPayload(_artifact('photo_ref_3k.avif'));
    final frames = decodeAv1Frames([tu]);
    expect(frames.length, 1);
    expect(frames.single.width, 120);
    expect(frames.single.height, 160);
  });

  test('garbage input fails loud, not quiet', () {
    expect(() => decodeAv1Frames([Uint8List.fromList(List.filled(64, 0xAB))]),
        throwsA(isA<MalformedAv1Stream>()));
    expect(() => avifMdatPayload(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<MalformedAv1Stream>()));
  });
}
