/// Turns the signed manifest's ICE servers into the exact map shape the peer
/// connection takes.
///
/// WHY THIS EXISTS. Until now nothing read `EndpointManifest.iceServers` and
/// handed it to `FlutterWebRtcPeerConnectionPort.create`, whose `iceServers`
/// parameter defaulted to `const []` — so every call was placed with no STUN or
/// TURN at all, and only succeeded when both peers happened to be directly
/// reachable. That is a bug, not a design; this module closes it.
///
/// It is a pure function so the mapping, the ordering, and the relay policy can
/// all be tested without a network or the plugin.
library;

import 'endpoint_manifest.dart';

/// How hard the connection should try to hide from a hostile network.
enum IceProfile {
  /// STUN and TURN both offered, direct paths allowed. The default for every
  /// fresh call: relaying everything costs bandwidth, money and latency.
  normal,

  /// Everything through TURN. Entered only after a call has already failed ICE
  /// twice, or when the manifest pushes the `strict_relay` flag — and never
  /// sticky: the next call starts at [normal] again.
  strictRelay,
}

/// The two values the peer connection config needs.
final class RtcIceConfig {
  const RtcIceConfig({
    required this.iceServers,
    required this.iceTransportPolicy,
  });

  final List<Map<String, Object>> iceServers;

  /// `'all'` or `'relay'`.
  final String iceTransportPolicy;
}

/// Thrown by [buildRtcIceConfig] when [IceProfile.strictRelay] is in force but
/// the manifest carries no TURN/TURNS entry, so the relay filter drops every
/// server.
///
/// WHY AN EXCEPTION AND NOT A RESULT TYPE. A relay-only policy with an empty
/// server list can gather no candidates, so a config in that state is not a
/// lesser outcome to pattern-match on — it is a contradiction between the
/// manifest and the profile, and no caller can do anything useful with it.
/// Throwing keeps the return type of [buildRtcIceConfig] unchanged, so the
/// normal path and the strict-with-relays path behave exactly as before, and
/// the caller cannot proceed as if a working config existed: the failure
/// surfaces at build time with its reason attached, instead of as a connection
/// that silently never completes.
///
/// It implements [Exception], not [Error], because the trigger is manifest
/// content — a runtime condition the caller should catch and report (or use to
/// fall back), not a programming defect.
final class StrictRelayUnsatisfiableException implements Exception {
  const StrictRelayUnsatisfiableException({required this.droppedEntryCount});

  /// How many manifest entries the strict-relay filter removed. Equals the
  /// manifest's full entry count, because the exception is only thrown when
  /// nothing survived. Zero means the manifest offered no ICE servers at all.
  final int droppedEntryCount;

  @override
  String toString() =>
      'StrictRelayUnsatisfiableException: strict relay profile in force but '
      'the manifest has no TURN/TURNS server; '
      '$droppedEntryCount STUN-only entries were dropped by the relay filter.';
}

/// Builds the peer-connection ICE configuration from [manifest].
///
/// Ordering, not filtering, expresses the TURNS-443 preference: every server is
/// still offered, because ICE tries them all and dropping one can only lose a
/// path that might have worked. Under [IceProfile.strictRelay] the STUN-only
/// entries ARE dropped, because a relay-only policy can never use them.
///
/// Throws [StrictRelayUnsatisfiableException] when that filter leaves nothing:
/// a `'relay'` policy with no relay servers cannot ever connect, and returning
/// it well-formed would hide the reason inside a call that never completes.
RtcIceConfig buildRtcIceConfig(
  EndpointManifest manifest, {
  IceProfile profile = IceProfile.normal,
}) {
  final strict = profile == IceProfile.strictRelay;

  final entries = <IceServerEntry>[
    for (final e in manifest.iceServers)
      if (!strict || e.urls.any(_isTurn)) e,
  ]..sort((a, b) => _rank(a).compareTo(_rank(b)));

  if (strict && entries.isEmpty) {
    throw StrictRelayUnsatisfiableException(
      droppedEntryCount: manifest.iceServers.length,
    );
  }

  return RtcIceConfig(
    iceServers: [
      for (final e in entries)
        <String, Object>{
          'urls': [for (final u in e.urls) u.toString()],
          if (e.username.isNotEmpty) 'username': e.username,
          if (e.credential.isNotEmpty) 'credential': e.credential,
        },
    ],
    iceTransportPolicy: strict ? 'relay' : 'all',
  );
}

/// Should this call use relay-only?
///
/// The rule is deliberately narrow. Two ICE failures on the SAME call — the
/// first attempt and then an ICE restart — is evidence the network will not
/// allow a direct path; anything less is a transient and does not justify
/// pushing every packet through TURN.
IceProfile iceProfileFor({
  required int iceFailureCount,
  required Map<String, bool> featureFlags,
}) {
  if (featureFlags['strict_relay'] == true) return IceProfile.strictRelay;
  return iceFailureCount >= 2 ? IceProfile.strictRelay : IceProfile.normal;
}

bool _isTurn(Uri u) {
  final s = u.scheme.toLowerCase();
  return s == 'turn' || s == 'turns';
}

/// 0 = turns on 443, 1 = other turns, 2 = turn, 3 = stun and everything else.
///
/// turns:...:443 is first because it is indistinguishable from ordinary HTTPS
/// on the wire, which is what survives the most restrictive networks.
int _rank(IceServerEntry e) {
  var best = 3;
  for (final u in e.urls) {
    final scheme = u.scheme.toLowerCase();
    final rank = switch (scheme) {
      'turns' => _portOf(u) == 443 ? 0 : 1,
      'turn' => 2,
      _ => 3,
    };
    if (rank < best) best = rank;
  }
  return best;
}

/// `stun:host:3478` is an opaque URI, so `Uri.port` is 0 and `Uri.host` empty.
/// Re-parsing with an authority marker is the standard workaround (RFC 7064,
/// RFC 7065 define these schemes without an authority component).
int? _portOf(Uri u) {
  if (u.hasPort) return u.port;
  final path = u.path;
  final reparsed = Uri.tryParse('//$path');
  if (reparsed != null && reparsed.hasPort) return reparsed.port;
  final q = path.indexOf('?');
  final hostPort = q < 0 ? path : path.substring(0, q);
  final colon = hostPort.lastIndexOf(':');
  if (colon < 0) return null;
  return int.tryParse(hostPort.substring(colon + 1));
}
