/// Application-level abuse controls for the signaling relay.
///
/// Scope note: these are per-process rate/session/spam limits that protect
/// the relay's memory and CPU from a misbehaving client. They are NOT a
/// substitute for network-level DDoS protection — volumetric attack
/// mitigation belongs to standard infrastructure (cloud load balancer / WAF /
/// upstream filtering) in front of this process, per the deployment
/// blueprint. Nothing here claims DDoS immunity.
///
/// Privacy note: the exported [AbuseCounters] are plain aggregate integers —
/// no identities, remote addresses, or callIds are ever stored in them. The
/// enforcement maps inside [AbuseGuard] are keyed by a transient source key
/// (remote address string) strictly for in-memory limiting; entries are
/// pruned on a fixed window and are never logged or exported.
library;

/// Injectable time source so every limit is deterministic under test.
typedef Clock = DateTime Function();

/// WebSocket close code: per-connection message rate limit exceeded.
const int rateLimitCloseCode = 4429;

/// WebSocket close code: too many new callIds created by one source within
/// the session window (invite-spam guard).
const int sessionLimitCloseCode = 4430;

/// WebSocket close code: concurrent room capacity reached (global or
/// per-source); the close reason string names which cap fired.
const int roomCapacityCloseCode = 4503;

/// WebSocket close code: room reaped after exceeding the idle TTL.
const int idleTimeoutCloseCode = 4408;

/// Validated configuration for [AbuseGuard]. All limits are constructor
/// parameters with production-safe defaults; construction throws
/// [ArgumentError] on any non-sensical value.
class AbuseControlConfig {
  /// Creates a config, validating every field.
  AbuseControlConfig({
    this.messagesPerSecond = 30,
    this.messageBurst = 60,
    this.maxNewCallIdsPerWindow = 20,
    this.sessionWindow = const Duration(seconds: 60),
    this.rejoinWindow = const Duration(minutes: 5),
    this.maxConcurrentRoomsGlobal = 1024,
    this.maxConcurrentRoomsPerSource = 16,
    this.maxFrameBytes = 64 * 1024,
    this.idleRoomTtl = const Duration(minutes: 10),
    this.sweepInterval = const Duration(seconds: 30),
  }) {
    if (messagesPerSecond <= 0) {
      throw ArgumentError.value(
        messagesPerSecond,
        'messagesPerSecond',
        'must be > 0',
      );
    }
    if (messageBurst < 1) {
      throw ArgumentError.value(messageBurst, 'messageBurst', 'must be >= 1');
    }
    if (maxNewCallIdsPerWindow < 1) {
      throw ArgumentError.value(
        maxNewCallIdsPerWindow,
        'maxNewCallIdsPerWindow',
        'must be >= 1',
      );
    }
    if (sessionWindow <= Duration.zero) {
      throw ArgumentError.value(sessionWindow, 'sessionWindow', 'must be > 0');
    }
    if (rejoinWindow < sessionWindow) {
      throw ArgumentError.value(
        rejoinWindow,
        'rejoinWindow',
        'must be >= sessionWindow (a legit reconnect must never be counted '
            'as a new session while its creation still counts)',
      );
    }
    if (maxConcurrentRoomsGlobal < 1) {
      throw ArgumentError.value(
        maxConcurrentRoomsGlobal,
        'maxConcurrentRoomsGlobal',
        'must be >= 1',
      );
    }
    if (maxConcurrentRoomsPerSource < 1) {
      throw ArgumentError.value(
        maxConcurrentRoomsPerSource,
        'maxConcurrentRoomsPerSource',
        'must be >= 1',
      );
    }
    if (maxFrameBytes < 1) {
      throw ArgumentError.value(maxFrameBytes, 'maxFrameBytes', 'must be >= 1');
    }
    if (idleRoomTtl <= Duration.zero) {
      throw ArgumentError.value(idleRoomTtl, 'idleRoomTtl', 'must be > 0');
    }
    if (sweepInterval <= Duration.zero) {
      throw ArgumentError.value(sweepInterval, 'sweepInterval', 'must be > 0');
    }
  }

  /// Sustained per-connection message rate (token-bucket refill rate).
  final double messagesPerSecond;

  /// Instantaneous burst allowance per connection (token-bucket capacity).
  final int messageBurst;

  /// Max NEW callIds one source may create within [sessionWindow].
  /// Rejoining a callId this source was recently seen on is free.
  final int maxNewCallIdsPerWindow;

  /// Window over which new-callId creations are counted.
  final Duration sessionWindow;

  /// How long a (source, callId) association is remembered so that a
  /// legitimate reconnect to the SAME callId is admitted without consuming
  /// session-creation quota. Must be >= [sessionWindow].
  final Duration rejoinWindow;

  /// Hard cap on rooms tracked by the whole process.
  final int maxConcurrentRoomsGlobal;

  /// Cap on rooms a single source may participate in concurrently.
  final int maxConcurrentRoomsPerSource;

  /// Largest frame (bytes) accepted for relaying/buffering. Larger frames
  /// are dropped before they touch any buffer (connection stays open,
  /// matching the relay's established drop-not-close frame semantics).
  final int maxFrameBytes;

  /// Rooms with no traffic for this long are reaped by the sweep.
  final Duration idleRoomTtl;

  /// How often the idle-room / stale-entry sweep runs.
  final Duration sweepInterval;
}

/// Aggregate, privacy-preserving counters — plain integers only, suitable
/// for a future metrics exporter. No identities, addresses, or callIds.
class AbuseCounters {
  /// Total WebSocket connections accepted.
  int connectionsTotal = 0;

  /// Connections closed for exceeding the message rate limit.
  int rateLimitDisconnects = 0;

  /// Room joins rejected by the session-creation (invite-spam) limit.
  int sessionLimitRejections = 0;

  /// Room joins rejected by the global or per-source concurrent room cap.
  int roomCapacityRejections = 0;

  /// Frames dropped for exceeding [AbuseControlConfig.maxFrameBytes].
  int oversizedFramesDropped = 0;

  /// Rooms reaped by the idle-TTL sweep.
  int idleRoomsReaped = 0;
}

/// Verdict for a room-join attempt.
class RoomAdmission {
  const RoomAdmission._(this.allowed, this.closeCode, this.reason);

  static const RoomAdmission _allowed = RoomAdmission._(true, 0, '');

  /// Whether the join may proceed.
  final bool allowed;

  /// Typed WebSocket close code to send when [allowed] is false.
  final int closeCode;

  /// Human-readable (identity-free) rejection reason.
  final String reason;
}

/// Per-connection token bucket. One instance per socket; not thread-safe
/// (the relay is single-isolate).
class TokenBucket {
  TokenBucket._(this._ratePerSecond, this._capacity, this._now)
    : _tokens = _capacity.toDouble() {
    _lastRefill = _now();
  }

  final double _ratePerSecond;
  final int _capacity;
  final Clock _now;
  double _tokens;
  late DateTime _lastRefill;

  /// Consumes one token if available; returns false on rate violation.
  bool tryConsume() {
    final now = _now();
    final elapsedMicros = now.difference(_lastRefill).inMicroseconds;
    if (elapsedMicros > 0) {
      _tokens =
          (_tokens +
                  _ratePerSecond *
                      elapsedMicros /
                      Duration.microsecondsPerSecond)
              .clamp(0, _capacity.toDouble());
      _lastRefill = now;
    }
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}

class _CallIdRecord {
  _CallIdRecord(this.createdAt) : lastSeen = createdAt;

  /// When this source first created/joined the callId — the timestamp that
  /// counts against the session-creation window.
  final DateTime createdAt;

  /// Last join activity; drives [AbuseControlConfig.rejoinWindow] expiry.
  DateTime lastSeen;
}

/// Enforces all configured limits and owns the aggregate counters.
///
/// The relay calls [newConnectionBucket] per socket, [admitRoomJoin] before
/// a socket enters a room, [leaveRoom] when it exits, and [prune]
/// periodically (bounded memory for the transient enforcement maps).
class AbuseGuard {
  /// Creates a guard with [config] limits and an injectable [clock].
  AbuseGuard({AbuseControlConfig? config, Clock? clock})
    : config = config ?? AbuseControlConfig(),
      _now = clock ?? DateTime.now;

  /// The active limit configuration.
  final AbuseControlConfig config;

  /// Aggregate privacy-preserving counters.
  final AbuseCounters counters = AbuseCounters();

  final Clock _now;

  /// source key -> recently seen callIds (session-creation tracking).
  final Map<String, Map<String, _CallIdRecord>> _recentCallIds =
      <String, Map<String, _CallIdRecord>>{};

  /// source key -> callIds of rooms the source currently occupies.
  final Map<String, Set<String>> _occupiedRooms = <String, Set<String>>{};

  /// A fresh per-connection rate limiter.
  TokenBucket newConnectionBucket() =>
      TokenBucket._(config.messagesPerSecond, config.messageBurst, _now);

  /// Decides whether [sourceKey] may join (or create, when [roomExists] is
  /// false) the room for [callId], given [activeRooms] rooms currently
  /// tracked by the relay. Bumps the matching rejection counter itself.
  RoomAdmission admitRoomJoin({
    required String sourceKey,
    required String callId,
    required bool roomExists,
    required int activeRooms,
  }) {
    final now = _now();
    final recent = _pruneSource(sourceKey, now);

    // Per-source concurrent room cap (creator and joiner both consume).
    final occupied = _occupiedRooms[sourceKey];
    if (occupied != null &&
        !occupied.contains(callId) &&
        occupied.length >= config.maxConcurrentRoomsPerSource) {
      counters.roomCapacityRejections++;
      return const RoomAdmission._(
        false,
        roomCapacityCloseCode,
        'per-source room capacity',
      );
    }

    if (!roomExists) {
      // Global concurrent room cap applies only to creating a NEW room.
      if (activeRooms >= config.maxConcurrentRoomsGlobal) {
        counters.roomCapacityRejections++;
        return const RoomAdmission._(
          false,
          roomCapacityCloseCode,
          'global room capacity',
        );
      }
      // Session-creation (invite-spam) limit: a callId this source was
      // recently seen on is a legitimate reconnect and is admitted free;
      // only genuinely new callIds consume quota.
      final record = recent[callId];
      if (record == null) {
        final windowStart = now.subtract(config.sessionWindow);
        var created = 0;
        for (final r in recent.values) {
          if (r.createdAt.isAfter(windowStart)) created++;
        }
        if (created >= config.maxNewCallIdsPerWindow) {
          counters.sessionLimitRejections++;
          return const RoomAdmission._(
            false,
            sessionLimitCloseCode,
            'session creation limit',
          );
        }
        recent[callId] = _CallIdRecord(now);
      } else {
        record.lastSeen = now;
      }
    } else {
      // Joining an existing room: remember the association so this source's
      // own reconnect to the same callId stays free.
      (recent[callId] ??= _CallIdRecord(now)).lastSeen = now;
    }

    (_occupiedRooms[sourceKey] ??= <String>{}).add(callId);
    return RoomAdmission._allowed;
  }

  /// Releases [sourceKey]'s concurrent-room slot for [callId].
  void leaveRoom(String sourceKey, String callId) {
    final occupied = _occupiedRooms[sourceKey];
    if (occupied == null) return;
    occupied.remove(callId);
    if (occupied.isEmpty) _occupiedRooms.remove(sourceKey);
  }

  /// Drops expired session-tracking entries for every source. Called on the
  /// relay's sweep tick so the transient maps stay bounded.
  void prune() {
    final now = _now();
    _recentCallIds.removeWhere((_, recent) {
      _expire(recent, now);
      return recent.isEmpty;
    });
  }

  Map<String, _CallIdRecord> _pruneSource(String sourceKey, DateTime now) {
    final recent = _recentCallIds[sourceKey] ?? <String, _CallIdRecord>{};
    _recentCallIds[sourceKey] = recent;
    _expire(recent, now);
    return recent;
  }

  void _expire(Map<String, _CallIdRecord> recent, DateTime now) {
    final cutoff = now.subtract(config.rejoinWindow);
    recent.removeWhere((_, r) => r.lastSeen.isBefore(cutoff));
  }
}
