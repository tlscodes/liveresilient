/// The picture the app journey sends as its photo: a rendered scene, not
/// noise, so a person looking at the phone's copy can tell it is the right
/// picture — a sky gradient, a sun, two hill bands, a colour-bar strip along
/// the bottom, and the run's own id, profile and time written into the sky.
///
/// Plain Dart over package:image (no Flutter), so the driver in
/// integration_test/ and the pixel test in test/ share one renderer.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The eight bars of the bottom strip, left to right, as RGB.
const List<List<int>> journeySceneBarColors = [
  [235, 235, 235],
  [235, 235, 0],
  [0, 235, 235],
  [0, 235, 0],
  [235, 0, 235],
  [235, 0, 0],
  [0, 0, 235],
  [20, 20, 20],
];

/// The bar strip is the bottom 12 % of the canvas.
const double journeySceneBarStripFraction = 0.12;

/// The first row of the bar strip, in pixels from the top.
int journeySceneBarStripTop(int height) =>
    height - (height * journeySceneBarStripFraction).round();

/// The pixel at the middle of bar [index] on a [width] x [height] scene —
/// where a reader (the unit test, or a person with the phone's copy) can
/// sample the bar's colour away from any edge.
(int x, int y) journeySceneBarCenter(int width, int height, int index) {
  final top = journeySceneBarStripTop(height);
  final x = ((index + 0.5) * width / journeySceneBarColors.length).floor();
  final y = top + (height - top) ~/ 2;
  return (x, y);
}

/// Renders the scene as a JPEG at quality 90.
///
/// [textureAmplitude] adds a deterministic per-channel texture of up to
/// ±amplitude (an LCG seeded from the size and the amplitude) over the sky
/// and the hills — never over the bars, the sun or the text — which is how
/// the driver grows the file toward its target size without changing what
/// the picture shows.
Uint8List renderJourneyScene({
  required int width,
  required int height,
  required String runId,
  required String profile,
  required DateTime at,
  int textureAmplitude = 0,
}) {
  final image = img.Image(width: width, height: height);
  final stripTop = journeySceneBarStripTop(height);
  final horizon = (height * 0.60).round();
  final farBase = (height * 0.66).round();
  final farAmp = height * 0.10;
  final nearAmp = height * 0.08;

  const skyTopR = 40, skyTopG = 90, skyTopB = 190;
  const skyHorizonR = 230, skyHorizonG = 200, skyHorizonB = 150;
  const farHillR = 30, farHillG = 95, farHillB = 45;
  const nearHillR = 70, nearHillG = 160, nearHillB = 60;

  var seed = 0x5EED ^ (width * 31 + height) ^ (textureAmplitude * 7919);
  final span = 2 * textureAmplitude + 1;
  int textured(int value) {
    if (textureAmplitude == 0) return value;
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    final delta = ((seed >> 16) % span) - textureAmplitude;
    return (value + delta).clamp(0, 255);
  }

  // Sky above the ridges, two hill bands below them, per column so the
  // ridges can follow a wave.
  for (var x = 0; x < width; x++) {
    final phase = x / width * 2 * math.pi;
    final farRidge =
        horizon - farAmp * (0.5 + 0.5 * math.sin(1.3 * phase + 0.7));
    final nearRidge =
        farBase - nearAmp * (0.5 + 0.5 * math.sin(0.9 * phase + 2.5));
    for (var y = 0; y < stripTop; y++) {
      int r, g, b;
      if (y >= nearRidge) {
        r = nearHillR;
        g = nearHillG;
        b = nearHillB;
      } else if (y >= farRidge) {
        r = farHillR;
        g = farHillG;
        b = farHillB;
      } else {
        // The ridges never rise above the horizon's own line, so t < 1.
        final t = y / horizon;
        r = (skyTopR + (skyHorizonR - skyTopR) * t).round();
        g = (skyTopG + (skyHorizonG - skyTopG) * t).round();
        b = (skyTopB + (skyHorizonB - skyTopB) * t).round();
      }
      image.setPixelRgb(x, y, textured(r), textured(g), textured(b));
    }
  }

  img.fillCircle(
    image,
    x: (width * 0.78).round(),
    y: (height * 0.20).round(),
    radius: (height * 0.07).round(),
    color: img.ColorRgb8(255, 225, 90),
  );

  for (var i = 0; i < journeySceneBarColors.length; i++) {
    final bar = journeySceneBarColors[i];
    img.fillRect(
      image,
      x1: (i * width / journeySceneBarColors.length).floor(),
      y1: stripTop,
      x2: ((i + 1) * width / journeySceneBarColors.length).floor() - 1,
      y2: height - 1,
      color: img.ColorRgb8(bar[0], bar[1], bar[2]),
    );
  }

  // Text with a dark offset copy underneath so it stays legible where the
  // gradient turns pale.
  final shadow = img.ColorRgb8(20, 30, 60);
  final white = img.ColorRgb8(250, 250, 250);
  void label(String text, img.BitmapFont font, int x, int y) {
    img.drawString(image, text, font: font, x: x + 2, y: y + 2, color: shadow);
    img.drawString(image, text, font: font, x: x, y: y, color: white);
  }

  label('JOURNEY', img.arial48, 24, 16);
  label('run $runId', img.arial24, 24, 76);
  label('profile $profile', img.arial24, 24, 108);
  label(_stamp(at), img.arial24, 24, 140);

  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

/// `2026-09-04 12:30:15Z` — the moment in UTC, to the second.
String _stamp(DateTime at) {
  final u = at.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} '
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}
