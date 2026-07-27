/// Decoding the layers of a post back into something to show.
///
/// The renderer never refuses a whole post because one part is missing or
/// unreadable. A picture whose refinements did not arrive is still a
/// picture; a bundle with one corrupt frame still has the frames before
/// it. What it will not do is guess: a payload it cannot decode is
/// reported as such and never rendered as something else.
library;

import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';

import 'payload_envelope.dart';

/// Everything recovered from one post.
class RenderedPost {
  const RenderedPost({
    this.body,
    this.thumbnail,
    this.voiceColumns,
    this.videoFrames = const [],
    this.unreadableParts = 0,
  });

  /// The text layer, decompressed.
  final String? body;

  /// The finest image available from the levels that arrived.
  final DecodedThumbnail? thumbnail;

  /// Voice token columns, for the caller's own decoder to turn into sound.
  final List<List<int>>? voiceColumns;

  /// Video frames in order, as far as they decoded.
  final List<Uint8List> videoFrames;

  /// Parts present but not decodable by this build — a future payload
  /// kind, or damage that survived the hash check because it was in a
  /// layer that was never fetched whole.
  final int unreadableParts;

  bool get isEmpty =>
      body == null &&
      thumbnail == null &&
      voiceColumns == null &&
      videoFrames.isEmpty;
}

/// Decodes composed layers.
class BroadcastMediaRenderer {
  const BroadcastMediaRenderer({
    this.text = const TextDocumentCompressor(),
    this.image = const LowRateImageCompressor(),
    this.video = const FlipbookVideoCompressor(),
  });

  final TextDocumentCompressor text;
  final LowRateImageCompressor image;
  final FlipbookVideoCompressor video;

  /// Rebuild a post from whichever layers the reader managed to fetch.
  ///
  /// [voiceSession] must be the session that mirrors the publisher's, and
  /// is required only when a voice layer is present. Its state advances on
  /// every decoded block, which is why a caller must keep one session per
  /// author rather than making one per post.
  RenderedPost render({
    Uint8List? textLayer,
    Uint8List? stillLayer,
    Uint8List? voiceLayer,
    Uint8List? heavyLayer,
    HamsedaSession? voiceSession,
    int? voiceFrameCount,
  }) {
    var unreadable = 0;
    String? body;
    final imageLevels = <ProgressiveLevel>[];
    List<List<int>>? voiceColumns;
    final frames = <FlipbookFrame>[];

    if (textLayer != null) {
      final envelope = PayloadEnvelope.decode(textLayer);
      if (envelope == null || envelope.kind != PayloadKind.text) {
        unreadable += 1;
      } else {
        try {
          body = text.decompress(envelope.body);
        } on Object {
          unreadable += 1;
        }
      }
    }

    if (stillLayer != null) {
      final envelope = PayloadEnvelope.decode(stillLayer);
      final level = envelope != null && envelope.kind == PayloadKind.imageLevel
          ? _levelFrom(envelope.body)
          : null;
      if (level == null) {
        unreadable += 1;
      } else {
        imageLevels.add(level);
      }
    }

    if (voiceLayer != null) {
      final envelope = PayloadEnvelope.decode(voiceLayer);
      if (envelope == null ||
          envelope.kind != PayloadKind.voiceTokens ||
          voiceSession == null ||
          voiceFrameCount == null) {
        unreadable += 1;
      } else {
        try {
          voiceColumns = voiceSession.decodeBlock(
            envelope.body,
            voiceFrameCount,
          );
          voiceSession.commit();
        } on Object {
          // A block that will not decode must not advance the shared
          // state, or every later block decodes to nonsense.
          voiceSession.rollback();
          unreadable += 1;
        }
      }
    }

    if (heavyLayer != null) {
      final bundle = PayloadBundle.decode(heavyLayer);
      if (bundle == null) {
        unreadable += 1;
      } else {
        for (final part in bundle.parts) {
          switch (part.kind) {
            case PayloadKind.imageLevel:
              final level = _levelFrom(part.body);
              if (level == null) {
                unreadable += 1;
              } else {
                imageLevels.add(level);
              }
            case PayloadKind.videoFrame:
              final frame = _frameFrom(part.body);
              if (frame == null) {
                unreadable += 1;
              } else {
                frames.add(frame);
              }
            case PayloadKind.text:
            case PayloadKind.voiceTokens:
            case PayloadKind.bundle:
              // A kind that does not belong in the heavy bundle. Counted,
              // never guessed at.
              unreadable += 1;
          }
        }
      }
    }

    DecodedThumbnail? thumbnail;
    if (imageLevels.isNotEmpty) {
      try {
        thumbnail = image.decodeProgressive(imageLevels);
      } on Object {
        unreadable += 1;
      }
    }

    var decodedFrames = const <Uint8List>[];
    if (frames.isNotEmpty) {
      try {
        decodedFrames = video.decode(frames);
      } on Object {
        unreadable += 1;
      }
    }

    return RenderedPost(
      body: body,
      thumbnail: thumbnail,
      voiceColumns: voiceColumns,
      videoFrames: decodedFrames,
      unreadableParts: unreadable,
    );
  }

  /// Rebuild a progressive level, refusing a coder this build does not
  /// have rather than picking the nearest one.
  static ProgressiveLevel? _levelFrom(Uint8List body) {
    final payload = ImageLevelPayload.decode(body);
    if (payload == null) return null;
    if (payload.coderIndex >= LevelCoder.values.length) return null;
    return ProgressiveLevel(
      payload.width,
      payload.height,
      payload.bytes,
      LevelCoder.values[payload.coderIndex],
    );
  }

  static FlipbookFrame? _frameFrom(Uint8List body) {
    final payload = VideoFramePayload.decode(body);
    if (payload == null) return null;
    if (payload.predictorIndex >= FlipbookPredictor.values.length) return null;
    return FlipbookFrame(
      payload.index,
      payload.bytes,
      predictor: FlipbookPredictor.values[payload.predictorIndex],
    );
  }
}
