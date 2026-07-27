/// One configuration object for the probe-defense layer.
///
/// Exists so a deployment states its posture in a single place, and so
/// contradictions between the layers are caught at construction rather
/// than discovered in a packet capture: a Safari TLS profile paired with a
/// Windows TCP profile is rejected here, because the two together are more
/// distinguishing than either would be alone.
library;

import 'reality_pass_through.dart';
import 'tcp_stack_profile.dart';
import 'traffic_shaper.dart';
import 'utls_client_profile.dart';

/// A mismatch between layers that would make the connection *more*
/// identifiable than an unconfigured one.
class ProbeDefenseConfigError implements Exception {
  const ProbeDefenseConfigError(this.message);

  final String message;

  @override
  String toString() => 'ProbeDefenseConfigError: $message';
}

/// Client- and relay-side probe-defense settings.
class ProbeDefenseConfig {
  ProbeDefenseConfig({
    this.utlsProfile = UtlsProfileId.chrome120,
    TcpStackProfileId? tcpProfile,
    this.enablePostQuantum = true,
    this.enableEch = true,
    this.shaping = TrafficShapingPolicy.voice,
    this.fallbackTarget,
    this.shortIds = const [],
    this.allowProfileMismatch = false,
  }) : tcpProfile = tcpProfile ?? _defaultTcpFor(utlsProfile) {
    if (allowProfileMismatch) return;

    final tls = UtlsClientProfile.forId(utlsProfile);
    final expected = TcpStackProfile.byName(tls.defaultTcpProfile);
    if (expected != null && expected.id != this.tcpProfile) {
      throw ProbeDefenseConfigError(
        'TLS profile ${utlsProfile.name} implies a '
        '${tls.defaultTcpProfile} TCP stack, not ${this.tcpProfile.name}; '
        'the pair is a stronger signal than either alone. Pass '
        'allowProfileMismatch: true only if the host OS genuinely differs.',
      );
    }
    if (enablePostQuantum && !tls.offersPostQuantum) {
      throw ProbeDefenseConfigError(
        '${utlsProfile.name} ships no hybrid post-quantum group; offering '
        'one while claiming that browser is itself an anomaly. Set '
        'enablePostQuantum: false or pick a profile that offers it.',
      );
    }
  }

  /// Which browser the Client Hello imitates.
  final UtlsProfileId utlsProfile;

  /// Which OS stack the socket imitates.
  final TcpStackProfileId tcpProfile;

  /// Offer a hybrid post-quantum key exchange. On by default: Chrome and
  /// Firefox now do, so *not* offering one is the anomaly.
  final bool enablePostQuantum;

  /// Send an `encrypted_client_hello` extension (a GREASE one when no
  /// config is available, which is what browsers do).
  final bool enableEch;

  final TrafficShapingPolicy shaping;

  /// Relay side: where unauthenticated connections are spliced. Required
  /// to run a [RealityGate]; null disables the gate entirely.
  final FallbackTarget? fallbackTarget;

  /// Relay side: the credentials admitted.
  final List<RealityCredential> shortIds;

  /// Skip the cross-layer consistency checks. Legitimate when the host OS
  /// really is the one being claimed by a different profile.
  final bool allowProfileMismatch;

  /// The resolved TLS profile.
  UtlsClientProfile get tls => UtlsClientProfile.forId(utlsProfile);

  /// The resolved TCP stack profile.
  TcpStackProfile get tcp => TcpStackProfile.forId(tcpProfile);

  /// Observables this configuration declares but cannot actually set from
  /// a userspace Dart process. Never empty — surface it, don't swallow it.
  List<String> get unenforceableObservables => tcp.unreachableObservables;

  static TcpStackProfileId _defaultTcpFor(UtlsProfileId id) {
    final name = UtlsClientProfile.forId(id).defaultTcpProfile;
    return TcpStackProfile.byName(name)?.id ?? TcpStackProfileId.linux;
  }
}
