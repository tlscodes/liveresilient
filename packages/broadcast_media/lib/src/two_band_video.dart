/// The two-band video letter (2026-09-23, Fable 5.1's design, built by
/// hand): the photo's payload in the voice's shape. When the camera holds
/// still on something — a page, a sign, a label — the letter carries ONE
/// sharp page-resolution AV1 keyframe for the length of the hold (the
/// "page band", 648x1152, like the AVIF photo the owner called excellent);
/// the rest of the clip stays today's 216x384 motion stream (the "moving
/// band"). Both bands are AV1 in the same 'V1' wire, in time order: every
/// run starts with its own sequence header + keyframe, which dav1d decodes
/// across the size change. The audio tail drops to 8 kbit/s wideband
/// (NoLACE on the receiver earns it back) and gives the picture ~17 KB.
///
/// Why: at 216x384 a hand-held magazine page puts body text two pixels
/// tall — no crf can read it (row 51263382: the headline read, the body
/// did not). Only pixels make print readable, and only a still can afford
/// them inside sixty letters.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'av1_encoder.dart';
import 'video_note_codec.dart';

/// The page band's geometry: 3x the moving band (multiples of 8).
const int pageBandWidth = 648;
const int pageBandHeight = 1152;

/// The page keyframe is not bisected: text edges ring past ~32.
const int pageBandCrf = 30;

/// A hold: mean |dY| between consecutive 216x384 frames under this…
const double holdMeanDiff = 1.5;

/// …for at least this many output frames (1 s at 4 fps).
const int holdMinFrames = 4;

/// At most this many holds become pages (each costs ~44 KB of motion).
const int holdMaxPages = 3;

/// The audio tail's rate in a two-band letter (NoLACE on the receiver).
const int twoBandAudioBitrate = 8000;

/// A still stretch of the clip, in output-frame indices [start, end).
class Hold {
  const Hold(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start;
  @override
  String toString() => 'Hold($start..$end)';
}

/// Mean absolute luma difference between two frames' Y planes.
double meanAbsLumaDiff(Uint8List a, Uint8List b) {
  var s = 0;
  for (var i = 0; i < a.length; i += 2) {
    s += (a[i] - b[i]).abs();
  }
  return s / (a.length / 2);
}

/// The still stretches of a packed I420 clip, longest first then in time
/// order, at most [holdMaxPages].
List<Hold> findHolds(
  Uint8List i420, {
  required int width,
  required int height,
  double threshold = holdMeanDiff,
  int minFrames = holdMinFrames,
  int maxHolds = holdMaxPages,
}) {
  final fb = width * height * 3 ~/ 2;
  final luma = width * height;
  final n = i420.length ~/ fb;
  Uint8List y(int i) => Uint8List.sublistView(i420, i * fb, i * fb + luma);
  final holds = <Hold>[];
  var runStart = -1;
  for (var i = 1; i <= n; i++) {
    final still = i < n && meanAbsLumaDiff(y(i), y(i - 1)) < threshold;
    if (still && runStart < 0) runStart = i - 1;
    if (!still && runStart >= 0) {
      if (i - runStart >= minFrames) holds.add(Hold(runStart, i));
      runStart = -1;
    }
  }
  holds.sort((a, b) => b.length.compareTo(a.length));
  final kept = holds.take(maxHolds).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return kept;
}

/// 3x3 Laplacian variance of a luma plane: the sharpness score the page
/// keyframe is chosen by (the first frame of a hold is still settling).
double laplacianVariance(Uint8List lum, int width, int height) {
  var sum = 0.0, sum2 = 0.0, n = 0;
  for (var r = 1; r < height - 1; r += 2) {
    for (var c = 1; c < width - 1; c += 2) {
      final i = r * width + c;
      final l =
          4 * lum[i] -
          lum[i - 1] -
          lum[i + 1] -
          lum[i - width] -
          lum[i + width];
      sum += l;
      sum2 += l * l;
      n++;
    }
  }
  final mean = sum / n;
  return sum2 / n - mean * mean;
}

/// A page held for [frames] output frames: the same I420 frame repeated,
/// so the encoder spends one keyframe and then ~100 B skip frames — the
/// page sits still instead of shimmering, and the timeline stays at fps.
Uint8List _held(Uint8List page, int frames) {
  final out = Uint8List(page.length * frames);
  for (var k = 0; k < frames; k++) {
    out.setRange(k * page.length, (k + 1) * page.length, page);
  }
  return out;
}

/// What a two-band build measured, beside the wire.
class TwoBandBuild {
  const TwoBandBuild({
    required this.wire,
    required this.movingCrf,
    required this.pages,
    required this.pageBytes,
    required this.frames,
    required this.passes,
  });
  final Uint8List wire;
  final int movingCrf;
  final int pages;
  final int pageBytes;
  final int frames;
  final int passes;
}

/// Builds the two-band letter. [clip] is the packed 216x384 I420 motion
/// clip at [fps]; [pages] maps each [Hold] to its sharpest page-resolution
/// I420 frame (648x1152). Pages are encoded once at [pageBandCrf]; if they
/// would leave the motion band under a third of the budget, the shortest
/// holds are dropped. The moving band's crf is then bisected, as today.
TwoBandBuild buildTwoBandLetter({
  required Uint8List clip,
  required Uint8List pcm16k,
  required int fps,
  required int budget,
  required Map<Hold, Uint8List> pages,
  int preset = videoLetterPreset,
  int crfLow = 16,
  int crfHigh = 40,
}) {
  final fb = videoLetterWidth * videoLetterHeight * 3 ~/ 2;
  final n = clip.length ~/ fb;
  // 8 kbit/s only when a page needs the room; a clip with no hold keeps
  // the 12 kbit/s tail the owner accepted.
  final audio = encodeVbrTail(
    pcm16k,
    pages.isEmpty ? videoLetterAudioBitrate : twoBandAudioBitrate,
  );
  // Encode each page run once; drop pages that crowd out the motion.
  var holds = pages.keys.toList()..sort((a, b) => a.start.compareTo(b.start));
  final pageUnits = <Hold, List<Uint8List>>{};
  for (final h in holds) {
    pageUnits[h] = encodeAv1I420(
      _held(pages[h]!, h.length),
      width: pageBandWidth,
      height: pageBandHeight,
      fps: fps,
      crf: pageBandCrf,
      preset: preset,
    );
  }
  int bytesOf(List<Uint8List> u) => u.fold(0, (a, b) => a + 3 + b.length);
  while (holds.isNotEmpty &&
      holds.fold<int>(0, (a, h) => a + bytesOf(pageUnits[h]!)) >
          (budget - audio.length) * 2 ~/ 3) {
    holds.sort((a, b) => a.length.compareTo(b.length));
    holds.removeAt(0);
    holds.sort((a, b) => a.start.compareTo(b.start));
  }
  final pageBytes = holds.fold<int>(0, (a, h) => a + bytesOf(pageUnits[h]!));
  // The moving runs between the holds.
  final moving = <(int, int)>[];
  var at = 0;
  for (final h in holds) {
    if (h.start > at) moving.add((at, h.start));
    at = h.end;
  }
  if (at < n) moving.add((at, n));

  List<Uint8List> assemble(int crf) {
    final movingUnits = <int, List<Uint8List>>{};
    for (final (s, e) in moving) {
      movingUnits[s] = encodeAv1I420(
        Uint8List.sublistView(clip, s * fb, e * fb),
        width: videoLetterWidth,
        height: videoLetterHeight,
        fps: fps,
        crf: crf,
        preset: preset,
      );
    }
    final out = <Uint8List>[];
    var t = 0;
    while (t < n) {
      final hold = holds.where((h) => h.start == t).firstOrNull;
      if (hold != null) {
        out.addAll(pageUnits[hold]!);
        t = hold.end;
      } else {
        final (s, e) = moving.firstWhere((m) => m.$1 == t);
        out.addAll(movingUnits[s]!);
        t = e;
      }
    }
    return out;
  }

  Uint8List? fit;
  var fitCrf = -1, frames = 0, passes = 0, smallest = 1 << 30;
  var lo = crfLow, hi = crfHigh;
  var crf = math.min(math.max(24, crfLow), crfHigh);
  while (lo <= hi) {
    passes++;
    final units = assemble(crf);
    final wire = VideoNote(
      fps: fps,
      width: videoLetterWidth,
      height: videoLetterHeight,
      videoFrames: units,
      audioBits: audio,
    ).encode();
    wire[11] = videoLetterAudioModeOpusVbr;
    if (wire.length < smallest) smallest = wire.length;
    if (wire.length <= budget) {
      fit = wire;
      fitCrf = crf;
      frames = units.length;
      hi = crf - 1;
    } else {
      lo = crf + 1;
    }
    if (lo > hi) break;
    final movingBytes =
        wire.length - videoNoteHeaderBytes - audio.length - pageBytes;
    final room = budget - videoNoteHeaderBytes - audio.length - pageBytes;
    final guess = movingBytes <= 0 || room <= 0
        ? (lo + hi) ~/ 2
        : crf - (6 * (math.log(room / movingBytes) / math.ln2)).round();
    crf = guess.clamp(lo, hi);
  }
  if (fit == null) throw VideoLetterTooLong(smallest, budget);
  return TwoBandBuild(
    wire: fit,
    movingCrf: fitCrf,
    pages: holds.length,
    pageBytes: pageBytes,
    frames: frames,
    passes: passes,
  );
}
