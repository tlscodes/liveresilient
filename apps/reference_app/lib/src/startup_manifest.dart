/// Loading the endpoint manifest at startup — the last hop of the ICE fix.
///
/// WHY THIS FILE EXISTS. `buildRtcIceConfig` maps a manifest to peer-connection
/// ICE servers, `buildWebRtcCallSession` accepts the result, and both are
/// tested. Nothing produced a manifest, so the parameter stayed null, the
/// null-coalesce fired, and every call was still placed with `iceServers:
/// const []` — no STUN, no TURN. A mapper with no source is a mapper that
/// never runs.
///
/// WHAT THIS IS NOT. It is not the signed-config refresh client: fetching,
/// verifying and rolling over signed manifests belongs to `signed_config` and
/// its cache, and inventing a second fetch path here would create two sources
/// of truth for the same document. This is the seam that hands whatever the
/// config layer already trusts to the call builder, plus a documented
/// development fallback so a dev build is not silently STUN-less.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signed_config/signed_config.dart';

/// Where a manifest came from. Logged and shown in dev builds, because
/// "which ICE servers am I actually using" is the first question when a call
/// fails to connect and the last one anybody can answer today.
enum ManifestSource {
  /// Verified signed manifest from the config layer.
  signedConfig,

  /// Imported out of band — a scanned code, a pasted string, a sideloaded
  /// file — and verified by the SAME rules as the network path. This is the
  /// rung that works when the config origins are unreachable, which is the
  /// only case where a fresh install has nothing at all.
  outOfBand,

  /// A JSON file named by `ENDPOINT_MANIFEST_FILE`, for local development and
  /// device testing against a private relay.
  localFile,

  /// Public STUN only. Honest last resort: it fixes symmetric-NAT discovery
  /// but cannot relay, so calls behind a strict firewall still fail.
  publicStunFallback,

  /// Nothing available. Direct paths only — the pre-fix behaviour, now
  /// reported instead of silent.
  none,
}

class StartupManifest {
  const StartupManifest(this.manifest, this.source, {this.failure});

  final EndpointManifest? manifest;
  final ManifestSource source;

  /// What went wrong on a rung that was TRIED and did not work.
  ///
  /// Distinct from "not configured". A developer who typos
  /// `ENDPOINT_MANIFEST_FILE` used to be silently downgraded to public STUN and
  /// told "discovery works, relaying does not" — a true sentence about the
  /// wrong situation. The failure was caught by `catch (_)` and discarded, so
  /// `describe()` was structurally incapable of reporting the thing it existed
  /// to report. Now it is carried.
  final String? failure;

  bool get hasIceServers => (manifest?.iceServers.isNotEmpty) ?? false;

  String describe() {
    final base = _describeSource();
    return failure == null ? base : '$base — but note: $failure';
  }

  String _describeSource() => switch (source) {
    ManifestSource.signedConfig =>
      'signed manifest rev ${manifest?.revision}, '
          '${manifest?.iceServers.length} ICE servers',
    ManifestSource.outOfBand =>
      'out-of-band manifest rev ${manifest?.revision}, '
          '${manifest?.iceServers.length} ICE servers '
          '(same verification as the network path)',
    ManifestSource.localFile =>
      'local manifest file, ${manifest?.iceServers.length} ICE servers',
    ManifestSource.publicStunFallback =>
      'public STUN fallback: discovery works, relaying does not',
    ManifestSource.none => 'no manifest: host candidates only',
  };
}

/// Resolves the manifest to use for this process.
///
/// Order: whatever the config layer already verified, then a developer file,
/// then public STUN, then nothing. Each step down is reported rather than
/// assumed, because the difference between them is the difference between a
/// call that connects on a hostile network and one that does not.
///
/// [verifiedManifest] is supplied by the caller that owns the signed-config
/// cache; passing null means "the config layer has nothing yet".
Future<StartupManifest> loadStartupManifest({
  EndpointManifest? verifiedManifest,
  EndpointManifest? outOfBandManifest,
  Map<String, String>? environment,
  bool allowPublicStunFallback = true,
}) async {
  if (verifiedManifest != null && verifiedManifest.iceServers.isNotEmpty) {
    return StartupManifest(verifiedManifest, ManifestSource.signedConfig);
  }

  // Ranked above the dev file and below the network cache on purpose: an
  // out-of-band manifest is a deliberate act by the user, so it outranks a
  // stale environment variable, but it does not override a newer verified
  // manifest the device already holds.
  if (outOfBandManifest != null && outOfBandManifest.iceServers.isNotEmpty) {
    return StartupManifest(outOfBandManifest, ManifestSource.outOfBand);
  }

  final env = environment ?? Platform.environment;
  final path = env['ENDPOINT_MANIFEST_FILE'];
  String? fileFailure;
  if (path != null && path.isNotEmpty) {
    try {
      final raw = await File(path).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        final parsed = EndpointManifest.fromJson(decoded);
        return StartupManifest(parsed, ManifestSource.localFile);
      }
      fileFailure = '$path is JSON but not a manifest object';
    } on Object catch (e) {
      // Still not fatal — a bad dev file must not take the app down — but the
      // reason travels with the result instead of vanishing. Configuring a
      // rung and having it fail is a different situation from not configuring
      // it, and the two call for opposite fixes.
      fileFailure = '$path could not be used: $e';
    }
  }

  if (allowPublicStunFallback) {
    final stun = _publicStunManifest();
    if (stun != null) {
      return StartupManifest(
        stun,
        ManifestSource.publicStunFallback,
        failure: fileFailure,
      );
    }
  }

  return StartupManifest(null, ManifestSource.none, failure: fileFailure);
}

/// A minimal STUN-only manifest.
///
/// STUN alone cannot relay, so this does not rescue a call behind a symmetric
/// NAT on both sides — it only restores server-reflexive candidate discovery,
/// which is still the difference between "sometimes connects" and "connects
/// whenever a direct path exists at all". TURN requires credentials, which by
/// definition cannot be hardcoded.
EndpointManifest? _publicStunManifest() {
  try {
    final now = DateTime.now().toUtc();
    return EndpointManifest(
      revision: 1,
      signingKeyId: 'public-stun-fallback',
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
      signalingEndpoints: [Uri.parse('wss://localhost:4443')],
      iceServers: [
        IceServerEntry(urls: [Uri.parse('stun:stun.l.google.com:19302')]),
      ],
      configServiceUris: [Uri.parse('https://localhost/config')],
    );
  } catch (_) {
    // Manifest validation is strict by design; if a future rule rejects this
    // shape, degrade to "none" rather than crashing at startup.
    return null;
  }
}

/// The startup retrieval rule — bounds on fetching the policy document.
///
/// WHY A SEPARATE RULE. The admission rule elsewhere in the app refuses to
/// start a session when measured conditions cannot meet a promised quality
/// property, and it takes its thresholds and candidate settings from the very
/// manifest this file resolves. Retrieval of that manifest therefore cannot
/// run under the admission rule: a gate cannot be the gatekeeper of fetching
/// its own definition. Retrieval runs under THIS rule instead.
///
/// WHY THESE CONSTANTS MAY BE COMPILED IN. The admission thresholds must
/// never be hardcoded — they define a quality promise and live in the signed
/// document precisely so they can change without a release. These bounds are
/// different in kind: they promise no quality property at all, they only cap
/// the time and effort spent during bootstrap, when no promise has been
/// offered to any caller yet. A compiled-in "give up after N attempts or T
/// seconds" cannot silently weaken a promise that does not yet exist. Do not
/// mistake these constants for the thing that must not be hardcoded.
class StartupRetrievalPolicy {
  const StartupRetrievalPolicy({
    this.attemptDeadline = const Duration(seconds: 5),
    this.totalDeadline = const Duration(seconds: 20),
    this.maxAttempts = 3,
  });

  /// How long a single resolution attempt may run before it is cut off and
  /// counted as a failed attempt.
  final Duration attemptDeadline;

  /// Cap on the whole retrieval, across all attempts. When the clock passes
  /// this, retrieval stops even if attempts remain.
  final Duration totalDeadline;

  /// Cap on the number of resolution attempts.
  final int maxAttempts;

  /// The compiled-in defaults: at most 3 attempts of at most 5 seconds each,
  /// at most 20 seconds overall.
  static const StartupRetrievalPolicy defaults = StartupRetrievalPolicy();
}

/// Where startup currently stands. Carried on every refusal, because "still
/// retrieving" and "gave up" call for opposite reactions from a caller —
/// wait, versus surface the failure.
enum StartupPhase {
  /// Retrieval has not been started.
  notStarted,

  /// Retrieval is running under [StartupRetrievalPolicy].
  retrieving,

  /// A usable manifest is in hand; callers may proceed.
  ready,

  /// A bound of [StartupRetrievalPolicy] was hit before a manifest was in
  /// hand. The recorded failure names which one.
  budgetExhausted,
}

/// Thrown when a bound of [StartupRetrievalPolicy] is hit.
///
/// Loud on purpose: reaching a cap is never an unbounded retry and never a
/// silent fall to the next rung. [cap] names which bound was hit and its
/// configured value; [attemptFailures] carries what each attempt reported,
/// so the answer to "why is there no manifest" travels with the failure
/// instead of having to be reconstructed from logs.
class StartupBudgetExceeded implements Exception {
  const StartupBudgetExceeded(this.cap, this.attemptsMade, this.attemptFailures);

  /// Which bound was hit, with its value — e.g. 'maxAttempts (3)' or
  /// 'totalDeadline (0:00:20.000000)'.
  final String cap;

  /// Attempts actually made before the cap stopped retrieval.
  final int attemptsMade;

  /// One line per failed attempt, in order.
  final List<String> attemptFailures;

  @override
  String toString() =>
      'StartupBudgetExceeded: $cap hit after $attemptsMade attempt(s)'
      '${attemptFailures.isEmpty ? '' : ' — ${attemptFailures.join('; ')}'}';
}

/// The explicit refusal a caller receives for asking to proceed before a
/// usable manifest is in hand. It names the startup state rather than letting
/// a call run without policy.
class StartupNotReady implements Exception {
  const StartupNotReady(this.phase, [this.detail]);

  final StartupPhase phase;
  final String? detail;

  @override
  String toString() =>
      'StartupNotReady: no usable manifest held (state: ${phase.name}'
      '${detail == null ? '' : ' — $detail'})';
}

/// The bootstrap gate: runs retrieval under [StartupRetrievalPolicy] and
/// refuses every caller until a current document is in hand.
///
/// CACHED OLDER DOCUMENTS: this gate consumes none. The only cache in the
/// system is the signed-config cache, owned by `signed_config` and by the
/// caller that passes `verifiedManifest` into [loadStartupManifest] — what
/// arrives here is already verified and already current by that layer's
/// rules. If a stale-document path is ever added HERE, it must carry an
/// explicit age and a stated staleness cap, and a stale document must never
/// be reported as equivalent to a current one. Until such a path exists,
/// this comment is the whole of that machinery.
class StartupManifestGate {
  StartupManifestGate({this.policy = StartupRetrievalPolicy.defaults});

  /// The compiled-in bounds this gate runs under.
  final StartupRetrievalPolicy policy;

  StartupPhase _phase = StartupPhase.notStarted;
  StartupManifest? _held;
  String? _terminalFailure;

  /// Where startup currently stands.
  StartupPhase get phase => _phase;

  /// TRUE exactly when a usable document is in hand — [retrieve] completed
  /// and produced a manifest. This is the predicate a caller checks before
  /// asking to be admitted.
  bool get holdsUsableManifest =>
      _phase == StartupPhase.ready && _held?.manifest != null;

  /// The admission point for the bootstrap phase.
  ///
  /// While no usable document is held, this throws [StartupNotReady] naming
  /// the current state — the call is refused explicitly, never attempted
  /// without policy.
  StartupManifest requireManifest() {
    final held = _held;
    if (held != null && holdsUsableManifest) return held;
    throw StartupNotReady(_phase, _terminalFailure);
  }

  /// Runs [attemptOnce] under the policy's bounds until it produces a
  /// manifest or a cap is hit.
  ///
  /// [attemptOnce] is typically `() => loadStartupManifest(...)` closed over
  /// the config layer's current state — a callback, so a later attempt can
  /// see a fetch the config layer completed in the meantime, and so this
  /// file still contains no second fetch path of its own.
  ///
  /// Bounds enforced, in the order they can fire:
  ///   - a single attempt is cut off at [StartupRetrievalPolicy.attemptDeadline]
  ///     (or at whatever remains of the total budget, if less) and counted as
  ///     a failed attempt, with the cut recorded;
  ///   - retrieval stops when [StartupRetrievalPolicy.totalDeadline] is spent
  ///     or [StartupRetrievalPolicy.maxAttempts] attempts have failed,
  ///     whichever comes first, by throwing [StartupBudgetExceeded] naming
  ///     the cap that was hit. No cap ever falls silently to another rung.
  ///
  /// An attempt that completes but yields [ManifestSource.none] counts as a
  /// failed attempt, reported with what the ladder itself said; any other
  /// rung that produced a manifest is accepted, preserving the existing
  /// ladder order and its reporting unchanged.
  Future<StartupManifest> retrieve(
    Future<StartupManifest> Function() attemptOnce,
  ) async {
    _phase = StartupPhase.retrieving;
    _terminalFailure = null;
    final clock = Stopwatch()..start();
    final attemptFailures = <String>[];

    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      final remaining = policy.totalDeadline - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw _exhausted(
          'totalDeadline (${policy.totalDeadline})',
          attempt - 1,
          attemptFailures,
        );
      }
      final deadline = remaining < policy.attemptDeadline
          ? remaining
          : policy.attemptDeadline;
      try {
        final result = await attemptOnce().timeout(deadline);
        if (result.manifest != null) {
          _held = result;
          _phase = StartupPhase.ready;
          return result;
        }
        attemptFailures.add('attempt $attempt: ${result.describe()}');
      } on TimeoutException {
        attemptFailures.add('attempt $attempt: attemptDeadline ($deadline) hit');
      } on Object catch (e) {
        attemptFailures.add('attempt $attempt: $e');
      }
    }
    throw _exhausted(
      'maxAttempts (${policy.maxAttempts})',
      policy.maxAttempts,
      attemptFailures,
    );
  }

  /// Records the terminal state, then returns the failure for the caller to
  /// throw — so a later [requireManifest] refusal names the same cap.
  StartupBudgetExceeded _exhausted(
    String cap,
    int attemptsMade,
    List<String> attemptFailures,
  ) {
    final failure = StartupBudgetExceeded(
      cap,
      attemptsMade,
      List.unmodifiable(attemptFailures),
    );
    _phase = StartupPhase.budgetExhausted;
    _terminalFailure = failure.toString();
    return failure;
  }
}
