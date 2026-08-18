/// The routing decision for an attachment, recorded before it is obeyed.
///
/// WHY THIS EXISTS, AND WHY IT DOES NOT SWITCH ANYTHING YET.
///
/// This project has now shipped the same defect three times: `iceServers`
/// existed and never reached `createPeerConnection`; `LaneAggregationProbe`
/// decided and nothing consumed the decision; `MediaSendRouter` chose a path
/// and nothing asked it. Each time the component was correct, tested, and
/// inert. The pattern is not carelessness — it is that the last hop is always
/// the riskiest one, so it is always the one deferred.
///
/// Flipping attachments onto the cliff-free path today would break them: the
/// receive side that maps `transferId` back to a layer index does not exist in
/// the app yet, so the sender would emit rateless symbols nobody reassembles.
/// The honest intermediate is SHADOW MODE — consult the router on every real
/// send, record what it would have done, and keep sending the old way until
/// the receive side exists.
///
/// That buys three things a deferred wire does not:
/// - the router acquires a production caller, so it stops being an orphan and
///   starts being exercised by real payload sizes and real types;
/// - the decision becomes observable, so the switching thresholds can be
///   argued about with data from the actual app instead of from a test;
/// - the day the receive side lands, the change is one branch here, not a
///   design conversation.
///
/// The single rule this file must never break: it does not decide. The
/// thresholds live in `MediaSendRouter`, which lives in
/// `connection_orchestrator` and cannot be imported here (`messaging` does not
/// depend on it, and inverting that would be worse than the duplication this
/// avoids). So the decision is INJECTED as a callback by whoever owns both.
library;

/// What the router said, and what actually happened.
///
/// The two are separate fields on purpose. When they differ, that is not a
/// bug — it is shadow mode working, and the gap between them is the measurement
/// that justifies flipping.
class AttachmentRouteDecision {
  const AttachmentRouteDecision({
    required this.wouldUseCliffFree,
    required this.reason,
    required this.actuallyUsedCliffFree,
    required this.byteLength,
    required this.lossEstimate,
  });

  /// The router's verdict for this payload.
  final bool wouldUseCliffFree;

  /// The router's own words, carried through so a log line explains itself
  /// rather than merely reporting a boolean.
  final String reason;

  /// What the transfer actually did. False everywhere until the receive side
  /// exists; when it becomes true, this file is where that shows up.
  final bool actuallyUsedCliffFree;

  final int byteLength;
  final double lossEstimate;

  /// True while the decision is observed but not obeyed.
  bool get isShadowed => wouldUseCliffFree && !actuallyUsedCliffFree;

  /// Always JSON-encodable.
  ///
  /// `lossEstimate` is null rather than a number when the estimator produced
  /// NaN or infinity, for two reasons. The mechanical one: `jsonEncode` throws
  /// `JsonUnsupportedObjectError` on non-finite doubles, so a map containing
  /// one is a telemetry line that never leaves the device — the failure would
  /// erase exactly the events worth investigating. The honest one: there is no
  /// finite number that means "no usable estimate". Writing 0.0 would report a
  /// pristine link next to a verdict that routed as if the link were bad, and
  /// a reader has no way to tell that fabrication from a measurement.
  Map<String, Object?> toTelemetry() => <String, Object?>{
    'wouldUseCliffFree': wouldUseCliffFree,
    'actuallyUsedCliffFree': actuallyUsedCliffFree,
    'shadowed': isShadowed,
    'byteLength': byteLength,
    'lossEstimate': lossEstimate.isFinite
        ? double.parse(lossEstimate.toStringAsFixed(3))
        : null,
    'reason': reason,
  };

  /// Never throws.
  ///
  /// `(lossEstimate * 100).round()` raises `UnsupportedError` on NaN and
  /// infinity, which would make every log line and every debugger inspection
  /// of this object fail — a `toString` that throws turns a diagnostic aid
  /// into a second incident.
  @override
  String toString() {
    final pct = lossEstimate.isFinite
        ? '${(lossEstimate * 100).round()}%'
        : 'unknown';
    return 'route(${wouldUseCliffFree ? 'cliff-free' : 'acknowledged'}'
        '${isShadowed ? ', SHADOWED' : ''}, $byteLength B, loss $pct): $reason';
  }
}

/// Asks the routing question for a payload of [byteLength] bytes.
///
/// Supplied by the layer that owns `MediaSendRouter`; null means "nobody is
/// watching", which must behave exactly like today.
typedef AttachmentRouteAdvisor =
    AttachmentRouteDecision? Function({
      required int byteLength,
      required bool isImage,
    });
