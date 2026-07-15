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

const int manifestSchemaVersion = 1;

/// A standard STUN/TURN server entry, mirroring the W3C `RTCIceServer`
/// dictionary so it maps 1:1 onto WebRTC configuration.
class IceServerEntry {
  /// `stun:`, `stuns:`, `turn:`, or `turns:` URIs.
  final List<Uri> urls;

  /// TURN long-term-credential username (empty for STUN).
  final String username;

  /// TURN credential (empty for STUN). Deployments should prefer
  /// short-lived credentials minted by the config service.
  final String credential;

  static const _allowedSchemes = {'stun', 'stuns', 'turn', 'turns'};

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
class EndpointManifest {
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

  /// HTTPS base URI of the configuration service for the next refresh.
  final Uri configServiceUri;

  /// Minimum app version allowed to use these endpoints (semver string,
  /// enforced by the app shell; empty means no restriction).
  final String minimumAppVersion;

  EndpointManifest({
    this.schemaVersion = manifestSchemaVersion,
    required this.revision,
    required this.signingKeyId,
    required this.issuedAt,
    required this.expiresAt,
    required List<Uri> signalingEndpoints,
    required List<IceServerEntry> iceServers,
    required this.configServiceUri,
    this.minimumAppVersion = '',
  }) : signalingEndpoints = List.unmodifiable(signalingEndpoints),
       iceServers = List.unmodifiable(iceServers) {
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
    if (configServiceUri.scheme != 'https' || configServiceUri.host.isEmpty) {
      throw FormatException(
        'Config service URI must be https://, got: $configServiceUri',
      );
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
    final configService = json['configServiceUri'];
    final minAppVersion = json['minimumAppVersion'];

    if (schemaVersion is! int ||
        revision is! int ||
        signingKeyId is! String ||
        issuedAt is! String ||
        expiresAt is! String ||
        signaling is! List ||
        ice is! List ||
        configService is! String) {
      throw const FormatException('Manifest has missing or mistyped fields.');
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
      configServiceUri: Uri.parse(configService),
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
    'configServiceUri': configServiceUri.toString(),
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
