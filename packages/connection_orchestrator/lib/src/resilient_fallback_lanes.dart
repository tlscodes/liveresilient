/// Registers the resilient fallback lane stack with a [ConnectionFabric].
///
/// The lanes themselves live in `adaptive_transport`; this file only says
/// what the fabric cannot measure — each lane's id, kind, relative cost and
/// energy draw — and hands them over through the standard
/// [ConnectionFabric.registerLane] interface.
///
/// Why the lanes are registered INDIVIDUALLY rather than as one composed
/// [ResilientFallbackTransportChain]: the fabric already ranks, fails over
/// and learns per lane, and it parks undeliverable payloads in the DTN
/// queue. Registering the chain's [PathSelector] as a single channel would
/// nest a second ranker inside the first, hiding per-lane health from the
/// snapshot stream and from [LaneExperience]. Use
/// [ResilientFallbackTransportChain] directly when a caller wants a
/// standalone selector with no fabric; use this file when the fabric is the
/// owner.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart' show DeviceLinkConsent;

import 'connection_fabric.dart';
import 'lane.dart';

/// Fabric-wide lane ids for the resilient stack, so callers can correlate a
/// [ConnectivitySnapshot] entry back to the lane that produced it.
class ResilientLaneIds {
  const ResilientLaneIds._();

  static const String primaryUdp = 'resilient.udp';
  static const String webSocketRelay = 'resilient.wss';
  static const String httpLongPoll = 'resilient.https';
  static const String localMesh = 'resilient.mesh';
}

/// Registration helper for the four fallback lanes.
class ResilientFallbackLanes {
  const ResilientFallbackLanes._();

  /// Registers every non-null lane with [fabric] and returns the ids that
  /// were registered, in the order they were added.
  ///
  /// Every lane is optional: pass only the ones this device can actually
  /// use right now (no mesh peer in range → leave [localMesh] null).
  /// Passing none at all is an error — a fabric with no lane to register
  /// is a caller bug, not a degraded mode.
  ///
  /// Cost and energy ranks encode the intended preference order — the
  /// fabric subtracts `costRank * 0.05` from live health when ranking, so
  /// these are the tie-breakers that decide the stack order before any
  /// traffic has flowed: direct UDP (0) → relay, one hop (1) → long-poll,
  /// most bytes per frame (2) → local mesh (3). The mesh ranks LAST
  /// despite carrying no WAN cost: it depends on a third party's radio and
  /// willingness to relay, so it is a last resort, not a cheap default.
  /// Its higher [LaneProfile.energyRank] additionally demotes it when the
  /// device reports low battery.
  ///
  /// [meshConsent], when given, gates the mesh lane: it stays ineligible
  /// until consent is granted and becomes ineligible again the moment it
  /// is revoked.
  static List<String> registerAll(
    ConnectionFabric fabric, {
    TransportChannel? primaryUdp,
    TransportChannel? webSocketRelay,
    TransportChannel? httpLongPoll,
    TransportChannel? localMesh,
    DeviceLinkConsent? meshConsent,
  }) {
    final registered = <String>[];

    void add(TransportChannel? channel, LaneProfile profile) {
      if (channel == null) return;
      fabric.registerLane(channel, profile);
      registered.add(profile.id);
    }

    add(
      primaryUdp,
      const LaneProfile(
        id: ResilientLaneIds.primaryUdp,
        kind: LaneKind.internet,
        costRank: 0,
        energyRank: 0,
      ),
    );
    add(
      webSocketRelay,
      const LaneProfile(
        id: ResilientLaneIds.webSocketRelay,
        kind: LaneKind.internet,
        costRank: 1,
        energyRank: 1,
      ),
    );
    add(
      httpLongPoll,
      const LaneProfile(
        id: ResilientLaneIds.httpLongPoll,
        kind: LaneKind.internet,
        costRank: 2,
        energyRank: 1,
      ),
    );
    add(
      localMesh,
      LaneProfile(
        id: ResilientLaneIds.localMesh,
        kind: LaneKind.localPeer,
        costRank: 3,
        energyRank: 2,
        consent: meshConsent,
      ),
    );

    if (registered.isEmpty) {
      throw ArgumentError('At least one resilient lane must be provided.');
    }
    return registered;
  }

  /// Removes every resilient lane id from [fabric]. Ids that were never
  /// registered are ignored, so this is safe to call on teardown paths that
  /// do not know which lanes came up.
  static void unregisterAll(ConnectionFabric fabric) {
    for (final id in const [
      ResilientLaneIds.primaryUdp,
      ResilientLaneIds.webSocketRelay,
      ResilientLaneIds.httpLongPoll,
      ResilientLaneIds.localMesh,
    ]) {
      fabric.unregisterLane(id);
    }
  }
}
