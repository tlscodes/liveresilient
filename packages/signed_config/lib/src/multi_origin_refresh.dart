/// Staggered-parallel multi-origin manifest refresh (Happy Eyeballs
/// pattern) with per-origin failure isolation.
///
/// Phase-7 exit gate: a failure (network error, tampered bytes, or a
/// verification rejection such as rollback) on origin k must never block a
/// healthy origin k+1. This helper races the candidate origins with a
/// staggered start — origin i launches `i * staggerDelay` after origin 0,
/// or immediately once every already-started origin has failed — and
/// returns the first manifest that passes [ManifestVerifier]. It aggregates
/// per-origin failures and throws only when every origin has failed.
///
/// Kept free of cache state (single-flight, cooldown, grace) on purpose —
/// that policy lives in `manifest_cache.dart`; this file owns only the
/// "race origins, first verified winner" step, so it can be unit tested in
/// isolation.
library;

import 'dart:async';

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
  /// Per-origin failure detail, in the order the origins were listed.
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

/// Default stagger between successive origin launches.
const Duration defaultOriginStaggerDelay = Duration(milliseconds: 250);

/// Races [origins] with staggered starts (Happy Eyeballs); returns the
/// first VERIFIED-ACCEPTED manifest.
///
/// Origin 0 starts immediately; origin i starts after `i * [staggerDelay]`,
/// or as soon as every origin started so far has failed (so a fast failure
/// never waits out the stagger). A fetch failure, malformed document, or
/// verification rejection on one origin is recorded and does not block the
/// others (per-origin isolation). The first [ManifestAccepted] wins;
/// still-running attempts are abandoned — their late results and errors are
/// discarded. Origins whose stagger has not elapsed when a winner lands are
/// never fetched at all.
///
/// Throws [MultiOriginRefreshException] (failures in origin-list order)
/// only when ALL origins fail; throws [ArgumentError] when [origins] is
/// empty.
///
/// Only [Exception]s from [fetch] are treated as origin failures — an
/// [Error] (a programming bug, not a network condition) propagates, unless
/// a winner has already been delivered.
Future<MultiOriginRefreshResult> fetchVerifiedManifest({
  required List<Uri> origins,
  required Future<List<int>> Function(Uri uri) fetch,
  required ManifestVerifier verifier,
  required int lastAcceptedRevision,
  required DateTime now,
  Duration staggerDelay = defaultOriginStaggerDelay,
}) {
  if (origins.isEmpty) {
    throw ArgumentError.value(
      origins,
      'origins',
      'At least one manifest origin is required.',
    );
  }

  final outer = Completer<MultiOriginRefreshResult>();
  // Failure slots keyed by origin index so the aggregate exception reports
  // in origin-list order regardless of completion order.
  final failureSlots = List<OriginFailure?>.filled(origins.length, null);
  var startedCount = 0;
  var failedCount = 0;
  // Completed to release the starter early: either every started attempt
  // has failed (launch the next origin now) or the outer future settled
  // (let the starter exit instead of waiting out a dangling stagger).
  var wakeSignal = Completer<void>();

  void wakeStarter() {
    if (!wakeSignal.isCompleted) wakeSignal.complete();
  }

  void settleWithResult(MultiOriginRefreshResult result) {
    if (outer.isCompleted) return;
    outer.complete(result);
    wakeStarter();
  }

  void settleWithError(Object error, [StackTrace? stack]) {
    if (outer.isCompleted) return;
    outer.completeError(error, stack);
    wakeStarter();
  }

  void recordFailure(int index, String reason) {
    failureSlots[index] = OriginFailure(origins[index], reason);
    failedCount++;
    if (failedCount == origins.length) {
      settleWithError(
        MultiOriginRefreshException(
          failureSlots.whereType<OriginFailure>().toList(),
        ),
      );
    } else if (failedCount == startedCount) {
      wakeStarter();
    }
  }

  Future<void> attempt(int index) async {
    final origin = origins[index];
    try {
      final List<int> bytes;
      final SignedManifestDocument document;
      try {
        bytes = await fetch(origin);
        document = SignedManifestDocument.fromBytes(bytes);
      } on Exception catch (error) {
        if (outer.isCompleted) return;
        recordFailure(index, error.toString());
        return;
      }

      final result = await verifier.verify(
        document,
        lastAcceptedRevision: lastAcceptedRevision,
        now: now,
      );
      if (outer.isCompleted) return;
      switch (result) {
        case ManifestAccepted(:final manifest):
          settleWithResult(
            MultiOriginRefreshResult(manifest: manifest, documentBytes: bytes),
          );
        case ManifestRejected(:final reason, :final detail):
          recordFailure(index, 'rejected (${reason.name}): $detail');
      }
    } catch (error, stack) {
      // Non-Exception Error: a programming bug — propagate it, unless a
      // winner already settled the race (abandoned attempts stay silent).
      settleWithError(error, stack);
    }
  }

  Future<void> starter() async {
    for (var index = 0; index < origins.length; index++) {
      if (index > 0) {
        await Future.any<void>([
          Future<void>.delayed(staggerDelay),
          wakeSignal.future,
        ]);
      }
      if (outer.isCompleted) return;
      // Reset BEFORE launching so a fast synchronous-in-microtask failure
      // of attempt(index) lands on the signal the next iteration awaits —
      // no lost wakeups.
      wakeSignal = Completer<void>();
      startedCount++;
      unawaited(attempt(index));
    }
  }

  unawaited(starter());
  return outer.future;
}
