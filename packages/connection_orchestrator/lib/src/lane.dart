/// Lane metadata: what the fabric knows about a registered transport
/// beyond its raw [TransportChannel] health.
library;

import 'package:device_link/device_link.dart' show DeviceLinkConsent;

/// Broad class of a lane, used for reporting and tie-breaking.
enum LaneKind {
  /// Infrastructure path (server/relay reachable over the network).
  internet,

  /// Direct nearby-device link.
  localPeer,

  /// Intermittent physical carrier (a device that moves between peers).
  carrier,
}

/// Static, owner-declared facts about a lane. Health is measured live by
/// the channel itself; this profile carries what measurement cannot know:
/// relative cost and the consent that authorizes using the lane at all.
class LaneProfile {
  const LaneProfile({
    required this.id,
    required this.kind,
    this.costRank = 0,
    this.consent,
  });

  /// Unique fabric-wide lane id.
  final String id;

  final LaneKind kind;

  /// Relative cost of using this lane: 0 = free/preferred, higher = more
  /// expensive. Used as a score penalty so a cheap lane wins a near-tie.
  final int costRank;

  /// When set, the lane is eligible only while [DeviceLinkConsent.granted]
  /// is true. Consent is re-read on every ranking pass, so revocation
  /// takes effect immediately.
  final DeviceLinkConsent? consent;

  /// Whether the lane may be used right now.
  bool get eligible => consent == null || consent!.granted;
}
