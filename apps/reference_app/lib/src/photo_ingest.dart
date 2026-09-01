import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:messaging/messaging.dart';

/// Encodes the three staged artifacts from raw picked bytes — the app's
/// half of RIG_GUIDE §0.2 item 1b (the messaging package owns delivery,
/// this file owns codecs):
///
///   original: re-encoded JPEG capped at 2048 px long side, quality 80
///             (the wire original; the camera original stays on-device,
///             fetch-on-demand is a later item);
///   preview:  ~15 KB JPEG, long side 320 px, quality stepped down and
///             size halved until it fits;
///   thumbhash: the ~30-byte placeholder from a 64 px RGBA downsample.
///
/// Pure function over bytes — no plugin, no platform channel — so it runs
/// under `compute()` and in plain unit tests.
StagedPhotoArtifacts buildStagedPhotoArtifacts(Uint8List raw) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) {
    throw const FormatException('unsupported or corrupt image bytes');
  }

  const originalCapPx = 2048;
  const originalQuality = 80;
  const previewLongPx = 320;
  const previewCapBytes = 15 * 1024;
  const thumbLongPx = 64;

  final full = _capLongSide(decoded, originalCapPx);
  final original = Uint8List.fromList(
    img.encodeJpg(full, quality: originalQuality),
  );

  // Preview: start at 320px q70 and tighten until it fits ~15 KB. The loop
  // is bounded; every step either drops quality or halves the long side,
  // so it terminates on any input.
  var side = previewLongPx;
  var quality = 70;
  var previewImage = _capLongSide(full, side);
  var preview = Uint8List.fromList(
    img.encodeJpg(previewImage, quality: quality),
  );
  for (var step = 0; preview.length > previewCapBytes && step < 6; step++) {
    if (quality > 40) {
      quality -= 15;
    } else {
      side = (side / 2).round().clamp(32, previewLongPx);
      previewImage = _capLongSide(full, side);
    }
    preview = Uint8List.fromList(img.encodeJpg(previewImage, quality: quality));
  }

  final tiny = _capLongSide(full, thumbLongPx).convert(numChannels: 4);
  final rgba = tiny.getBytes(order: img.ChannelOrder.rgba);

  return StagedPhotoArtifacts(
    thumbHash: ThumbHash.encodeRgba(tiny.width, tiny.height, rgba),
    preview: preview,
    original: original,
    width: full.width,
    height: full.height,
  );
}

img.Image _capLongSide(img.Image im, int cap) {
  final long = im.width > im.height ? im.width : im.height;
  if (long <= cap) return im;
  return im.width >= im.height
      ? img.copyResize(im, width: cap, interpolation: img.Interpolation.linear)
      : img.copyResize(
          im,
          height: cap,
          interpolation: img.Interpolation.linear,
        );
}
