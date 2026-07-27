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
  /// to run a [RealityGate]; null disables the gate entirely. This is the
  /// statically configured value; use [resolvedFallbackTarget] to honor a
  /// `FALLBACK_TARGET_HOST` environment override.
  final FallbackTarget? fallbackTarget;

  /// [fallbackTarget], with [FallbackTarget.hostEnvironmentVariable]
  /// applied on top: an operator can redirect the splice destination at
  /// deploy time without rebuilding the config, and the environment always
  /// wins over whatever is statically configured here.
  FallbackTarget? get resolvedFallbackTarget =>
      FallbackTarget.resolve(fallbackTarget);

  /// Relay side: the credentials admitted.
  final List<RealityCredential> shortIds;

  /// Skip the cross-layer consistency checks. Legitimate when the host OS
  /// really is the one being claimed by a different profile.
  final bool allowProfileMismatch;

  /// Parses the deployment config schema.
  ///
  /// ```json
  /// {
  ///   "edgeBridgeNodes": ["203.0.113.10:443", "203.0.113.11:443"],
  ///   "fallbackTarget": "www.apple.com:443",
  ///   "shortIds": ["a1b2c3d4a1b2c3d4"],
  ///   "utlsProfile": "chrome_latest",
  ///   "tcpOsProfile": "windows_11",
  ///   "enablePQ": true,
  ///   "enableECH": true,
  ///   "shaping": {"paddingRange": [1, 128], "jitterMicroseconds": 250}
  /// }
  /// ```
  ///
  /// `edgeBridgeNodes` is read by [EdgeBridgeTopology.fromConfig], not
  /// here — the two are parsed separately on purpose, so a client can hold
  /// a topology without holding a relay's credentials.
  ///
  /// `shortIds` are hex, 8 bytes each, and are *identifiers only*: the key
  /// each one authenticates under is not in this file and must not be. A
  /// short id in a config is a lookup handle; a key in a config is a
  /// credential leak. Pass keys via [shortIds] built with
  /// [RealityCredential.fromSharedSecret].
  factory ProbeDefenseConfig.fromJson(Map<String, Object?> json) {
    final shaping = json['shaping'];
    return ProbeDefenseConfig(
      utlsProfile: _parseUtlsProfile(json['utlsProfile']),
      tcpProfile: _parseTcpProfile(json['tcpOsProfile']),
      enablePostQuantum: json['enablePQ'] as bool? ?? true,
      enableEch: json['enableECH'] as bool? ?? true,
      shaping: shaping is Map<String, Object?>
          ? _parseShaping(shaping)
          : TrafficShapingPolicy.voice,
      fallbackTarget: _parseFallbackTarget(json['fallbackTarget']),
      allowProfileMismatch: json['allowProfileMismatch'] as bool? ?? false,
    );
  }

  static UtlsProfileId _parseUtlsProfile(Object? value) {
    final name = (value as String? ?? 'chrome_latest').toLowerCase();
    return switch (name) {
      'chrome_latest' || 'chrome' || 'chrome120' => UtlsProfileId.chrome120,
      'firefox_latest' || 'firefox' || 'firefox120' => UtlsProfileId.firefox120,
      'safari_latest' || 'safari' || 'safari17' => UtlsProfileId.safari17,
      _ => throw ProbeDefenseConfigError('unknown utlsProfile "$value"'),
    };
  }

  static TcpStackProfileId? _parseTcpProfile(Object? value) {
    if (value == null) return null;
    final name = (value as String).toLowerCase();
    // The schema names OS releases; the profiles name stacks. A release
    // maps to a stack, never the other way round.
    return switch (name) {
      'windows_11' || 'windows_10' || 'windows' => TcpStackProfileId.windows,
      'ios' || 'ios_17' || 'macos' => TcpStackProfileId.iOS,
      'android' || 'android_14' => TcpStackProfileId.android,
      'linux' || 'ubuntu' => TcpStackProfileId.linux,
      _ => throw ProbeDefenseConfigError('unknown tcpOsProfile "$value"'),
    };
  }

  static FallbackTarget? _parseFallbackTarget(Object? value) {
    if (value == null) return null;
    final raw = (value as String).trim();
    if (raw.isEmpty) return null;
    final uri = raw.contains('://') ? Uri.parse(raw) : Uri.parse('https://$raw');
    if (uri.host.isEmpty) {
      throw ProbeDefenseConfigError('fallbackTarget "$value" has no host');
    }
    return FallbackTarget(host: uri.host, port: uri.hasPort ? uri.port : 443);
  }

  static TrafficShapingPolicy _parseShaping(Map<String, Object?> json) {
    final range = json['paddingRange'];
    var maxPadding = TrafficShapingPolicy.voice.maxPadding;
    var mean = TrafficShapingPolicy.voice.gaussianMean;
    if (range is List && range.length == 2) {
      final low = (range[0] as num).toInt();
      final high = (range[1] as num).toInt();
      if (high < low) {
        throw ProbeDefenseConfigError(
          'paddingRange [$low, $high] is inverted',
        );
      }
      maxPadding = high;
      // Center the Gaussian in the requested range rather than keeping the
      // default mean, which could sit outside it.
      mean = low + (high - low) ~/ 2;
    }
    final jitterMicros = (json['jitterMicroseconds'] as num?)?.toInt();
    return TrafficShapingPolicy(
      distribution: _parseDistribution(json['distribution']),
      maxPadding: maxPadding,
      gaussianMean: mean,
      gaussianStdDev: (mean ~/ 2).clamp(1, 1 << 30),
      maxJitter: jitterMicros == null
          ? TrafficShapingPolicy.voice.maxJitter
          : Duration(microseconds: jitterMicros),
    );
  }

  static LengthDistribution _parseDistribution(Object? value) {
    if (value == null) return LengthDistribution.gaussian;
    final name = (value as String).toLowerCase();
    for (final distribution in LengthDistribution.values) {
      if (distribution.name == name) return distribution;
    }
    throw ProbeDefenseConfigError('unknown shaping distribution "$value"');
  }

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
