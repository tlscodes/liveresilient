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
import 'spoken_text_plan.dart';

/// Everything recovered from one post.
class RenderedPost {
  const RenderedPost({
    this.body,
    this.thumbnail,
    this.voiceColumns,
    this.spokenText,
    this.voiceProvenance,
    this.videoFrames = const [],
    this.unreadableParts = 0,
  });

  /// The text layer, decompressed.
  final String? body;

  /// The finest image available from the levels that arrived.
  final DecodedThumbnail? thumbnail;

  /// Voice token columns, for the caller's own decoder to turn into sound.
  final List<List<int>>? voiceColumns;

  /// A reading to perform locally, when the post asked for one.
  ///
  /// Present only alongside a text layer that verified, because there is
  /// nothing else this may ever be built from.
  final SpokenTextRequest? spokenText;

  /// Where this post's audio comes from, when it has any.
  ///
  /// Never null when there is audio, and both values mean the same thing
  /// to a user interface: what the listener hears is not a recording of
  /// the author. Say so.
  final VoiceProvenance? voiceProvenance;

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
      spokenText == null &&
      videoFrames.isEmpty;

  /// Whether this post has audio a reader could play.
  bool get hasAudio => voiceColumns != null || spokenText != null;
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
  }) {
    var unreadable = 0;
    String? body;
    final imageLevels = <int, ProgressiveLevel>{};
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
      final payload =
          envelope != null && envelope.kind == PayloadKind.imageLevel
          ? ImageLevelPayload.decode(envelope.body)
          : null;
      final level = payload == null ? null : _levelFrom(payload);
      if (level == null) {
        unreadable += 1;
      } else {
        imageLevels[payload!.ordinal] = level;
      }
    }

    SpokenTextRequest? spokenText;
    VoiceProvenance? provenance;

    if (voiceLayer != null) {
      final envelope = PayloadEnvelope.decode(voiceLayer);
      switch (envelope?.kind) {
        case PayloadKind.spokenText:
          final plan = SpokenTextPlan.decode(envelope!.body);
          if (plan == null || body == null) {
            // A reading with no verified text behind it is refused. The
            // engine must never be handed anything that did not survive
            // the signature and hash checks.
            unreadable += 1;
          } else {
            spokenText = SpokenTextRequest(
              text: body,
              language: plan.language,
              wordsPerMinute: plan.wordsPerMinute,
            );
            provenance = VoiceProvenance.synthesizedFromText;
          }
        case PayloadKind.voiceTokens:
          final payload = VoiceTokensPayload.decode(envelope!.body);
          if (voiceSession == null || payload == null) {
            unreadable += 1;
          } else {
            try {
              voiceColumns = voiceSession.decodeBlock(
                payload.bytes,
                payload.frameCount,
              );
              voiceSession.commit();
              provenance = VoiceProvenance.reconstructedFromTokens;
            } on Object {
              // A block that will not decode must not advance the shared
              // state, or every later block decodes to nonsense.
              voiceSession.rollback();
              unreadable += 1;
            }
          }
        case null:
        case PayloadKind.text:
        case PayloadKind.imageLevel:
        case PayloadKind.videoFrame:
        case PayloadKind.bundle:
          unreadable += 1;
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
              final payload = ImageLevelPayload.decode(part.body);
              final level = payload == null ? null : _levelFrom(payload);
              if (level == null || imageLevels.containsKey(payload!.ordinal)) {
                // A duplicate ordinal is refused rather than allowed to
                // silently replace the level already held.
                unreadable += 1;
              } else {
                imageLevels[payload.ordinal] = level;
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
            case PayloadKind.spokenText:
            case PayloadKind.bundle:
              // A kind that does not belong in the heavy bundle. Counted,
              // never guessed at.
              unreadable += 1;
          }
        }
      }
    }

    // Only the run starting at the base level is usable. A refinement is a
    // residual against the level below it, so levels 1 and 2 without
    // level 0 are not a lower-quality picture — they are noise that would
    // decode without complaint and be shown as the photograph.
    final ordered = <ProgressiveLevel>[];
    for (var ordinal = 0; imageLevels.containsKey(ordinal); ordinal++) {
      ordered.add(imageLevels[ordinal]!);
    }
    unreadable += imageLevels.length - ordered.length;

    // Decoded one prefix at a time, keeping the best that worked. The
    // whole promise of a progressive format is that a partial arrival is
    // still a picture, and decoding the full list in one attempt threw
    // that away the moment any refinement was damaged.
    DecodedThumbnail? thumbnail;
    for (var count = 1; count <= ordered.length; count++) {
      try {
        thumbnail = image.decodeProgressive(ordered.sublist(0, count));
      } on Object {
        unreadable += ordered.length - count + 1;
        break;
      }
    }
    if (thumbnail != null && !_geometryHolds(thumbnail)) {
      // A level may declare a size its payload cannot fill. Caught here
      // rather than left to crash whoever indexes the buffer.
      thumbnail = null;
      unreadable += 1;
    }

    final decodedFrames = <Uint8List>[];
    for (var count = 1; count <= frames.length; count++) {
      try {
        final attempt = video.decode(frames.sublist(0, count));
        decodedFrames
          ..clear()
          ..addAll(attempt);
      } on Object {
        // A temporal frame whose predecessor is missing or damaged ends
        // the run; everything before it is still good.
        unreadable += frames.length - count + 1;
        break;
      }
    }

    return RenderedPost(
      body: body,
      thumbnail: thumbnail,
      voiceColumns: voiceColumns,
      spokenText: spokenText,
      voiceProvenance: provenance,
      videoFrames: decodedFrames,
      unreadableParts: unreadable,
    );
  }

  /// Whether a decoded thumbnail's buffer matches the size it claims.
  static bool _geometryHolds(DecodedThumbnail thumbnail) =>
      thumbnail.gray.length >= thumbnail.width * thumbnail.height;

  /// Rebuild a progressive level, refusing a coder this build does not
  /// have rather than picking the nearest one.
  static ProgressiveLevel? _levelFrom(ImageLevelPayload payload) {
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
