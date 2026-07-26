import 'dart:async';
import 'dart:math';

import 'host_port.dart';

/// One reachable relay front-end: where to connect, and which virtual host to
/// ask for in the TLS SNI extension (RFC 6066 section 3).
///
/// [sniHostName] is kept separate from [hostPort] because several logical hosts
/// commonly share one address, and a roaming client may reach the same virtual
/// host through a different address.
class RelayEndpoint {
  RelayEndpoint({required this.hostPort, String? sniHostName})
      : sniHostName = sniHostName ?? hostPort.host {
    if (this.sniHostName.trim().isEmpty) {
      throw ArgumentError.value(sniHostName, 'sniHostName', 'must not be empty');
    }
  }

  final HostPort hostPort;
  final String sniHostName;

  @override
  String toString() => '${hostPort.authority} (sni=$sniHostName)';
}

/// Raised when every configured endpoint has been tried and none accepted the
/// connection.
class NoReachableEndpointException implements Exception {
  NoReachableEndpointException(this.attempts, this.lastError);

  final int attempts;
  final Object? lastError;

  @override
  String toString() =>
      'NoReachableEndpointException: $attempts attempt(s) failed, '
      'last error: $lastError';
}

/// Connects to a relay across several endpoints, moving to the next one when the
/// current path degrades.
///
/// Retry timing is exponential backoff with full jitter: attempt *n* waits a
/// random duration in `[0, baseBackoff * 2^n]`, capped at [maxBackoff]. Jitter
/// keeps a fleet of clients that all lost the same relay from reconnecting in
/// lockstep.
///
/// The endpoint cursor is persistent: after a successful connection the next
/// [connect] starts from the endpoint that worked, so a healthy path is not
/// abandoned on the next call.
class MultiHomedConnector<T> {
  MultiHomedConnector({
    required List<RelayEndpoint> endpoints,
    required Future<T> Function(RelayEndpoint endpoint) connect,
    this.baseBackoff = const Duration(milliseconds: 200),
    this.maxBackoff = const Duration(seconds: 10),
    this.attemptsPerEndpoint = 1,
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _endpoints = List<RelayEndpoint>.unmodifiable(endpoints),
        _connect = connect,
        _random = random ?? Random.secure(),
        _sleep = sleep ?? Future<void>.delayed {
    if (_endpoints.isEmpty) {
      throw ArgumentError.value(endpoints, 'endpoints', 'must not be empty');
    }
    if (attemptsPerEndpoint < 1) {
      throw ArgumentError.value(
        attemptsPerEndpoint,
        'attemptsPerEndpoint',
        'must be >= 1',
      );
    }
    if (baseBackoff <= Duration.zero || maxBackoff < baseBackoff) {
      throw ArgumentError('backoff bounds must satisfy 0 < base <= max');
    }
  }

  final List<RelayEndpoint> _endpoints;
  final Future<T> Function(RelayEndpoint) _connect;
  final Random _random;
  final Future<void> Function(Duration) _sleep;

  final Duration baseBackoff;
  final Duration maxBackoff;
  final int attemptsPerEndpoint;

  int _cursor = 0;

  /// Endpoints in the order the next [connect] will try them.
  List<RelayEndpoint> get rotation => [
        for (int i = 0; i < _endpoints.length; i++)
          _endpoints[(_cursor + i) % _endpoints.length],
      ];

  /// The endpoint the next attempt starts from.
  RelayEndpoint get currentEndpoint => _endpoints[_cursor];

  /// Upper bound of the jitter window for the given zero-based retry index.
  Duration backoffCeilingFor(int retryIndex) {
    if (retryIndex <= 0) return Duration.zero;
    // Shift is capped so the multiplication cannot overflow before clamping.
    final int shift = retryIndex > 32 ? 32 : retryIndex;
    final int micros = baseBackoff.inMicroseconds << shift;
    return micros >= maxBackoff.inMicroseconds || micros < 0
        ? maxBackoff
        : Duration(microseconds: micros);
  }

  /// Tries each endpoint in [rotation], up to [attemptsPerEndpoint] times each,
  /// and returns the first successful connection.
  ///
  /// Throws [NoReachableEndpointException] once every attempt has failed.
  Future<T> connect() async {
    final int totalAttempts = _endpoints.length * attemptsPerEndpoint;
    Object? lastError;

    for (int attempt = 0; attempt < totalAttempts; attempt++) {
      if (attempt > 0) {
        final ceiling = backoffCeilingFor(attempt);
        if (ceiling > Duration.zero) {
          await _sleep(
            Duration(microseconds: _random.nextInt(ceiling.inMicroseconds + 1)),
          );
        }
      }

      final endpoint = _endpoints[_cursor];
      try {
        final connection = await _connect(endpoint);
        return connection;
      } catch (error) {
        lastError = error;
        _advance();
      }
    }

    throw NoReachableEndpointException(totalAttempts, lastError);
  }

  /// Marks the current path as degraded so the next [connect] starts elsewhere.
  /// Call this when an established connection drops or its quality collapses.
  void reportPathDegraded() => _advance();

  void _advance() {
    _cursor = (_cursor + 1) % _endpoints.length;
  }
}

/// Result of a raced connect: which endpoint won, the connection, how many
/// attempts were started, and how long the winner took.
class RacedConnection<T> {
  RacedConnection({
    required this.endpoint,
    required this.connection,
    required this.attemptsStarted,
    required this.elapsed,
  });

  final RelayEndpoint endpoint;
  final T connection;
  final int attemptsStarted;
  final Duration elapsed;
}

/// Staggered parallel connection racing per Happy Eyeballs v2 (RFC 8305
/// section 5): attempt endpoint 0 immediately, start the next attempt every
/// [connectionAttemptDelay] (RFC 8305 recommends 250 ms) without waiting for
/// the previous one to fail, and take the first success. Losing attempts are
/// handed to [discard] so their sockets can be closed.
///
/// Sequential fallback waits full timeouts serially; racing bounds the added
/// latency of a dead first endpoint to one stagger delay instead.
class HappyEyeballsRacer<T> {
  HappyEyeballsRacer({
    required List<RelayEndpoint> endpoints,
    required Future<T> Function(RelayEndpoint endpoint) connect,
    this.connectionAttemptDelay = const Duration(milliseconds: 250),
    void Function(T connection)? discard,
    DateTime Function()? now,
  })  : _endpoints = List<RelayEndpoint>.unmodifiable(endpoints),
        _connect = connect,
        _discard = discard,
        _now = now ?? DateTime.now {
    if (_endpoints.isEmpty) {
      throw ArgumentError.value(endpoints, 'endpoints', 'must not be empty');
    }
    if (connectionAttemptDelay <= Duration.zero) {
      throw ArgumentError.value(connectionAttemptDelay,
          'connectionAttemptDelay', 'must be positive');
    }
  }

  final List<RelayEndpoint> _endpoints;
  final Future<T> Function(RelayEndpoint) _connect;
  final void Function(T)? _discard;
  final DateTime Function() _now;

  final Duration connectionAttemptDelay;

  /// Races the endpoints; completes with the first successful connection or
  /// throws [NoReachableEndpointException] when every attempt failed.
  Future<RacedConnection<T>> race() {
    final started = _now();
    final result = Completer<RacedConnection<T>>();
    var attemptsStarted = 0;
    var failures = 0;
    Object? lastError;
    Timer? stagger;

    void launch(int index) {
      if (result.isCompleted || index >= _endpoints.length) return;
      attemptsStarted++;
      final endpoint = _endpoints[index];
      _connect(endpoint).then((connection) {
        if (result.isCompleted) {
          _discard?.call(connection);
          return;
        }
        stagger?.cancel();
        result.complete(RacedConnection(
          endpoint: endpoint,
          connection: connection,
          attemptsStarted: attemptsStarted,
          elapsed: _now().difference(started),
        ));
      }).catchError((Object error) {
        lastError = error;
        failures++;
        if (result.isCompleted) return;
        if (failures == _endpoints.length) {
          stagger?.cancel();
          result.completeError(
            NoReachableEndpointException(attemptsStarted, lastError),
          );
        } else if (attemptsStarted < _endpoints.length) {
          // A failure releases the stagger early (RFC 8305 section 5): start
          // the next candidate now instead of waiting out the delay.
          stagger?.cancel();
          launch(attemptsStarted);
          if (attemptsStarted < _endpoints.length) {
            stagger = Timer.periodic(
              connectionAttemptDelay,
              (_) => launch(attemptsStarted),
            );
          }
        }
      });
    }

    launch(0);
    if (_endpoints.length > 1) {
      stagger = Timer.periodic(
        connectionAttemptDelay,
        (_) => launch(attemptsStarted),
      );
    }
    return result.future;
  }
}

/// Wraps a [MultiHomedConnector]-style switch with mandatory post-switch path
/// validation: after connecting on a new endpoint the caller runs its
/// challenge/response probe, and only a validated connection is released to
/// carry media. An unvalidated path is discarded and counted.
class ValidatedSwitcher<T> {
  ValidatedSwitcher({
    required Future<T> Function(RelayEndpoint endpoint) connect,
    required Future<bool> Function(RelayEndpoint endpoint, T connection)
        validatePath,
    void Function(T connection)? discard,
  })  : _connect = connect,
        _validatePath = validatePath,
        _discard = discard;

  final Future<T> Function(RelayEndpoint) _connect;
  final Future<bool> Function(RelayEndpoint, T) _validatePath;
  final void Function(T)? _discard;

  int _switches = 0;
  int _validationFailures = 0;

  int get switchCount => _switches;
  int get validationFailureCount => _validationFailures;

  /// Connects to [endpoint] and returns the connection only after the path
  /// validation probe passed. Throws [StateError] when validation fails, so a
  /// caller can fall back to the next endpoint.
  Future<T> switchTo(RelayEndpoint endpoint) async {
    final connection = await _connect(endpoint);
    final ok = await _validatePath(endpoint, connection);
    if (!ok) {
      _validationFailures++;
      _discard?.call(connection);
      throw StateError('path validation failed for $endpoint');
    }
    _switches++;
    return connection;
  }
}
