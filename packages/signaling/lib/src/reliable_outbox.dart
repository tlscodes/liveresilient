/// Reliable at-least-once outbox for signaling envelopes.
///
/// Guarantees:
/// - every enqueued envelope is retransmitted with exponential back-off
///   until acknowledged, expired, or the outbox is disposed;
/// - retransmissions reuse the original `messageId`, so receivers
///   de-duplicate idempotently;
/// - an optional [OutboxStore] persists pending envelopes across process
///   restarts (crash-safe signaling for call setup on flaky devices).
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:clock/clock.dart';

import 'signal_envelope.dart';

/// Persistence contract for pending envelopes. Implementations must be
/// durable (e.g. app-local database). All methods may be called
/// concurrently with sends; implementations should be idempotent.
abstract interface class OutboxStore {
  Future<void> save(SignalEnvelope envelope);
  Future<void> remove(String messageId);
  Future<List<SignalEnvelope>> loadAll();
}

/// Transmission hook. Returns true when the underlying path accepted the
/// frame (acceptance is not delivery; delivery is confirmed only by an ack).
typedef OutboxTransmit = Future<bool> Function(SignalEnvelope envelope);

class OutboxConfig {
  /// First retransmission delay.
  final Duration initialRetryDelay;

  /// Cap for the exponentially growing retransmission delay.
  final Duration maxRetryDelay;

  /// Multiplier applied per retransmission.
  final double backoffMultiplier;

  /// Total time an envelope may stay pending before it is dropped and
  /// reported as failed.
  final Duration messageLifetime;

  /// Maximum number of pending envelopes; enqueueing beyond this throws
  /// [StateError] so callers surface overload instead of buffering silently.
  final int maxPending;

  const OutboxConfig({
    this.initialRetryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.messageLifetime = const Duration(minutes: 2),
    this.maxPending = 256,
  });
}

/// Terminal outcome for an envelope handed to the outbox.
enum OutboxOutcome { acknowledged, expired, disposed }

class _PendingEntry {
  final SignalEnvelope envelope;
  final DateTime enqueuedAt;
  final Completer<OutboxOutcome> completer = Completer<OutboxOutcome>();
  int attempts = 0;
  Timer? retryTimer;

  _PendingEntry(this.envelope, this.enqueuedAt);
}

class ReliableOutbox {
  final OutboxConfig config;
  final OutboxTransmit _transmit;
  final OutboxStore? _store;

  final LinkedHashMap<String, _PendingEntry> _pending =
      LinkedHashMap<String, _PendingEntry>();

  bool _disposed = false;

  ReliableOutbox({
    required OutboxTransmit transmit,
    OutboxStore? store,
    this.config = const OutboxConfig(),
  }) : _transmit = transmit,
       _store = store;

  int get pendingCount => _pending.length;

  /// Restores persisted envelopes (call once on startup, before [enqueue]).
  Future<void> restore() async {
    final store = _store;
    if (store == null) return;
    for (final envelope in await store.loadAll()) {
      if (_pending.containsKey(envelope.messageId)) continue;
      final entry = _PendingEntry(envelope, clock.now());
      _pending[envelope.messageId] = entry;
      _scheduleAttempt(entry, delay: Duration.zero);
    }
  }

  /// Enqueues an envelope for reliable delivery. The returned future
  /// completes with the terminal outcome (it never throws for delivery
  /// failures — expiry is an outcome, not an exception).
  Future<OutboxOutcome> enqueue(SignalEnvelope envelope) async {
    if (_disposed) {
      throw StateError('Outbox has been disposed.');
    }
    if (_pending.length >= config.maxPending) {
      throw StateError(
        'Outbox overloaded: ${_pending.length} envelopes pending.',
      );
    }
    if (_pending.containsKey(envelope.messageId)) {
      return _pending[envelope.messageId]!.completer.future;
    }

    final entry = _PendingEntry(envelope, clock.now());
    _pending[envelope.messageId] = entry;
    await _store?.save(envelope);
    _scheduleAttempt(entry, delay: Duration.zero);
    return entry.completer.future;
  }

  /// Marks a message as acknowledged by the receiver. Unknown ids are
  /// ignored (late or duplicated acks are normal under fanout).
  Future<void> acknowledge(String messageId) async {
    final entry = _pending.remove(messageId);
    if (entry == null) return;
    entry.retryTimer?.cancel();
    await _store?.remove(messageId);
    if (!entry.completer.isCompleted) {
      entry.completer.complete(OutboxOutcome.acknowledged);
    }
  }

  /// Immediately retries every pending envelope. Call when connectivity is
  /// restored (e.g. the signaling socket reconnected) so recovery does not
  /// wait for back-off timers.
  void flush() {
    for (final entry in _pending.values.toList()) {
      entry.retryTimer?.cancel();
      _scheduleAttempt(entry, delay: Duration.zero);
    }
  }

  Duration _delayForAttempt(int attempts) {
    final scale = math.pow(config.backoffMultiplier, attempts).toDouble();
    final ms = (config.initialRetryDelay.inMilliseconds * scale).round();
    return Duration(
      milliseconds: math.min(ms, config.maxRetryDelay.inMilliseconds),
    );
  }

  void _scheduleAttempt(_PendingEntry entry, {required Duration delay}) {
    if (_disposed) return;
    entry.retryTimer = Timer(delay, () => _attempt(entry));
  }

  Future<void> _attempt(_PendingEntry entry) async {
    if (_disposed || !_pending.containsKey(entry.envelope.messageId)) {
      return;
    }

    final age = clock.now().difference(entry.enqueuedAt);
    if (age >= config.messageLifetime) {
      _pending.remove(entry.envelope.messageId);
      await _store?.remove(entry.envelope.messageId);
      if (!entry.completer.isCompleted) {
        entry.completer.complete(OutboxOutcome.expired);
      }
      return;
    }

    entry.attempts++;
    try {
      await _transmit(entry.envelope);
    } catch (_) {
      // Transmission errors are absorbed; the retry timer below covers them.
    }

    // Delivery is confirmed only via acknowledge(); always schedule the
    // next retransmission. Ack cancels it.
    if (_pending.containsKey(entry.envelope.messageId)) {
      _scheduleAttempt(entry, delay: _delayForAttempt(entry.attempts));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _pending.values) {
      entry.retryTimer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete(OutboxOutcome.disposed);
      }
    }
    _pending.clear();
  }
}

/// Receiver-side de-duplication window for at-least-once delivery.
///
/// Retransmissions reuse `messageId`; this set answers "have I already
/// processed this id?" with a bounded memory footprint.
class InboxDeduplicator {
  final int maximumEntries;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  InboxDeduplicator({this.maximumEntries = 4096}) {
    if (maximumEntries < 1) {
      throw RangeError.range(maximumEntries, 1, null, 'maximumEntries');
    }
  }

  /// Returns true when the id is new (caller should process the message),
  /// false when it is a duplicate (caller should re-ack and drop it).
  bool markIfNew(String messageId) {
    if (_seen.contains(messageId)) return false;
    _seen.add(messageId);
    while (_seen.length > maximumEntries) {
      _seen.remove(_seen.first);
    }
    return true;
  }
}
