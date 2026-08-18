/// The last hop: the app owns both packages, so the app is where the media
/// router finally acquires a production caller.
///
/// THE PATTERN THIS BREAKS. Three times in this project a component was built,
/// tested, and left inert because the final wire was the riskiest part:
/// `iceServers` never reached `createPeerConnection`; `LaneAggregationProbe`
/// decided and nothing consumed it; `MediaSendRouter` chose a path and nothing
/// asked. Each was correct and useless.
///
/// WHY THIS ONE IS SHADOWED RATHER THAN OBEYED. Obeying the router today would
/// break attachments: the receive-side router that maps `transferId` back to a
/// layer index does not exist in the app, so the sender would emit rateless
/// symbols nobody reassembles — turning a slow photo into a lost one. Shadow
/// mode asks the question on every real send, records the answer, and keeps the
/// old behaviour. The router stops being an orphan; the release builds stay
/// green; and the eventual switch is one boolean.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart'
    show MediaSendRouter, routeAttachment;
import 'package:messaging/messaging.dart'
    show AttachmentRouteAdvisor, AttachmentRouteDecision;

/// Builds the advisor to hand to `startAttachmentSend`.
///
/// [lossEstimate] is READ at call time rather than captured: an attachment sent
/// five minutes into a degrading call must be judged on the link as it is now,
/// and a value frozen at construction would route the worst transfers with the
/// best-case number. Null means "no estimator yet", which routes as a clean
/// channel — the same assumption the app makes today.
///
/// There is deliberately NO `obeyDecision` flag.
///
/// It existed, defaulted to false, and was a booby trap: it set
/// `actuallyUsedCliffFree: true` while nothing in `startAttachmentSend` read
/// that field, so flipping it produced telemetry claiming a path no byte took —
/// on the very metric shadow mode exists to produce. The switch belongs where
/// the switching happens. When the receive-side layer router lands and the send
/// path really branches, `actuallyUsedCliffFree` will be reported by that path.
AttachmentRouteAdvisor buildAttachmentRouteAdvisor({
  MediaSendRouter router = const MediaSendRouter(),
  double Function()? lossEstimate,
  void Function(AttachmentRouteDecision decision)? onDecision,
}) {
  return ({required int byteLength, required bool isImage}) {
    // OBSERVATION MUST NOT BE ABLE TO KILL A SEND.
    //
    // This runs synchronously inside `startAttachmentSend`, BEFORE the handle
    // exists. `onDecision` is wired to `notifyListeners()`, which throws on a
    // disposed ChangeNotifier; `lossEstimate` is somebody else's closure. An
    // exception from either used to propagate out of a method named "start"
    // and the attachment was never sent — telemetry losing a user's photo.
    try {
      // CLAMPING AND ERASING ARE NOT THE SAME OPERATION, and conflating them
      // defeated the router's own guard one level above it.
      //
      // An out-of-range FINITE estimate (7.5, -3.0) is a scaling mistake: the
      // link is real, the number is mis-expressed, and [0,1] is the honest
      // reading. A NON-FINITE estimate is not a number at all, and
      // `MediaSendRouter` deliberately routes it as if the link were BAD —
      // "an unusable estimate is not evidence of a good link". Substituting
      // 0.0 here, as this function used to, deleted that guard before it could
      // run: NaN arrived at the router as a pristine channel, and the one
      // failure direction the router was hardened against came back in through
      // its caller.
      //
      // So: clamp what is finite, and pass what is not straight through.
      final raw = lossEstimate?.call() ?? 0.0;
      final loss = raw.isFinite ? raw.clamp(0.0, 1.0).toDouble() : raw;
      final routed = routeAttachment(
        byteLength: byteLength < 0 ? 0 : byteLength,
        isImage: isImage,
        lossEstimate: loss,
        router: router,
      );
      final decision = AttachmentRouteDecision(
        wouldUseCliffFree: routed.isCliffFree,
        // The router's own sentence, carried verbatim. A boolean tells you the
        // verdict; only the reason tells you whether it came from the size,
        // the type, the loss estimate, or the absence of one.
        reason: routed.reason,
        // `actuallyUsedCliffFree` reports what the SEND PATH did, and the send
        // path is unconditionally the acknowledged one until the receive-side
        // layer router exists. Deriving it from a flag here produced telemetry
        // that lied: a caller could set obeyDecision and read back "cliff-free"
        // while every byte still went the old way. The flag is gone; when the
        // path really switches, this value comes from the path.
        actuallyUsedCliffFree: false,
        byteLength: byteLength,
        lossEstimate: loss,
      );
      try {
        onDecision?.call(decision);
      } on Object {
        // A listener that throws is the listener's problem, never the send's.
      }
      return decision;
    } on Object {
      // No decision is a truthful answer; a wrong decision is not.
      return null;
    }
  };
}
