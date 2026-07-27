/// Turning real media into the four broadcast layers, inside a byte budget.
///
/// The order of operations is the design. Instead of encoding everything
/// and hoping it fits, the composer is told what the post may cost and
/// fills that from the most important byte to the least: text, then the
/// coarsest picture, then voice, then refinements and motion for whoever
/// can afford them. A reader on the worst link gets a complete message
/// rather than a truncated one, which is the same promise the call side
/// makes when it degrades instead of dropping.
///
/// Nothing is ever dropped quietly. Every part that did not fit is named
/// in the report with the size it would have taken, because a silent cap
/// reads as "everything is here" when it is not.
library;

import 'dart:typed_data';

import 'package:broadcast/broadcast.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';

import 'media_sources.dart';
import 'payload_envelope.dart';

/// What each layer of one post may cost.
///
/// The defaults come from the design's own tiering: a text-only post is
/// under a kilobyte, a picture is tens of kilobytes, and motion is the
/// only thing allowed to be large — and it is optional by construction,
/// because it lives in the layer a reader may skip.
class MediaBudget {
  const MediaBudget({
    this.textBytes = 4 * 1024,
    this.stillBytes = 24 * 1024,
    this.voiceBytes = 8 * 1024,
    this.heavyBytes = 512 * 1024,
  });

  /// A budget for a link that can carry almost nothing.
  static const MediaBudget survival = MediaBudget(
    textBytes: 1024,
    stillBytes: 2 * 1024,
    voiceBytes: 1024,
    heavyBytes: 0,
  );

  final int textBytes;
  final int stillBytes;
  final int voiceBytes;

  /// Ceiling for the optional refinement-and-motion layer. Zero disables
  /// it entirely.
  final int heavyBytes;
}

/// One part that was encoded, or that could not be afforded.
class PartReport {
  const PartReport({
    required this.name,
    required this.bytes,
    required this.included,
  });

  /// A stable label: `text`, `image.level.0`, `voice`, `video.frame.3`.
  final String name;

  /// Encoded size. Present whether or not it was included, so a caller
  /// can see exactly what raising the budget would buy.
  final int bytes;

  final bool included;
}

/// What the composer did, in full.
class CompositionReport {
  CompositionReport(List<PartReport> parts) : parts = List.unmodifiable(parts);

  final List<PartReport> parts;

  List<PartReport> get included => [
    for (final p in parts)
      if (p.included) p,
  ];

  /// Parts that did not fit, with what each would have cost.
  List<PartReport> get dropped => [
    for (final p in parts)
      if (!p.included) p,
  ];

  int get includedBytes => included.fold(0, (sum, part) => sum + part.bytes);

  bool get isComplete => dropped.isEmpty;

  @override
  String toString() =>
      'CompositionReport(${included.length} parts, $includedBytes bytes'
      '${dropped.isEmpty ? '' : ', dropped ${[for (final p in dropped) p.name]}'})';
}

/// The encoded layers of one post, ready to hand to a publisher.
class ComposedLayers {
  const ComposedLayers({
    required this.report,
    this.text,
    this.still,
    this.voice,
    this.heavy,
  });

  final CompositionReport report;

  final Uint8List? text;
  final Uint8List? still;
  final Uint8List? voice;

  /// The optional bundle: image refinements and video frames.
  final Uint8List? heavy;

  bool get isEmpty =>
      text == null && still == null && voice == null && heavy == null;
}

/// Composes broadcast layers from real media.
class BroadcastMediaComposer {
  const BroadcastMediaComposer({
    this.budget = const MediaBudget(),
    this.text = const TextDocumentCompressor(),
    this.image = const LowRateImageCompressor(),
    this.video = const FlipbookVideoCompressor(),
  });

  final MediaBudget budget;
  final TextDocumentCompressor text;
  final LowRateImageCompressor image;
  final FlipbookVideoCompressor video;

  /// Encode everything supplied, filling [budget] most-important first.
  ///
  /// [voiceSession] is required whenever [voiceTokens] is given: the token
  /// codec's compression comes entirely from state shared with the reader
  /// and carried across posts, so a session created fresh per post would
  /// throw away the very thing that makes it small.
  ComposedLayers compose({
    String? body,
    RasterImage? picture,
    VoiceTokenBlock? voiceTokens,
    HamsedaSession? voiceSession,
    VideoClip? clip,
  }) {
    if (voiceTokens != null && voiceSession == null) {
      throw ArgumentError.value(
        voiceSession,
        'voiceSession',
        'token voice needs the session that carries its shared state',
      );
    }

    final parts = <PartReport>[];
    Uint8List? textLayer;
    Uint8List? stillLayer;
    Uint8List? voiceLayer;
    final heavyParts = <PayloadEnvelope>[];

    if (body != null && body.isNotEmpty) {
      final encoded = PayloadEnvelope(
        kind: PayloadKind.text,
        body: text.compress(body),
      ).encode();
      // Text is never dropped. It is the layer that carries the message,
      // it is the smallest thing here, and a post whose words did not fit
      // is not a post. Going over budget is reported instead.
      textLayer = encoded;
      parts.add(
        PartReport(name: 'text', bytes: encoded.length, included: true),
      );
      if (encoded.length > budget.textBytes) {
        parts.add(
          PartReport(
            name: 'text.over-budget',
            bytes: encoded.length - budget.textBytes,
            included: false,
          ),
        );
      }
    }

    if (picture != null) {
      final levels = image.encodeProgressive(
        picture.pixels,
        picture.width,
        picture.height,
        picture.channels,
      );
      for (var i = 0; i < levels.length; i++) {
        final envelope = PayloadEnvelope(
          kind: PayloadKind.imageLevel,
          body: ImageLevelPayload(
            width: levels[i].width,
            height: levels[i].height,
            coderIndex: levels[i].coder.index,
            bytes: levels[i].bytes,
          ).encode(),
        );
        final encoded = envelope.encode();
        final name = 'image.level.$i';
        if (i == 0) {
          // The coarsest level goes in its own layer so a reader gets a
          // picture from one fetch, without touching the heavy bundle.
          final fits = encoded.length <= budget.stillBytes;
          if (fits) stillLayer = encoded;
          parts.add(
            PartReport(name: name, bytes: encoded.length, included: fits),
          );
        } else {
          final fits = _fitsHeavy(heavyParts, encoded);
          if (fits) heavyParts.add(envelope);
          parts.add(
            PartReport(name: name, bytes: encoded.length, included: fits),
          );
        }
      }
    }

    if (voiceTokens != null) {
      final encoded = PayloadEnvelope(
        kind: PayloadKind.voiceTokens,
        body: voiceSession!.encodeBlock(voiceTokens.columns),
      ).encode();
      final fits = encoded.length <= budget.voiceBytes;
      if (fits) {
        voiceLayer = encoded;
        voiceSession.commit();
      } else {
        // Roll the codec state back, or the reader's state would advance
        // past a block it never received and every later block would
        // decode to nonsense.
        voiceSession.rollback();
      }
      parts.add(
        PartReport(name: 'voice', bytes: encoded.length, included: fits),
      );
    }

    if (clip != null) {
      final frames = video.encode(clip.frames, clip.width, clip.height);
      for (var i = 0; i < frames.length; i++) {
        final envelope = PayloadEnvelope(
          kind: PayloadKind.videoFrame,
          body: VideoFramePayload(
            index: frames[i].index,
            predictorIndex: frames[i].predictor.index,
            bytes: frames[i].bytes,
          ).encode(),
        );
        final encoded = envelope.encode();
        // Frames stop at the first one that does not fit rather than
        // skipping ahead: a later frame predicted from a frame that was
        // dropped cannot be decoded anyway.
        final fits =
            heavyParts.length < maxBundleParts &&
            _fitsHeavy(heavyParts, encoded) &&
            !parts.any((p) => p.name.startsWith('video.frame') && !p.included);
        if (fits) heavyParts.add(envelope);
        parts.add(
          PartReport(
            name: 'video.frame.$i',
            bytes: encoded.length,
            included: fits,
          ),
        );
      }
    }

    final heavy = heavyParts.isEmpty
        ? null
        : PayloadBundle(heavyParts).encode();

    return ComposedLayers(
      report: CompositionReport(parts),
      text: textLayer,
      still: stillLayer,
      voice: voiceLayer,
      heavy: heavy,
    );
  }

  bool _fitsHeavy(List<PayloadEnvelope> held, Uint8List candidate) {
    if (budget.heavyBytes <= 0) return false;
    var used = 3;
    for (final part in held) {
      used += 4 + 2 + part.body.length;
    }
    return used + 4 + candidate.length <= budget.heavyBytes;
  }
}

/// Publish [layers] as one post.
///
/// The heavy bundle goes in as the chunked media layer rather than as a
/// directly committed one, so a reader fetches it a chunk at a time and
/// verifies each chunk on arrival — which is exactly the layer that is
/// large enough for that to matter.
Future<BroadcastPost> publishComposed(
  BroadcastPublisher publisher,
  ComposedLayers layers, {
  int mediaChunkSize = 64 * 1024,
  DateTime? at,
}) {
  if (layers.isEmpty) {
    throw ArgumentError.value(layers, 'layers', 'nothing was composed');
  }
  return publisher.publish(
    text: layers.text,
    still: layers.still,
    voice: layers.voice,
    media: layers.heavy,
    mediaChunkSize: mediaChunkSize,
    at: at,
  );
}
