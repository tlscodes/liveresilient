/// The two-band video letter on the host (Homebrew libSvtAv1Enc 4.2.0 +
/// dav1d): a clip that moves, holds still for two seconds, then moves again
/// finds exactly that hold; the letter carries the hold as a 648x1152 page
/// and the rest at 216x384 in ONE stream that dav1d decodes across both
/// size changes, frame for frame, inside the budget.
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/av1_decoder.dart';
import 'package:broadcast_media/src/av1_encoder.dart';
import 'package:broadcast_media/src/two_band_video.dart';
import 'package:broadcast_media/src/video_note_codec.dart';
import 'package:test/test.dart';

/// One I420 frame of [w]x[h]: a gradient shifted by [shift], with a block
/// of fine "text" stripes (1 px period) in the middle.
Uint8List frame(int w, int h, int shift) {
  final out = Uint8List(w * h * 3 ~/ 2);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = ((x + y + shift) * 200 ~/ (w + h)) + 20;
      if (y > h ~/ 3 && y < h * 2 ~/ 3 && x > w ~/ 6 && x < w * 5 ~/ 6) {
        v = (y % 3 == 0) ? 30 : 230;
      }
      out[y * w + x] = v;
    }
  }
  out.fillRange(w * h, out.length, 128);
  return out;
}

void main() {
  final hasLib =
      File('/usr/local/lib/libSvtAv1Enc.4.dylib').existsSync() ||
      File('/opt/homebrew/lib/libSvtAv1Enc.4.dylib').existsSync();
  const w = videoLetterWidth, h = videoLetterHeight;

  test('a still stretch is found, and only that one', () {
    final clip = BytesBuilder()
      ..add([for (var i = 0; i < 8; i++) ...frame(w, h, i * 12)])
      ..add([for (var i = 0; i < 12; i++) ...frame(w, h, 96)])
      ..add([for (var i = 0; i < 8; i++) ...frame(w, h, 200 + i * 12)]);
    final holds = findHolds(clip.takeBytes(), width: w, height: h);
    expect(holds, hasLength(1));
    expect(holds.first.start, inInclusiveRange(7, 8));
    expect(holds.first.end, 20);
  });

  test('the sharper of two frames scores higher', () {
    final sharp = frame(pageBandWidth, pageBandHeight, 0);
    final soft = Uint8List.fromList(sharp);
    for (var i = 1; i < pageBandWidth * pageBandHeight - 1; i++) {
      soft[i] = (sharp[i - 1] + sharp[i] + sharp[i + 1]) ~/ 3;
    }
    expect(
      laplacianVariance(sharp, pageBandWidth, pageBandHeight),
      greaterThan(laplacianVariance(soft, pageBandWidth, pageBandHeight)),
    );
  });

  test(
    'one stream carries both bands and dav1d decodes across the switch',
    () {
      final clip = BytesBuilder()
        ..add([for (var i = 0; i < 6; i++) ...frame(w, h, i * 12)])
        ..add([for (var i = 0; i < 6; i++) ...frame(w, h, 72)])
        ..add([for (var i = 0; i < 6; i++) ...frame(w, h, 140 + i * 12)]);
      final all = clip.takeBytes();
      final holds = findHolds(all, width: w, height: h);
      expect(holds, hasLength(1));
      final page = frame(pageBandWidth, pageBandHeight, 72);
      final b = buildTwoBandLetter(
        clip: all,
        pcm16k: Uint8List(3 * 16000 * 2),
        fps: 6,
        budget: 60000,
        pages: {holds.first: page},
      );
      expect(b.wire.length, lessThanOrEqualTo(60000));
      expect(b.pages, 1);
      final note = VideoNote.decode(b.wire);
      final decoded = decodeAv1Frames(note.videoFrames);
      expect(decoded, hasLength(18));
      final sizes = decoded.map((f) => '${f.width}x${f.height}').toSet();
      expect(
        sizes,
        containsAll([
          '${videoLetterWidth}x$videoLetterHeight',
          '${pageBandWidth}x$pageBandHeight',
        ]),
      );
      final big = decoded.where((f) => f.width == pageBandWidth).length;
      expect(big, holds.first.length);
    },
    skip: hasLib ? false : 'no host libSvtAv1Enc',
  );
}
