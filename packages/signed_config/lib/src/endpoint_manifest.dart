/// Signed endpoint manifest model.
///
/// v2 replaces every dynamic-provisioning mechanism from v1 with one honest
/// primitive: the app fetches a JSON manifest over plain HTTPS from its own
/// configuration service, verifies an Ed25519 signature against keys pinned
/// in the app build (see `manifest_verifier.dart`), and only then uses the
/// listed endpoints. Endpoints are exactly what they claim to be — WSS
/// signaling URIs and standard STUN/TURN server URIs (RFC 7064 / RFC 7065).
///
/// Designed from the v2 blueprint role (replaces v1
/// `resilient_provisioning.dart` / `dynamic_provisioning.dart`, which are
/// excluded legacy).
library;

import 'dart:convert';

/// Schema v2 (Phase 7 "Signed Endpoint Discovery"): multi-origin
/// `configServiceUris`, `relayRegions`, and limited `featureFlags`.
/// There are no deployed v1 manifests, so v2 is the only accepted version.
const int manifestSchemaVersion = 2;

/// Upper bound on `featureFlags` entries ("limited" per the v2 blueprint).
const int maxFeatureFlags = 32;

/// Upper bound on `signalingEndpoints` entries. A manifest lists priority-
/// ordered candidates, not an unbounded directory; this caps parser/memory
/// cost on untrusted input while staying far above any realistic deployment.
const int maxSignalingEndpoints = 16;

/// Upper bound on `configServiceUris` entries (same rationale as
/// [maxSignalingEndpoints]).
const int maxConfigServiceUris = 16;

/// Upper bound on `iceServers` entries.
///
/// Raised from 32 to 256 (2026-08-12). The single-document, single-signature
/// shape is kept deliberately: pagination was considered and rejected, because
/// it is not a schema change but a new compatibility protocol — either every
/// page carries its own signature, which opens the door to mixing pages from
/// different revisions and replaying an old one, or a signed index is needed
/// first, which costs an extra round trip before anything is usable and makes
/// page updates non-atomic.
///
/// The security load does not rest on this number. A byte cap on the whole
/// document, applied before any parsing, is what bounds the cost — see
/// `SignedManifestDocument.maxSignedDocumentBytes`.
const int maxIceServers = 256;

/// Upper bound on `relayRegions` entries.
const int maxRelayRegions = 32;

/// A standard STUN/TURN server entry, mirroring the W3C `RTCIceServer`
/// dictionary so it maps 1:1 onto WebRTC configuration.
final class IceServerEntry {
  /// `stun:`, `stuns:`, `turn:`, or `turns:` URIs.
  final List<Uri> urls;

  /// TURN long-term-credential username (empty for STUN).
  final String username;

  /// TURN credential (empty for STUN). Deployments should prefer
  /// short-lived credentials minted by the config service.
  final String credential;

  static const _allowedSchemes = {'stun', 'stuns', 'turn', 'turns'};

  /// STUN/TURN URIs are opaque per RFC 7064/7065 (`stun:host:port`, no
  /// `//`), so `dart:core`'s [Uri.host] is empty even for valid entries —
  /// it only populates from an authority (`//host:port`) component. Try
  /// the authority form first (some callers do write `stun://host:port`),
  /// then fall back to reparsing the opaque scheme-specific part as an
  /// authority to recover the real host.
  static String _hostOf(Uri uri) =>
      uri.host.isNotEmpty ? uri.host : Uri.parse('//${uri.path}').host;

  IceServerEntry({
    required List<Uri> urls,
    this.username = '',
    this.credential = '',
  }) : urls = List.unmodifiable(urls) {
    if (urls.isEmpty) {
      throw const FormatException('IceServerEntry requires at least one URI.');
    }
    for (final uri in urls) {
      if (!_allowedSchemes.contains(uri.scheme)) {
        throw FormatException(
          'ICE server URI must use stun/stuns/turn/turns, got: '
          '${uri.scheme}',
        );
      }
      if (_hostOf(uri).isEmpty) {
        throw FormatException('ICE server URI is missing a host: $uri');
      }
    }
    final needsCredentials = urls.any(
      (u) => u.scheme == 'turn' || u.scheme == 'turns',
    );
    if (needsCredentials && (username.isEmpty || credential.isEmpty)) {
      throw const FormatException(
        'TURN entries require username and credential.',
      );
    }
  }

  factory IceServerEntry.fromJson(Map<String, Object?> json) {
    final rawUrls = json['urls'];
    if (rawUrls is! List || rawUrls.isEmpty) {
      throw const FormatException('ICE server entry: urls must be a list.');
    }
    final urls = <Uri>[];
    for (final raw in rawUrls) {
      if (raw is! String) {
        throw const FormatException('ICE server URI must be a string.');
      }
      urls.add(Uri.parse(raw));
    }
    final username = json['username'];
    final credential = json['credential'];
    return IceServerEntry(
      urls: urls,
      username: username is String ? username : '',
      credential: credential is String ? credential : '',
    );
  }

  Map<String, Object?> toJson() => {
    'urls': urls.map((u) => u.toString()).toList(),
    if (username.isNotEmpty) 'username': username,
    if (credential.isNotEmpty) 'credential': credential,
  };
}

/// The verified configuration consumed by the rest of the app.
final class EndpointManifest {
  final int schemaVersion;

  /// Strictly increasing revision; the cache rejects anything lower than
  /// the last accepted revision (rollback protection).
  final int revision;

  /// Identifier of the signing key that produced this manifest's signature
  /// (enables key rotation among the pinned set).
  final String signingKeyId;

  final DateTime issuedAt;
  final DateTime expiresAt;

  /// WSS signaling endpoints in priority order.
  final List<Uri> signalingEndpoints;

  /// Standard STUN/TURN servers.
  final List<IceServerEntry> iceServers;

  /// HTTPS base URIs of the configuration service, in priority order, for
  /// the next refresh. The model requires >= 1; Phase 7 production policy
  /// requires >= 2 independent origins (enforced at deployment, not here,
  /// so tests and dev setups can run single-origin).
  final List<Uri> configServiceUris;

  /// Relay regions this manifest advertises (lowercase kebab/ASCII, e.g.
  /// `eu-central`). May be empty.
  final List<String> relayRegions;

  /// Limited feature toggles: at most [maxFeatureFlags] entries, keys are
  /// `snake_case` ASCII, values strictly boolean.
  final Map<String, bool> featureFlags;

  /// Minimum app version allowed to use these endpoints (semver string,
  /// enforced by the app shell; empty means no restriction).
  final String minimumAppVersion;

  static final _relayRegionPattern = RegExp(r'^[a-z0-9-]{1,32}$');
  static final _featureFlagKeyPattern = RegExp(r'^[a-z0-9_]{1,64}$');

  EndpointManifest({
    this.schemaVersion = manifestSchemaVersion,
    required this.revision,
    required this.signingKeyId,
    required this.issuedAt,
    required this.expiresAt,
    required List<Uri> signalingEndpoints,
    required List<IceServerEntry> iceServers,
    required List<Uri> configServiceUris,
    List<String> relayRegions = const [],
    Map<String, bool> featureFlags = const {},
    this.minimumAppVersion = '',
  }) : signalingEndpoints = List.unmodifiable(signalingEndpoints),
       iceServers = List.unmodifiable(iceServers),
       configServiceUris = List.unmodifiable(configServiceUris),
       relayRegions = List.unmodifiable(relayRegions),
       featureFlags = Map.unmodifiable(featureFlags) {
    if (schemaVersion != manifestSchemaVersion) {
      throw FormatException('Unsupported manifest schema: $schemaVersion');
    }
    if (revision < 1) {
      throw const FormatException('Manifest revision must be >= 1.');
    }
    if (signingKeyId.isEmpty) {
      throw const FormatException('signingKeyId is required.');
    }
    if (!expiresAt.isAfter(issuedAt)) {
      throw const FormatException('expiresAt must be after issuedAt.');
    }
    if (signalingEndpoints.isEmpty) {
      throw const FormatException(
        'Manifest must list at least one signaling endpoint.',
      );
    }
    for (final uri in signalingEndpoints) {
      if (uri.scheme != 'wss' || uri.host.isEmpty) {
        throw FormatException(
          'Signaling endpoints must be wss:// URIs, got: $uri',
        );
      }
    }
    // Count caps run AFTER the per-item format/type checks above, so an
    // oversized list that also contains a malformed entry keeps throwing
    // the existing, more specific FormatException rather than a generic
    // "too many" one.
    if (signalingEndpoints.length > maxSignalingEndpoints) {
      throw FormatException(
        'signalingEndpoints is limited to $maxSignalingEndpoints entries, '
        'got ${signalingEndpoints.length}.',
      );
    }
    if (iceServers.length > maxIceServers) {
      throw FormatException(
        'iceServers is limited to $maxIceServers entries, '
        'got ${iceServers.length}.',
      );
    }
    if (configServiceUris.isEmpty) {
      throw const FormatException(
        'Manifest must list at least one config service URI.',
      );
    }
    final seenConfigUris = <String>{};
    for (final uri in configServiceUris) {
      if (uri.scheme != 'https' || uri.host.isEmpty) {
        throw FormatException(
          'Config service URIs must be https://, got: $uri',
        );
      }
      if (!seenConfigUris.add(uri.toString())) {
        throw FormatException('Duplicate config service URI: $uri');
      }
    }
    if (configServiceUris.length > maxConfigServiceUris) {
      throw FormatException(
        'configServiceUris is limited to $maxConfigServiceUris entries, '
        'got ${configServiceUris.length}.',
      );
    }
    final seenRegions = <String>{};
    for (final region in relayRegions) {
      if (!_relayRegionPattern.hasMatch(region)) {
        throw FormatException(
          'Relay regions must match ^[a-z0-9-]{1,32}\$, got: "$region"',
        );
      }
      if (!seenRegions.add(region)) {
        throw FormatException('Duplicate relay region: $region');
      }
    }
    if (relayRegions.length > maxRelayRegions) {
      throw FormatException(
        'relayRegions is limited to $maxRelayRegions entries, '
        'got ${relayRegions.length}.',
      );
    }
    if (featureFlags.length > maxFeatureFlags) {
      throw FormatException(
        'featureFlags is limited to $maxFeatureFlags entries, '
        'got ${featureFlags.length}.',
      );
    }
    for (final key in featureFlags.keys) {
      if (!_featureFlagKeyPattern.hasMatch(key)) {
        throw FormatException(
          'Feature flag keys must match ^[a-z0-9_]{1,64}\$, got: "$key"',
        );
      }
    }
  }

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  factory EndpointManifest.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final revision = json['revision'];
    final signingKeyId = json['signingKeyId'];
    final issuedAt = json['issuedAt'];
    final expiresAt = json['expiresAt'];
    final signaling = json['signalingEndpoints'];
    final ice = json['iceServers'];
    final configServices = json['configServiceUris'];
    final regions = json['relayRegions'];
    final flags = json['featureFlags'];
    final minAppVersion = json['minimumAppVersion'];

    if (schemaVersion is! int ||
        revision is! int ||
        signingKeyId is! String ||
        issuedAt is! String ||
        expiresAt is! String ||
        signaling is! List ||
        ice is! List ||
        configServices is! List) {
      throw const FormatException('Manifest has missing or mistyped fields.');
    }
    // Reject unsupported schemas here as well as in the constructor, so the
    // error names the version even when other fields are also off.
    if (schemaVersion != manifestSchemaVersion) {
      throw FormatException('Unsupported manifest schema: $schemaVersion');
    }
    if (regions is! List?) {
      throw const FormatException('relayRegions must be a list of strings.');
    }
    if (flags is! Map<String, Object?>?) {
      throw const FormatException(
        'featureFlags must be an object of boolean values.',
      );
    }
    final featureFlags = <String, bool>{};
    for (final MapEntry(:key, :value) in (flags ?? const {}).entries) {
      if (value is! bool) {
        throw FormatException(
          'Feature flag "$key" must be a boolean, got: $value',
        );
      }
      featureFlags[key] = value;
    }

    return EndpointManifest(
      schemaVersion: schemaVersion,
      revision: revision,
      signingKeyId: signingKeyId,
      issuedAt: DateTime.parse(issuedAt).toUtc(),
      expiresAt: DateTime.parse(expiresAt).toUtc(),
      signalingEndpoints: [
        for (final raw in signaling)
          if (raw is String)
            Uri.parse(raw)
          else
            throw const FormatException(
              'Signaling endpoint must be a string URI.',
            ),
      ],
      iceServers: [
        for (final raw in ice)
          if (raw is Map<String, Object?>)
            IceServerEntry.fromJson(raw)
          else
            throw const FormatException(
              'ICE server entry must be a JSON object.',
            ),
      ],
      configServiceUris: [
        for (final raw in configServices)
          if (raw is String)
            Uri.parse(raw)
          else
            throw const FormatException('Config service URI must be a string.'),
      ],
      relayRegions: [
        for (final raw in regions ?? const [])
          if (raw is String)
            raw
          else
            throw const FormatException('Relay region must be a string.'),
      ],
      featureFlags: featureFlags,
      minimumAppVersion: minAppVersion is String ? minAppVersion : '',
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'revision': revision,
    'signingKeyId': signingKeyId,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'signalingEndpoints': signalingEndpoints.map((u) => u.toString()).toList(),
    'iceServers': iceServers.map((s) => s.toJson()).toList(),
    'configServiceUris': configServiceUris.map((u) => u.toString()).toList(),
    // Always emitted (even when empty) so the canonical signed bytes never
    // depend on presence-vs-absence of these fields.
    'relayRegions': relayRegions,
    'featureFlags': Map<String, Object?>.of(featureFlags),
    if (minimumAppVersion.isNotEmpty) 'minimumAppVersion': minimumAppVersion,
  };

  /// Canonical bytes that the manifest signature covers.
  ///
  /// Canonicalization rule: the `toJson()` map is re-encoded with keys
  /// sorted lexicographically at every nesting level, UTF-8 encoded, no
  /// insignificant whitespace. Both the signer (config service) and the
  /// verifier (app) must use this exact rule.
  List<int> canonicalBytes() => utf8.encode(_canonicalJson(toJson()));

  static String _canonicalJson(Object? value) {
    if (value is Map<String, Object?>) {
      final keys = value.keys.toList()..sort();
      final parts = <String>[
        for (final key in keys)
          '${jsonEncode(key)}:${_canonicalJson(value[key])}',
      ];
      return '{${parts.join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}
