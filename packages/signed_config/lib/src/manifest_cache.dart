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
import 'multi_origin_refresh.dart';

/// Durable storage for the last accepted manifest document and revision.
abstract interface class ManifestStorage {
  /// Returns the persisted signed document bytes, or null when absent.
  Future<List<int>?> readDocument();

  Future<void> writeDocument(List<int> bytes);

  /// Highest revision ever accepted on this device (0 when none).
  Future<int> readAcceptedRevision();

  Future<void> writeAcceptedRevision(int revision);

  /// The persisted time floor (`persistedTimeFloorUtc`): the latest
  /// `issuedAt` of any document ever accepted on this device, in UTC, or
  /// null when none has been recorded yet. Kept in the same storage as the
  /// accepted revision because the two are always read together and must
  /// advance together — splitting them across stores would permit a
  /// half-write where one advances and the other does not.
  Future<DateTime?> readTimeFloorUtc();

  /// Advances the persisted time floor. Contract: [value] must be UTC
  /// (implementations reject a non-UTC instant), and the floor is
  /// monotonic — a write older than the stored floor is ignored, so the
  /// floor never moves backwards.
  Future<void> writeTimeFloorUtc(DateTime value);
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

final class CachedManifest {
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

final class ManifestUnavailable implements Exception {
  final String message;
  const ManifestUnavailable(this.message);

  @override
  String toString() => 'ManifestUnavailable: $message';
}

class ManifestCache {
  final ManifestVerifier _verifier;
  final ManifestStorage _storage;
  final ManifestFetcher _fetch;
  final List<Uri> _bootstrapUris;
  final ManifestCacheConfig config;
  final DateTime Function() _clock;

  EndpointManifest? _current;
  DateTime? _lastRefreshAttempt;
  Future<void>? _inflightRefresh;

  ManifestCache({
    required ManifestVerifier verifier,
    required ManifestStorage storage,
    required ManifestFetcher fetcher,

    /// Single-origin convenience: equivalent to `bootstrapUris: [uri]`.
    /// Exactly one of [bootstrapUri] / [bootstrapUris] must be provided.
    Uri? bootstrapUri,

    /// HTTPS URIs baked into the app build for the first fetch, tried in
    /// order. Later refreshes prefer the manifest's own `configServiceUris`
    /// (all of them, in order — per-origin failover).
    List<Uri>? bootstrapUris,
    this.config = const ManifestCacheConfig(),
    DateTime Function()? clock,
  }) : _verifier = verifier,
       _storage = storage,
       _fetch = fetcher,
       _bootstrapUris = List.unmodifiable([
         if (bootstrapUri != null) bootstrapUri,
         ...?bootstrapUris,
       ]),
       _clock = clock ?? DateTime.now {
    if ((bootstrapUri == null) == (bootstrapUris == null)) {
      throw ArgumentError(
        'Provide exactly one of bootstrapUri / bootstrapUris.',
      );
    }
    if (_bootstrapUris.isEmpty) {
      throw ArgumentError.value(
        bootstrapUris,
        'bootstrapUris',
        'At least one bootstrap URI is required.',
      );
    }
    for (final uri in _bootstrapUris) {
      if (uri.scheme != 'https') {
        throw ArgumentError.value(
          uri,
          'bootstrapUri',
          'Manifest bootstrap URIs must be https.',
        );
      }
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
      final timeFloor = await _storage.readTimeFloorUtc();
      final result = await _verifier.verify(
        document,
        lastAcceptedRevision: accepted,
        now: _clock(),
        persistedTimeFloorUtc: timeFloor,
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

    final needsRefresh =
        forceRefresh || current == null || current.isExpiredAt(now);

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

    // Candidate origins: the current manifest's own configServiceUris (all,
    // in order) when a manifest exists, else the baked-in bootstrap list.
    // Origins are tried sequentially with per-origin failure isolation —
    // a tampering/unreachable origin never blocks a healthy later one.
    final origins = _current?.configServiceUris ?? _bootstrapUris;
    final accepted = await _storage.readAcceptedRevision();
    final timeFloor = await _storage.readTimeFloorUtc();

    final MultiOriginRefreshResult result;
    try {
      result = await fetchVerifiedManifest(
        origins: origins,
        fetch: _fetch,
        verifier: _verifier,
        lastAcceptedRevision: accepted,
        now: now,
        persistedTimeFloorUtc: timeFloor,
      );
    } on MultiOriginRefreshException catch (error) {
      throw ManifestUnavailable(error.toString());
    }

    _current = result.manifest;
    await _storage.writeDocument(result.documentBytes);
    if (result.manifest.revision > accepted) {
      await _storage.writeAcceptedRevision(result.manifest.revision);
    }
    // The time floor advances with the accepted revision, in the same step:
    // it becomes the greater of the current floor and the accepted
    // document's issuedAt, and never moves backwards.
    final issuedAtUtc = result.manifest.issuedAt.toUtc();
    if (timeFloor == null || issuedAtUtc.isAfter(timeFloor)) {
      await _storage.writeTimeFloorUtc(issuedAtUtc);
    }
  }
}
