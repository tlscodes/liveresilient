/// Real media for the broadcast layers.
///
/// The `broadcast` package deals in bytes and says nothing about what they
/// mean. This one says what they mean, using codecs that already exist in
/// this workspace rather than new ones: the context-mixing document
/// compressor for text, the progressive low-rate compressor for a
/// picture, the token entropy codec for voice, the flipbook compressor for
/// a short clip.
///
/// One honest gap, stated here because it decides what a product can
/// promise: turning speech into tokens needs a neural codec that does not
/// live in this repository. This package entropy-codes tokens a caller
/// supplies and does not pretend to produce them.
library;

export 'src/broadcast_media_composer.dart';
export 'src/broadcast_media_renderer.dart';
export 'src/media_sources.dart';
export 'src/payload_envelope.dart';
