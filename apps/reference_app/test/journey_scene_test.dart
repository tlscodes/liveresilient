/// Pixel checks on the journey scene renderer: the colour bars are where
/// journeySceneBarCenter says and in their colours, the sky is blue at the
/// top, the title is really drawn over it, and the texture control grows
/// the JPEG — the properties the driver and a human reader rely on.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../integration_test/journey_scene.dart';

/// Set JOURNEY_SCENE_OUT to a path to also write the rendered JPEG there,
/// so a person can look at the picture the pixels were checked on.
const String sceneOut = String.fromEnvironment('JOURNEY_SCENE_OUT');

const int _width = 512;
const int _height = 384;

Uint8List _render(int amplitude) => renderJourneyScene(
  width: _width,
  height: _height,
  runId: 'run-x',
  profile: 'narrow',
  at: DateTime.utc(2026, 9, 4, 12, 30, 15),
  textureAmplitude: amplitude,
);

void main() {
  test('each colour bar reads back within ±28 per channel at its center', () {
    final bytes = _render(0);
    if (sceneOut.isNotEmpty) File(sceneOut).writeAsBytesSync(bytes);
    final image = img.decodeJpg(bytes)!;
    expect(image.width, _width);
    expect(image.height, _height);
    for (var i = 0; i < journeySceneBarColors.length; i++) {
      final (x, y) = journeySceneBarCenter(_width, _height, i);
      final pixel = image.getPixel(x, y);
      final want = journeySceneBarColors[i];
      final got = [pixel.r, pixel.g, pixel.b];
      for (var c = 0; c < 3; c++) {
        expect(
          (got[c] - want[c]).abs(),
          lessThanOrEqualTo(28),
          reason: 'bar $i channel $c at ($x,$y): got $got want $want',
        );
      }
    }
  });

  test('the sky is blue at the top-left and JOURNEY is drawn over it', () {
    final image = img.decodeJpg(_render(0))!;
    final corner = image.getPixel(0, 0);
    expect(corner.b, greaterThan(corner.r + 40), reason: 'corner $corner');

    // A 60x40 window inside the JOURNEY glyphs (drawn at 24,16 in arial48).
    var n = 0;
    var sum = 0.0;
    var sumSq = 0.0;
    var bright = 0;
    for (var y = 20; y < 60; y++) {
      for (var x = 30; x < 90; x++) {
        final p = image.getPixel(x, y);
        final luma = (p.r + p.g + p.b) / 3;
        n++;
        sum += luma;
        sumSq += luma * luma;
        // The blue sky cannot produce a near-white pixel; only the text can.
        if (p.r > 180 && p.g > 180 && p.b > 180) bright++;
      }
    }
    final variance = sumSq / n - (sum / n) * (sum / n);
    expect(variance, greaterThan(0));
    expect(bright, greaterThanOrEqualTo(30), reason: 'white text pixels');
  });

  test('the JPEG grows strictly with the texture amplitude 0 → 24', () {
    var last = -1;
    for (final amplitude in const [0, 6, 12, 18, 24]) {
      final size = _render(amplitude).length;
      expect(size, greaterThan(last), reason: 'amplitude $amplitude');
      last = size;
    }
  });
}
