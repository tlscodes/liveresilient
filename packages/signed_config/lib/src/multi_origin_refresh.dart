/// Sequential multi-origin manifest refresh with per-origin failure
/// isolation.
///
/// Phase-7 exit gate: a failure (network error, tampered bytes, or a
/// verification rejection such as rollback) on origin k must never block a
/// healthy origin k+1. This helper tries each candidate origin in order and
/// returns the first manifest that passes [ManifestVerifier]; it aggregates
/// per-origin failures and throws only when every origin has failed.
///
/// Kept free of cache state (single-flight, cooldown, grace) on purpose —
/// that policy lives in `manifest_cache.dart`; this file owns only the
/// "try origins in order, first verified winner" step, so it can be unit
/// tested in isolation.
library;

import 'endpoint_manifest.dart';
import 'manifest_verifier.dart';

/// One failed origin attempt inside a multi-origin refresh pass.
class OriginFailure {
  /// The config-service origin that failed.
  final Uri origin;

  /// Human-readable reason (fetch error or verification rejection detail).
  final String reason;

  const OriginFailure(this.origin, this.reason);

  @override
  String toString() => '$origin: $reason';
}

/// Thrown when every candidate origin failed to yield a verified manifest.
class MultiOriginRefreshException implements Exception {
  /// Per-origin failure detail, in the order the origins were tried.
  final List<OriginFailure> failures;

  MultiOriginRefreshException(List<OriginFailure> failures)
    : failures = List.unmodifiable(failures);

  @override
  String toString() =>
      'MultiOriginRefreshException: all ${failures.length} origin(s) '
      'failed: ${failures.join('; ')}';
}

/// A verified manifest together with the exact signed bytes it was decoded
/// from, so the caller can persist the original document verbatim.
class MultiOriginRefreshResult {
  final EndpointManifest manifest;
  final List<int> documentBytes;

  const MultiOriginRefreshResult({
    required this.manifest,
    required this.documentBytes,
  });
}

/// Tries [origins] sequentially; returns the first VERIFIED-ACCEPTED
/// manifest. A fetch failure, malformed document, or verification rejection
/// on one origin is recorded and the next origin is tried (per-origin
/// isolation). Throws [MultiOriginRefreshException] only when ALL origins
/// fail; throws [ArgumentError] when [origins] is empty.
///
/// Only [Exception]s from [fetch] are treated as origin failures — an
/// [Error] (a programming bug, not a network condition) propagates.
Future<MultiOriginRefreshResult> fetchVerifiedManifest({
  required List<Uri> origins,
  required Future<List<int>> Function(Uri uri) fetch,
  required ManifestVerifier verifier,
  required int lastAcceptedRevision,
  required DateTime now,
}) async {
  if (origins.isEmpty) {
    throw ArgumentError.value(
      origins,
      'origins',
      'At least one manifest origin is required.',
    );
  }

  final failures = <OriginFailure>[];
  for (final origin in origins) {
    final SignedManifestDocument document;
    final List<int> bytes;
    try {
      bytes = await fetch(origin);
      document = SignedManifestDocument.fromBytes(bytes);
    } on Exception catch (error) {
      failures.add(OriginFailure(origin, error.toString()));
      continue;
    }

    final result = await verifier.verify(
      document,
      lastAcceptedRevision: lastAcceptedRevision,
      now: now,
    );
    switch (result) {
      case ManifestAccepted(:final manifest):
        return MultiOriginRefreshResult(
          manifest: manifest,
          documentBytes: bytes,
        );
      case ManifestRejected(:final reason, :final detail):
        failures.add(
          OriginFailure(origin, 'rejected (${reason.name}): $detail'),
        );
    }
  }
  throw MultiOriginRefreshException(failures);
}
