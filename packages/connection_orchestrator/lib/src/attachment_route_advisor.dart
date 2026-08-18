/// The routing question, asked in the vocabulary an attachment sender has.
///
/// `MediaSendRouter` speaks in [MediaType]; the messaging layer knows only
/// "image or not" and a byte count. This adapter is the whole bridge, and it
/// lives here — with the router — so the mapping from "is it a photo" to a
/// media type is stated once, next to the thresholds it feeds.
///
/// It deliberately does NOT import `messaging`: this package is below it in the
/// dependency graph, and reaching upward to borrow a type would be a worse
/// defect than the duplication it avoids. The app layer, which owns both, does
/// the final adaptation.
library;

import 'media_send_router.dart';
import 'resilient_media_transport.dart' show MediaType;

/// Routes an attachment by size, kind and the live loss estimate.
///
/// [lossEstimate] is a value, not a source, so the caller decides how fresh it
/// is — and the caller is the one that knows.
///
/// A non-image attachment is routed as a document rather than as a photo on
/// purpose: the layering that makes an image useful when half-arrived does not
/// exist for a PDF, and routing it as a photo would promise a progressive
/// render that cannot happen.
MediaRouteDecision routeAttachment({
  required int byteLength,
  required bool isImage,
  double lossEstimate = 0.0,
  MediaSendRouter router = const MediaSendRouter(),
  MediaKindHint kind = MediaKindHint.unknown,
}) => router.route(
  type: kind.toMediaType(isImage: isImage),
  byteLength: byteLength,
  lossEstimate: lossEstimate,
);

/// What the attachment actually is.
///
/// A single `isImage` boolean collapsed audio and video into `document`, which
/// made two of the router's three layerable types unreachable from the
/// attachment path: a voice note under 2 KB went down the ACKNOWLEDGED path,
/// which is exactly the routing the router was written to prevent. A boolean
/// cannot express a four-way question.
enum MediaKindHint {
  image,
  voiceNote,
  video,

  /// Caller did not say. Falls back to the old boolean so existing call sites
  /// keep their behaviour instead of silently changing it.
  unknown;

  MediaType toMediaType({required bool isImage}) => switch (this) {
    MediaKindHint.image => MediaType.photo,
    MediaKindHint.voiceNote => MediaType.audioPcm,
    MediaKindHint.video => MediaType.flipbook,
    // Not a photo and not declared: a PDF has no coarse version to render
    // early, so promising a progressive path would be a promise nothing can
    // keep.
    MediaKindHint.unknown => isImage ? MediaType.photo : MediaType.document,
  };
}
