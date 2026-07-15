/// Verified-manifest cache with last-known-good fallback.
///
/// Policy:
/// - only manifests that passed [ManifestVerifier] enter the cache;
/// - the accepted revision is monotonic (rollback protection persists
///   across restarts via [ManifestStorage]);
/// - a fresh manifest is served while inside its validity window;
/// - when refresh fails and the cached manifest has expired, the cache can
///   still serve it as **last-known-good** for a bounded grace period, so a
///   temporary config-service outage does not brick calling — while a
///   permanently stale manifest eventually forces an app update path.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';

import 'endpoint_manifest.dart';
import 'manifest_verifier.dart';

/// Durable storage for the last accepted manifest document and revision.
abstract interface class ManifestStorage {
  /// Returns the persisted signed document bytes, or null when absent.
  Future<List<int>?> readDocument();

  Future<void> writeDocument(List<int> bytes);

  /// Highest revision ever accepted on this device (0 when none).
  Future<int> readAcceptedRevision();

  Future<void> writeAcceptedRevision(int revision);
}

/// Fetches the signed manifest document bytes over HTTPS from the given
/// URI. Implemented in the app layer with the platform HTTP client;
/// implementations must follow redirects only to https URIs.
typedef ManifestFetcher = Future<List<int>> Function(Uri uri);

enum ManifestFreshness {
  /// Inside its validity window.
  fresh,

  /// Expired, served under the last-known-good grace policy.
  lastKnownGood,
}

class CachedManifest {
  final EndpointManifest manifest;
  final ManifestFreshness freshness;
  const CachedManifest(this.manifest, this.freshness);
}

class ManifestCacheConfig {
  /// How long after expiry a last-known-good manifest may still be served.
  final Duration lastKnownGoodGrace;

  /// Minimum interval between network refresh attempts.
  final Duration refreshCooldown;

  const ManifestCacheConfig({
    this.lastKnownGoodGrace = const Duration(days: 7),
    this.refreshCooldown = const Duration(minutes: 5),
  });
}

class ManifestUnavailable implements Exception {
  final String message;
  const ManifestUnavailable(this.message);

  @override
  String toString() => 'ManifestUnavailable: $message';
}

class ManifestCache {
  final ManifestVerifier _verifier;
  final ManifestStorage _storage;
  final ManifestFetcher _fetch;
  final Uri _bootstrapUri;
  final ManifestCacheConfig config;
  final DateTime Function() _clock;

  EndpointManifest? _current;
  DateTime? _lastRefreshAttempt;
  Future<void>? _inflightRefresh;

  ManifestCache({
    required ManifestVerifier verifier,
    required ManifestStorage storage,
    required ManifestFetcher fetcher,

    /// HTTPS URI baked into the app build for the first fetch; later
    /// refreshes prefer the manifest's own `configServiceUri`.
    required Uri bootstrapUri,
    this.config = const ManifestCacheConfig(),
    DateTime Function()? clock,
  })  : _verifier = verifier,
        _storage = storage,
        _fetch = fetcher,
        _bootstrapUri = bootstrapUri,
        _clock = clock ?? DateTime.now {
    if (bootstrapUri.scheme != 'https') {
      throw ArgumentError.value(
        bootstrapUri,
        'bootstrapUri',
        'Manifest bootstrap URI must be https.',
      );
    }
  }

  /// Loads the persisted manifest (if any) into memory. Call once on
  /// startup before [get].
  Future<void> initialize() async {
    final bytes = await _storage.readDocument();
    if (bytes == null) return;
    try {
      final document = SignedManifestDocument.fromBytes(bytes);
      final accepted = await _storage.readAcceptedRevision();
      final result = await _verifier.verify(
        document,
        lastAcceptedRevision: accepted,
        now: _clock(),
      );
      switch (result) {
        case ManifestAccepted(:final manifest):
          _current = manifest;
        case ManifestRejected(:final reason):
          // An expired-but-authentic persisted manifest is still eligible
          // for last-known-good service; anything else is discarded.
          if (reason == ManifestRejection.expired) {
            final relaxed = await _verifier.verify(
              document,
              lastAcceptedRevision: accepted,
              // Verify authenticity as of its own issue time.
              now: EndpointManifest.fromJson(document.manifestJson).issuedAt,
            );
            if (relaxed is ManifestAccepted) {
              _current = relaxed.manifest;
            }
          }
      }
    } on FormatException {
      // Corrupt persisted state: ignore; a network refresh will replace it.
    }
  }

  /// Returns the best available manifest, refreshing over the network when
  /// needed. Throws [ManifestUnavailable] when nothing trustworthy exists.
  Future<CachedManifest> get({bool forceRefresh = false}) async {
    final now = _clock().toUtc();
    final current = _current;

    final needsRefresh = forceRefresh ||
        current == null ||
        current.isExpiredAt(now);

    if (needsRefresh && _cooldownElapsed(now)) {
      try {
        await _refresh(now);
      } on Exception {
        // Swallowed: fallback logic below decides what we can still serve.
      }
    }

    final effective = _current;
    if (effective == null) {
      throw const ManifestUnavailable(
        'No verified manifest is available and refresh failed.',
      );
    }

    if (!effective.isExpiredAt(now)) {
      return CachedManifest(effective, ManifestFreshness.fresh);
    }

    final graceEnd = effective.expiresAt.add(config.lastKnownGoodGrace);
    if (now.isBefore(graceEnd)) {
      return CachedManifest(effective, ManifestFreshness.lastKnownGood);
    }

    throw const ManifestUnavailable(
      'Cached manifest is beyond the last-known-good grace period.',
    );
  }

  int? get currentRevision => _current?.revision;

  bool _cooldownElapsed(DateTime now) {
    final last = _lastRefreshAttempt;
    return last == null || now.difference(last) >= config.refreshCooldown;
  }

  Future<void> _refresh(DateTime now) {
    // Coalesce concurrent refreshes into one network fetch.
    return _inflightRefresh ??= _doRefresh(now).whenComplete(() {
      _inflightRefresh = null;
    });
  }

  Future<void> _doRefresh(DateTime now) async {
    _lastRefreshAttempt = now;

    final uri = _current?.configServiceUri ?? _bootstrapUri;
    final bytes = await _fetch(uri);
    final document = SignedManifestDocument.fromBytes(bytes);
    final accepted = await _storage.readAcceptedRevision();

    final result = await _verifier.verify(
      document,
      lastAcceptedRevision: accepted,
      now: now,
    );

    switch (result) {
      case ManifestAccepted(:final manifest):
        _current = manifest;
        await _storage.writeDocument(bytes);
        if (manifest.revision > accepted) {
          await _storage.writeAcceptedRevision(manifest.revision);
        }
      case ManifestRejected(:final reason, :final detail):
        throw ManifestUnavailable(
          'Fetched manifest rejected (${reason.name}): $detail',
        );
    }
  }
}
