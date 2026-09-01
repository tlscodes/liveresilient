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
///   permanently stale manifest eventually forces an app update path;
/// - validity is always evaluated at an instant no earlier than the two
///   time floors ([embeddedTimeFloorUtc] baked into the binary, and the
///   persisted floor advanced by every acceptance), so a wound-back device
///   clock cannot resurrect documents from before those floors;
/// - a document whose ONLY defect is a time fact a wrong clock can
///   manufacture goes through one relaxation point,
///   [ManifestVerifier.verifyLenient] — on the persisted path and the
///   freshly-fetched path alike — and is then admitted only under the
///   bounded [_shouldAdoptStale] policy, never as fresh.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';

import 'endpoint_manifest.dart';
import 'manifest_verifier.dart';
import 'multi_origin_refresh.dart';

/// The in-binary time floor: the UTC instant this build was cut, written
/// as a source literal compiled into the binary.
///
/// HOW IT IS SET: updated in source at each release cut (by the release
/// checklist, or a release script stamping this line). It is data about
/// the BUILD, so it must never be read from the filesystem or a clock at
/// runtime — anything a device can influence after install is not a
/// floor. This value is the cut date of this package's v2.0.0 line. It
/// MUST never be set ahead of the true build instant: a future value
/// would expire genuinely valid documents on every device.
///
/// WHY IT EXISTS: a fresh install has no persisted time floor, so before
/// the first accepted document its only defense against a wound-back
/// device clock would be that same clock. This constant is the one time
/// fact a fresh binary already carries — real time is at least the moment
/// the build was cut. The cache evaluates validity at an instant never
/// earlier than this, so a document whose whole life (validity window
/// plus last-known-good grace) ended before the build existed is rejected
/// even when the device clock sits inside the document's window.
///
/// WHAT IT COSTS WHEN STALE: the replay window on fresh installs grows by
/// exactly this constant's age — a build cut N days ago cannot tell a
/// wound-back clock from a genuine one for documents newer than the cut.
/// Staleness never rejects a current document (the floor only moves the
/// evaluated instant forward, and it lies in the real past), so the cost
/// of neglect is weaker protection, not an outage. What it cannot detect:
/// a wrong clock AFTER the cut date; that is what the persisted floor,
/// advanced by every accepted document, is for.
final DateTime embeddedTimeFloorUtc = DateTime.utc(2026, 1, 1);

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

  // In-memory copy of the persisted time floor, loaded by [initialize]
  // and advanced by every acceptance, so [get] can derive the effective
  // instant synchronously. Null only means "not read yet / none
  // recorded"; the embedded floor applies regardless via
  // [_effectiveFloorUtc], so a fresh install is floored from the first
  // call.
  DateTime? _persistedFloorUtc;

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
  ///
  /// A persisted document whose only defect is a time fact goes through
  /// [ManifestVerifier.verifyLenient] — the same single relaxation point
  /// the freshly-fetched path uses — and is admitted only under
  /// [_shouldAdoptStale], so startup cannot resurrect a document the
  /// refresh path would refuse.
  Future<void> initialize() async {
    _persistedFloorUtc = await _storage.readTimeFloorUtc();
    final bytes = await _storage.readDocument();
    if (bytes == null) return;
    try {
      final document = SignedManifestDocument.fromBytes(bytes);
      final accepted = await _storage.readAcceptedRevision();
      final result = await _verifier.verifyLenient(
        document,
        lastAcceptedRevision: accepted,
        now: _clock(),
        persistedTimeFloorUtc: _effectiveFloorUtc(),
      );
      switch (result) {
        case LenientAccepted(:final manifest):
          _current = manifest;
        case LenientAcceptedStale(:final manifest, :final fault):
          final effectiveNow = _laterOf(_clock().toUtc(), _effectiveFloorUtc());
          if (_shouldAdoptStale(manifest, fault, effectiveNow)) {
            _current = manifest;
          }
        case LenientRejected():
          // Not authentic here and now (bad key or signature, malformed,
          // unsupported algorithm, or rollback): discarded; a network
          // refresh will replace it.
          break;
      }
    } on FormatException {
      // Corrupt persisted state: ignore; a network refresh will replace it.
    }
  }

  /// Returns the best available manifest, refreshing over the network when
  /// needed. Throws [ManifestUnavailable] when nothing trustworthy exists.
  ///
  /// Validity and grace are measured at the FLOORED instant (never earlier
  /// than the embedded and persisted time floors), so a wound-back device
  /// clock cannot make an old document look servable. The refresh
  /// cooldown, by contrast, is measured on the raw device clock: while
  /// the clock is behind the floor the floored instant stands still, and
  /// a standing clock would measure every interval as zero and disable
  /// refresh on exactly the devices that need it most.
  Future<CachedManifest> get({bool forceRefresh = false}) async {
    final deviceNow = _clock().toUtc();
    var now = _laterOf(deviceNow, _effectiveFloorUtc());
    final current = _current;

    final needsRefresh =
        forceRefresh || current == null || current.isExpiredAt(now);

    if (needsRefresh && _cooldownElapsed(deviceNow)) {
      try {
        await _refresh(deviceNow);
      } on Exception {
        // Swallowed: fallback logic below decides what we can still serve.
      }
      // A refresh can advance the persisted floor (an accepted document's
      // issuedAt may lie ahead of the device clock), so re-derive the
      // effective instant before judging freshness.
      now = _laterOf(deviceNow, _effectiveFloorUtc());
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

    if (now.isBefore(effective.expiresAt.add(config.lastKnownGoodGrace))) {
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
    _persistedFloorUtc = await _storage.readTimeFloorUtc();
    final floor = _effectiveFloorUtc();

    // Capture the bytes each origin served during the strict race, so the
    // lenient second pass can re-judge the SAME evidence without a second
    // network round (and without a stale origin ever outrunning a strictly
    // valid one — the strict race always gets the first claim).
    final fetchedBytes = <Uri, List<int>>{};
    Future<List<int>> capturingFetch(Uri uri) async {
      final bytes = await _fetch(uri);
      fetchedBytes[uri] = bytes;
      return bytes;
    }

    final MultiOriginRefreshException strictFailure;
    try {
      final result = await fetchVerifiedManifest(
        origins: origins,
        fetch: capturingFetch,
        verifier: _verifier,
        lastAcceptedRevision: accepted,
        now: now,
        persistedTimeFloorUtc: floor,
      );
      await _accept(
        result.manifest,
        result.documentBytes,
        lastAcceptedRevision: accepted,
      );
      return;
    } on MultiOriginRefreshException catch (error) {
      strictFailure = error;
    }

    await _lenientFallback(
      origins: origins,
      fetchedBytes: fetchedBytes,
      lastAcceptedRevision: accepted,
      now: now,
      floor: floor,
      strictFailure: strictFailure,
    );
  }

  /// The lenient second pass of a refresh: runs only after EVERY origin
  /// failed strict verification, and re-judges the bytes captured during
  /// the strict race through [ManifestVerifier.verifyLenient] — the same
  /// single relaxation point the persisted path uses.
  ///
  /// Origins are visited in list order; the first document that is
  /// authentic and admissible under [_shouldAdoptStale] is accepted.
  /// Origins whose fetch failed left no bytes and are skipped — their
  /// failure is already recorded in [strictFailure]. Throws
  /// [ManifestUnavailable] when nothing is admissible.
  Future<void> _lenientFallback({
    required List<Uri> origins,
    required Map<Uri, List<int>> fetchedBytes,
    required int lastAcceptedRevision,
    required DateTime now,
    required DateTime floor,
    required MultiOriginRefreshException strictFailure,
  }) async {
    final effectiveNow = _laterOf(now.toUtc(), floor);
    for (final origin in origins) {
      final bytes = fetchedBytes[origin];
      if (bytes == null) continue;
      final SignedManifestDocument document;
      try {
        document = SignedManifestDocument.fromBytes(bytes);
      } on FormatException {
        // Malformed bytes were already reported by the strict pass.
        continue;
      }
      final result = await _verifier.verifyLenient(
        document,
        lastAcceptedRevision: lastAcceptedRevision,
        now: now,
        persistedTimeFloorUtc: floor,
      );
      switch (result) {
        case LenientAccepted(:final manifest):
          // An origin can heal between the race and this pass only in
          // clock terms; a strict acceptance here is still a win.
          await _accept(
            manifest,
            bytes,
            lastAcceptedRevision: lastAcceptedRevision,
          );
          return;
        case LenientAcceptedStale(:final manifest, :final fault):
          if (_shouldAdoptStale(manifest, fault, effectiveNow)) {
            await _accept(
              manifest,
              bytes,
              lastAcceptedRevision: lastAcceptedRevision,
            );
            return;
          }
        case LenientRejected():
          // Not authentic (or a rollback): never admitted; next origin.
          break;
      }
    }
    throw ManifestUnavailable(
      'All origins failed strict verification and the lenient re-check '
      'admitted none: $strictFailure',
    );
  }

  /// Adoption policy for an authentic-but-time-faulted document — the ONE
  /// place it exists, shared by the persisted path ([initialize]) and the
  /// freshly-fetched path ([_lenientFallback]).
  ///
  /// notYetValid is adopted unconditionally: the document's window lies
  /// ahead of the evaluated instant, so [get]'s expiry checks bound its
  /// service naturally. expired is adopted only while inside the
  /// last-known-good grace measured at the FLOORED instant — which is
  /// what makes the embedded floor a real rejection on fresh installs: a
  /// document whose window plus grace ended before this build was cut is
  /// refused here, wound-back device clock or not.
  bool _shouldAdoptStale(
    EndpointManifest manifest,
    ManifestTimeFault fault,
    DateTime effectiveNow,
  ) => switch (fault) {
    ManifestTimeFault.notYetValid => true,
    ManifestTimeFault.expired => effectiveNow.isBefore(
      manifest.expiresAt.add(config.lastKnownGoodGrace),
    ),
  };

  /// Adopts a verified manifest: caches it in memory, then persists the
  /// document, the accepted revision (monotonic) and the time floor
  /// (monotonic). One function so the strict and lenient acceptance paths
  /// cannot diverge on what "accepted" persists.
  Future<void> _accept(
    EndpointManifest manifest,
    List<int> documentBytes, {
    required int lastAcceptedRevision,
  }) async {
    _current = manifest;
    await _storage.writeDocument(documentBytes);
    if (manifest.revision > lastAcceptedRevision) {
      await _storage.writeAcceptedRevision(manifest.revision);
    }
    // The time floor advances with acceptance, in the same step: it
    // becomes the greater of the current floor and the accepted
    // document's issuedAt (an authentic, signed statement that this
    // instant has existed), and never moves backwards.
    final issuedAtUtc = manifest.issuedAt.toUtc();
    final persisted = _persistedFloorUtc;
    if (persisted == null || issuedAtUtc.isAfter(persisted)) {
      await _storage.writeTimeFloorUtc(issuedAtUtc);
      _persistedFloorUtc = issuedAtUtc;
    }
  }

  /// The floor actually applied to validity: the later of the in-binary
  /// [embeddedTimeFloorUtc] and the persisted floor (when one has been
  /// recorded). Derived, never stored, so the two sources cannot drift.
  DateTime _effectiveFloorUtc() {
    final persisted = _persistedFloorUtc;
    if (persisted == null) return embeddedTimeFloorUtc;
    return _laterOf(embeddedTimeFloorUtc, persisted);
  }

  static DateTime _laterOf(DateTime a, DateTime b) => b.isAfter(a) ? b : a;
}
