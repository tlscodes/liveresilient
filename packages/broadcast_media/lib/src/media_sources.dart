/// Plain value types for the media a post is composed from.
///
/// Deliberately raw: interleaved pixels and grayscale frames, not files.
/// Decoding a JPEG is the host app's job, and keeping it there means this
/// package has no opinion about image libraries and no platform channel.
library;

import 'dart:typed_data';

/// An image as interleaved 8-bit samples.
class RasterImage {
  RasterImage({
    required this.pixels,
    required this.width,
    required this.height,
    required this.channels,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value(
        '$width x $height',
        'size',
        'both dimensions must be positive',
      );
    }
    if (channels < 1 || channels > 4) {
      throw ArgumentError.value(channels, 'channels', 'must be 1..4');
    }
    final expected = width * height * channels;
    if (pixels.length != expected) {
      throw ArgumentError.value(
        pixels.length,
        'pixels.length',
        'expected $expected for $width x $height x $channels',
      );
    }
  }

  final Uint8List pixels;
  final int width;
  final int height;
  final int channels;

  int get rawBytes => pixels.length;
}

/// A short clip as grayscale frames already sampled at the wire rate.
///
/// Sampling is the caller's decision because it is a content decision: how
/// many seconds matter, and how much motion is worth keeping, is not
/// something a codec should guess.
class VideoClip {
  VideoClip({required this.frames, required this.width, required this.height}) {
    if (frames.isEmpty) {
      throw ArgumentError.value(frames, 'frames', 'a clip needs a frame');
    }
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value(
        '$width x $height',
        'size',
        'both dimensions must be positive',
      );
    }
    final expected = width * height;
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].length != expected) {
        throw ArgumentError.value(
          frames[i].length,
          'frames[$i].length',
          'expected $expected grayscale samples',
        );
      }
    }
  }

  /// One 8-bit grayscale sample per pixel, row major.
  final List<Uint8List> frames;

  final int width;
  final int height;

  int get frameCount => frames.length;
}

/// A block of neural-codec token columns.
///
/// This package does not turn speech into tokens — no such model lives in
/// this repository, and pretending otherwise would be the worst kind of
/// scaffold. The caller supplies columns from whatever engine it has, and
/// what happens here is the entropy coding that makes them small.
class VoiceTokenBlock {
  VoiceTokenBlock({required this.columns, required this.rows}) {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'nothing to encode');
    }
    if (rows <= 0) {
      throw ArgumentError.value(rows, 'rows', 'must be positive');
    }
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].length != rows) {
        throw ArgumentError.value(
          columns[i].length,
          'columns[$i].length',
          'expected $rows rows',
        );
      }
    }
  }

  /// One inner list per frame, each holding [rows] codebook ids.
  final List<List<int>> columns;

  /// Codebook rows per column, fixed by the model that produced them.
  final int rows;

  int get frameCount => columns.length;
}
