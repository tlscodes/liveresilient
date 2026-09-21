/// Host-side proof of the SVT-AV1 encode path (the phone-authored video
/// letter) against the Homebrew libSvtAv1Enc 4.2.0 — the same version the
/// vendored ios framework was built from: 12 synthetic 144x256 frames go
/// through encodeAv1I420 and come back through dav1d as 12 frames with the
/// gradient intact; buildVideoLetter's bisect lands under the budget with
/// the flags nibble stamped Opus and an audio tail of 45 B packets.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:broadcast_media/src/av1_decoder.dart';
import 'package:broadcast_media/src/av1_encoder.dart';
import 'package:broadcast_media/src/video_note_codec.dart';
import 'package:test/test.dart';

/// [n] I420 frames of a moving diagonal gradient with a bright square.
Uint8List frames(int n, int w, int h) {
  final fb = w * h * 3 ~/ 2;
  final out = Uint8List(n * fb);
  for (var f = 0; f < n; f++) {
    final base = f * fb;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = ((x + y + f * 6) * 255 ~/ (w + h)) & 0xFF;
        if ((x - 40 - f * 4).abs() < 16 && (y - 100).abs() < 16) v = 235;
        out[base + y * w + x] = v;
      }
    }
    out.fillRange(base + w * h, base + w * h + w * h ~/ 4, 128 - f * 3);
    out.fillRange(base + w * h + w * h ~/ 4, base + fb, 128 + f * 3);
  }
  return out;
}

void main() {
  final hasLib =
      File('/usr/local/lib/libSvtAv1Enc.4.dylib').existsSync() ||
      File('/opt/homebrew/lib/libSvtAv1Enc.4.dylib').existsSync() ||
      (Platform.environment['SVTAV1_LIB_PATH'] ?? '').isNotEmpty;

  test(
    'libSvtAv1Enc is the 4.2.0 the framework was built from',
    () {
      expect(svtAv1Version(), contains('4.2.0'));
    },
    skip: hasLib ? false : 'no host libSvtAv1Enc',
  );

  test(
    '12 frames encode with the letter knobs and decode back through dav1d',
    () {
      const w = videoLetterWidth, h = videoLetterHeight;
      final units = encodeAv1I420(
        frames(12, w, h),
        width: w,
        height: h,
        fps: 6,
        crf: 40,
      );
      expect(units.length, inInclusiveRange(1, 12));
      final decoded = decodeAv1Frames(units);
      expect(decoded, hasLength(12));
      expect(decoded.first.width, w);
      expect(decoded.first.height, h);
      // The bright square is where it was put, the dark corner stays dark.
      final mid = decoded[6].rgba;
      int lum(int x, int y) => mid[(y * w + x) * 4];
      expect(lum(40 + 6 * 4, 100), greaterThan(180));
      expect(lum(2, 2), lessThan(90));
    },
    skip: hasLib ? false : 'no host libSvtAv1Enc',
  );

  test(
    'the letter builder bisects crf under the budget and stamps Opus',
    () {
      const w = videoLetterWidth, h = videoLetterHeight;
      final pcm = Uint8List(2 * 16000 * 2); // 2 s of 16 kHz near-silence
      final r = Random(1);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = r.nextInt(8);
      }
      final build = buildVideoLetter(
        i420: frames(12, w, h),
        pcm16k: pcm,
        width: w,
        height: h,
        fps: 6,
        budget: 6000,
        crfLow: 30,
        crfHigh: 63,
      );
      expect(build.wire.length, lessThanOrEqualTo(6000));
      expect(build.wire[0], 0x56);
      expect(build.wire[1], 0x31);
      expect(build.wire[11] & 0x0F, videoLetterAudioModeOpusVbr);
      expect(build.audioPackets, 33); // 2 s / 60 ms
      final note = VideoNote.decode(build.wire);
      expect(countVbrPackets(note.audioBits), 33);
      // Near-silence at 10 kbit/s VBR: far under the 75 B a full packet
      // would take, and every packet behind its own length byte.
      expect(note.audioBits.length, lessThan(33 * 76));
      var p = 0;
      while (p < note.audioBits.length) {
        expect(note.audioBits[p], inInclusiveRange(1, 255));
        p += 1 + note.audioBits[p];
      }
      expect(p, note.audioBits.length);
      expect(note.fps, 6);
      expect(note.width, w);
      expect(note.height, h);
      expect(decodeAv1Frames(note.videoFrames), hasLength(12));
      expect(build.passes, inInclusiveRange(1, 4), reason: 'seeded bisect');
    },
    skip: hasLib ? false : 'no host libSvtAv1Enc',
  );
}
