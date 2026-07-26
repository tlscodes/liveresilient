/// Inbound flow control for link message processing (blueprint §8.3 gaps:
/// per-peer quota, global rate limit, message priority).
///
/// Implemented as a wrapper around [LinkMessageProcessor] rather than a
/// rewrite, so the existing processor semantics — TTL bounds, signature
/// verification, duplicate suppression, and the off-by-default
/// `forwardingEnabled` kill-switch — are untouched. A message only reaches
/// the inner processor after it clears the peer quota and the global rate
/// limiter; everything after admission behaves exactly as before.
///
/// All decisions are driven by caller-supplied `nowMs` (deterministic under
/// a fake clock) and all state is bounded.
library;

import 'dart:collection';

import 'media_frame.dart';

/// Message classes in ascending importance. Under load the limiter drops
/// lower classes first: `bulk` before `presence` before `callSignal`.
enum LinkMessagePriority { bulk, presence, callSignal }

/// Validated knobs for [GuardedLinkProcessor]. Defaults are conservative.
class LinkFlowControlConfig {
  /// Sliding-window length for the per-peer quota.
  final int perPeerWindowMs;

  /// Maximum admitted messages per peer within [perPeerWindowMs].
  final int maxMessagesPerPeerPerWindow;

  /// Sustained global inbound rate (token-bucket refill, messages/second).
  final int maxGlobalMessagesPerSecond;

  /// Extra bucket headroom above the sustained rate (burst allowance).
  final int burstAllowance;

  /// Upper bound on distinct peers tracked by the quota window
  /// (least-recently-active peers are evicted beyond this).
  final int maxTrackedPeers;

  /// Fraction of bucket capacity reserved per priority step: a message may
  /// only spend a token while the bucket holds more than
  /// `capacity * fraction * (stepsBelowTop)` tokens. With the default 0.2,
  /// `bulk` is dropped once the bucket falls below 40% capacity and
  /// `presence` below 20%, while `callSignal` drains the bucket to zero —
  /// deterministic lowest-priority-first shedding.
  final double priorityReserveFraction;

  const LinkFlowControlConfig({
    this.perPeerWindowMs = 10 * 1000,
    this.maxMessagesPerPeerPerWindow = 30,
    this.maxGlobalMessagesPerSecond = 50,
    this.burstAllowance = 20,
    this.maxTrackedPeers = 256,
    this.priorityReserveFraction = 0.2,
  });

  /// Total token-bucket capacity.
  int get bucketCapacity => maxGlobalMessagesPerSecond + burstAllowance;

  /// Throws [ArgumentError] on any out-of-range knob. Called by
  /// [GuardedLinkProcessor] so an invalid config can never be installed.
  void validate() {
    if (perPeerWindowMs <= 0) {
      throw ArgumentError.value(
        perPeerWindowMs,
        'perPeerWindowMs',
        'must be positive',
      );
    }
    if (maxMessagesPerPeerPerWindow <= 0) {
      throw ArgumentError.value(
        maxMessagesPerPeerPerWindow,
        'maxMessagesPerPeerPerWindow',
        'must be positive',
      );
    }
    if (maxGlobalMessagesPerSecond <= 0) {
      throw ArgumentError.value(
        maxGlobalMessagesPerSecond,
        'maxGlobalMessagesPerSecond',
        'must be positive',
      );
    }
    if (burstAllowance < 0) {
      throw ArgumentError.value(
        burstAllowance,
        'burstAllowance',
        'must be non-negative',
      );
    }
    if (maxTrackedPeers <= 0) {
      throw ArgumentError.value(
        maxTrackedPeers,
        'maxTrackedPeers',
        'must be positive',
      );
    }
    if (priorityReserveFraction < 0 || priorityReserveFraction > 0.5) {
      throw ArgumentError.value(
        priorityReserveFraction,
        'priorityReserveFraction',
        'must be within [0, 0.5]',
      );
    }
  }
}

/// Why a message was shed before reaching the inner processor.
enum LinkFlowRejection { peerQuotaExceeded, rateLimited }

/// Outcome of a guarded process call: either the inner processor's
/// disposition (admitted) or a flow-control rejection (shed).
///
/// A true `sealed class` with exactly two variants ([AdmittedLinkOutcome],
/// [ShedLinkOutcome]) so callers can exhaustively `switch` on the outcome.
/// The pre-existing public surface — `admitted`/`disposition`/`rejection`
/// getters and the `.admitted(...)`/`.shed(...)` factory constructors — is
/// preserved unchanged on the base type so every existing call site
/// compiles as-is; the factories now return the concrete subtype.
sealed class GuardedLinkOutcome {
  /// Set when the message was admitted to the inner processor.
  LinkDisposition? get disposition;

  /// Set when flow control shed the message before processing.
  LinkFlowRejection? get rejection;

  const GuardedLinkOutcome();

  const factory GuardedLinkOutcome.admitted(LinkDisposition disposition) =
      AdmittedLinkOutcome;

  const factory GuardedLinkOutcome.shed(LinkFlowRejection rejection) =
      ShedLinkOutcome;

  bool get admitted => rejection == null;
}

/// The message was admitted to the inner processor.
final class AdmittedLinkOutcome extends GuardedLinkOutcome {
  @override
  final LinkDisposition disposition;

  @override
  LinkFlowRejection? get rejection => null;

  const AdmittedLinkOutcome(this.disposition);
}

/// Flow control shed the message before it reached the inner processor.
final class ShedLinkOutcome extends GuardedLinkOutcome {
  @override
  final LinkFlowRejection rejection;

  @override
  LinkDisposition? get disposition => null;

  const ShedLinkOutcome(this.rejection);
}

/// Wraps a [LinkMessageProcessor] with per-peer quotas, a global
/// token-bucket rate limit, and priority-aware shedding. The inner
/// processor (and its `forwardingEnabled = false` default kill-switch)
/// is left untouched.
class GuardedLinkProcessor {
  final LinkMessageProcessor inner;
  final LinkFlowControlConfig config;

  /// Insertion-ordered by last activity; least-recently-active evicted.
  final LinkedHashMap<String, List<int>> _admittedAtMsByPeer =
      LinkedHashMap<String, List<int>>();

  double _tokens;
  int _lastRefillMs;

  GuardedLinkProcessor({
    required this.inner,
    this.config = const LinkFlowControlConfig(),
  }) : _tokens = (config.maxGlobalMessagesPerSecond + config.burstAllowance)
           .toDouble(),
       _lastRefillMs = 0 {
    config.validate();
  }

  /// Current token count, exposed for tests/telemetry.
  double get availableTokens => _tokens;

  Future<GuardedLinkOutcome> process(
    MediaFrame envelope, {
    required String peerId,
    required LinkMessagePriority priority,
    required int nowMs,
  }) async {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }

    _refillTokens(nowMs);

    if (_isPeerOverQuota(peerId, nowMs)) {
      return const GuardedLinkOutcome.shed(LinkFlowRejection.peerQuotaExceeded);
    }

    if (_tokens < _admissionThreshold(priority)) {
      return const GuardedLinkOutcome.shed(LinkFlowRejection.rateLimited);
    }

    _tokens -= 1;
    _recordPeerAdmission(peerId, nowMs);

    final disposition = await inner.process(envelope, nowMs: nowMs);
    return GuardedLinkOutcome.admitted(disposition);
  }

  /// A message may spend a token only while the bucket holds at least one
  /// token plus the reserve kept for higher-priority classes.
  double _admissionThreshold(LinkMessagePriority priority) {
    final stepsBelowTop = LinkMessagePriority.callSignal.index - priority.index;
    return 1 +
        config.bucketCapacity * config.priorityReserveFraction * stepsBelowTop;
  }

  void _refillTokens(int nowMs) {
    if (nowMs <= _lastRefillMs) {
      // Never rewind: a stale clock reading must not mint tokens.
      _lastRefillMs = _lastRefillMs > nowMs ? _lastRefillMs : nowMs;
      return;
    }

    final elapsedMs = nowMs - _lastRefillMs;
    _tokens += elapsedMs * config.maxGlobalMessagesPerSecond / 1000;

    final capacity = config.bucketCapacity.toDouble();
    if (_tokens > capacity) {
      _tokens = capacity;
    }

    _lastRefillMs = nowMs;
  }

  bool _isPeerOverQuota(String peerId, int nowMs) {
    final admissions = _admittedAtMsByPeer[peerId];
    if (admissions == null) return false;

    admissions.removeWhere(
      (admittedAtMs) => admittedAtMs <= nowMs - config.perPeerWindowMs,
    );

    if (admissions.isEmpty) {
      _admittedAtMsByPeer.remove(peerId);
      return false;
    }

    return admissions.length >= config.maxMessagesPerPeerPerWindow;
  }

  void _recordPeerAdmission(String peerId, int nowMs) {
    // Re-insert to keep the map ordered by last activity.
    final admissions = _admittedAtMsByPeer.remove(peerId) ?? <int>[];
    admissions.add(nowMs);
    _admittedAtMsByPeer[peerId] = admissions;

    while (_admittedAtMsByPeer.length > config.maxTrackedPeers) {
      _admittedAtMsByPeer.remove(_admittedAtMsByPeer.keys.first);
    }
  }
}
