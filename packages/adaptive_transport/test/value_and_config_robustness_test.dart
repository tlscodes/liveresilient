/// Robustness matrix for the package's value types and config validation:
/// malformed payloads must be rejected loudly, and the diagnostic surfaces
/// (toString) must render — the branches live call-setup paths depend on
/// when relaying operator-supplied endpoint data.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

void main() {
  group('HostPort.fromJson', () {
    test('accepts a valid host/port map and trims the host', () {
      final hp = HostPort.fromJson({
        'host': '  relay.example.org ',
        'port': 443,
      });
      expect(hp.host, 'relay.example.org');
      expect(hp.port, 443);
    });

    test('rejects missing / non-string / blank hosts', () {
      expect(() => HostPort.fromJson({'port': 443}), throwsFormatException);
      expect(
        () => HostPort.fromJson({'host': 17, 'port': 443}),
        throwsFormatException,
      );
      expect(
        () => HostPort.fromJson({'host': '   ', 'port': 443}),
        throwsFormatException,
      );
    });

    test('rejects missing / non-int / out-of-range ports', () {
      expect(() => HostPort.fromJson({'host': 'h'}), throwsFormatException);
      expect(
        () => HostPort.fromJson({'host': 'h', 'port': '443'}),
        throwsFormatException,
      );
      expect(
        () => HostPort.fromJson({'host': 'h', 'port': 0}),
        throwsFormatException,
      );
      expect(
        () => HostPort.fromJson({'host': 'h', 'port': 65536}),
        throwsFormatException,
      );
    });
  });

  group('HostPort.parseAuthority', () {
    test('parses hostname, IPv4, and bracketed IPv6 authorities', () {
      expect(
        HostPort.parseAuthority('example.org:443').authority,
        'example.org:443',
      );
      expect(HostPort.parseAuthority('192.0.2.10:443').host, '192.0.2.10');
      final v6 = HostPort.parseAuthority('[2001:db8::10]:443');
      expect(v6.host, '2001:db8::10');
      expect(v6.port, 443);
      expect(v6.authority, '[2001:db8::10]:443', reason: 'IPv6 re-brackets');
    });

    test('rejects empty, full-URI, and unbracketed-IPv6 inputs', () {
      expect(() => HostPort.parseAuthority('   '), throwsFormatException);
      expect(
        () => HostPort.parseAuthority('wss://example.org:443'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('2001:db8::1:443'),
        throwsFormatException,
      );
    });

    test('rejects portless, zero-port, oversized-port, and decorated '
        'authorities', () {
      expect(
        () => HostPort.parseAuthority('example.org'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('example.org:0'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('example.org:99999'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('user@example.org:443'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('example.org:443?x=1'),
        throwsFormatException,
      );
      expect(
        () => HostPort.parseAuthority('example.org:443/path'),
        throwsFormatException,
      );
    });

    test('toUri builds a scheme URI and rejects an empty scheme', () {
      final hp = HostPort.parseAuthority('example.org:443');
      expect(hp.toUri('wss').toString(), 'wss://example.org:443');
      expect(() => hp.toUri(''), throwsArgumentError);
    });

    test('toUri builds a correctly-bracketed IPv6 URI', () {
      final hp = HostPort.parseAuthority('[2001:db8::10]:443');
      final uri = hp.toUri('wss');
      expect(uri.host, '2001:db8::10');
      expect(uri.port, 443);
      expect(uri.toString(), 'wss://[2001:db8::10]:443');
    });

    test('operator== / hashCode are structural on host+port', () {
      final a = HostPort(host: 'example.org', port: 443);
      final b = HostPort(host: 'example.org', port: 443);
      final differentPort = HostPort(host: 'example.org', port: 8443);
      final differentHost = HostPort(host: 'other.org', port: 443);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(differentPort)));
      expect(a, isNot(equals(differentHost)));
      // ignore: unrelated_type_equality_checks
      expect(a == 'not a HostPort', isFalse);
    });

    test('set membership follows structural equality, not identity', () {
      final a = HostPort(host: 'example.org', port: 443);
      final b = HostPort(host: 'example.org', port: 443);
      final other = HostPort(host: 'example.org', port: 8443);

      final set = {a, b, other};

      expect(set, hasLength(2), reason: 'a and b are structurally equal');
      expect(set.contains(HostPort(host: 'example.org', port: 443)), isTrue);
      expect(set.contains(HostPort(host: 'other.org', port: 443)), isFalse);
    });

    test('toJson round-trips through fromJson', () {
      final hp = HostPort.parseAuthority('example.org:443');
      expect(HostPort.fromJson(hp.toJson()).authority, hp.authority);
      expect(hp.toString(), hp.authority);
    });
  });

  group('CircuitBreakerConfig validation', () {
    test('rejects out-of-range thresholds and durations', () {
      expect(
        () => CircuitBreaker(
          config: const CircuitBreakerConfig(failureThreshold: 0),
        ),
        throwsRangeError,
      );
      expect(
        () => CircuitBreaker(
          config: const CircuitBreakerConfig(halfOpenMaxProbes: 0),
        ),
        throwsRangeError,
      );
      expect(
        () => CircuitBreaker(
          config: const CircuitBreakerConfig(halfOpenSuccessesToClose: 0),
        ),
        throwsRangeError,
      );
      expect(
        () => CircuitBreaker(
          config: const CircuitBreakerConfig(openDuration: Duration.zero),
        ),
        throwsArgumentError,
      );
      expect(
        () => CircuitBreaker(
          config: const CircuitBreakerConfig(
            openDuration: Duration(seconds: 10),
            maxOpenDuration: Duration(seconds: 5),
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('CircuitBreaker edge branches', () {
    test('exponential back-off caps at maxOpenDuration', () {
      var now = DateTime.utc(2026, 1, 1);
      final breaker = CircuitBreaker(
        config: const CircuitBreakerConfig(
          failureThreshold: 1,
          openDuration: Duration(seconds: 10),
          maxOpenDuration: Duration(seconds: 15),
        ),
        clock: () => now,
      );

      breaker.recordFailure(); // cycle 1: 10s cool-down
      expect(breaker.currentOpenDuration, const Duration(seconds: 10));

      now = now.add(const Duration(seconds: 10));
      expect(breaker.allowsRequest(), isTrue, reason: 'half-open probe');
      breaker.recordFailure(); // cycle 2: 20s uncapped -> capped at 15s

      expect(breaker.currentOpenDuration, const Duration(seconds: 15));
    });

    test('recordFailure while open is a no-op (no extra back-off cycle)', () {
      var now = DateTime.utc(2026, 1, 1);
      final breaker = CircuitBreaker(
        config: const CircuitBreakerConfig(failureThreshold: 1),
        clock: () => now,
      );

      breaker.recordFailure(); // trips open
      expect(breaker.state, CircuitState.open);
      final cooldown = breaker.currentOpenDuration;

      breaker.recordFailure(); // late failure from an in-flight request
      breaker.recordFailure();

      expect(breaker.state, CircuitState.open);
      expect(
        breaker.currentOpenDuration,
        cooldown,
        reason: 'late failures must not extend the back-off',
      );
    });

    test('resetToClosed restores a tripped breaker immediately', () {
      final breaker = CircuitBreaker(
        config: const CircuitBreakerConfig(failureThreshold: 1),
        clock: () => DateTime.utc(2026, 1, 1),
      );
      breaker.recordFailure();
      expect(breaker.state, CircuitState.open);

      breaker.resetToClosed();

      expect(breaker.state, CircuitState.closed);
      expect(breaker.allowsRequest(), isTrue);
    });
  });

  group('Relay pool value/config validation', () {
    RelayRegion region(String id) =>
        RelayRegion(id: id, uris: [Uri.parse('turns:relay.example.org:5349')]);

    test('RelayRegion rejects bad ids, empty URI lists, non-turn schemes', () {
      expect(
        () => RelayRegion(id: 'EU_Central', uris: [Uri.parse('turn:h:3478')]),
        throwsFormatException,
      );
      expect(() => RelayRegion(id: 'eu', uris: []), throwsFormatException);
      expect(
        () => RelayRegion(id: 'eu', uris: [Uri.parse('stun:h:3478')]),
        throwsFormatException,
      );
      expect(region('eu-central').toString(), contains('eu-central'));
    });

    test('RegionHealth rejects out-of-range alphas and renders health', () {
      final health = RegionHealth();
      expect(() => health.observeSuccess(alpha: 0), throwsRangeError);
      expect(() => health.observeFailure(alpha: 1.5), throwsRangeError);

      health.observeFailure();
      expect(health.availability, lessThan(1.0));
      expect(health.toString(), contains('availability'));
    });

    test('RelayPoolConfig rejects a non-positive probe interval', () {
      expect(
        () => RelayPool(
          regions: [region('eu-central')],
          config: const RelayPoolConfig(probeInterval: Duration.zero),
        ),
        throwsArgumentError,
      );
    });

    test('NoHealthyRelayException carries its reason in toString', () {
      expect(
        NoHealthyRelayException('all circuits open').toString(),
        'NoHealthyRelayException: all circuits open',
      );
    });
  });

  group('Network quality policy diagnostics', () {
    test('QualitySignals and NetworkQualityKnobs render for telemetry', () {
      const signals = QualitySignals(
        loss: PacketLossBucket.low,
        rtt: RttBucket.low,
        gatewayReachable: true,
        localPeersReachable: false,
      );
      expect(signals.toString(), contains('gateway: true'));

      const knobs = NetworkQualityKnobs(
        retryLimit: 2,
        operationTimeout: Duration(seconds: 5),
        mediaMode: MediaModeRung.audioOnly,
        relayPreference: RelayPreference.preferRelay,
        telemetrySamplingRate: 0.5,
        batteryBudgetHint: 0.8,
      );
      expect(knobs.toString(), contains('timeout: 5000ms'));
      expect(knobs.toString(), contains('media: audioOnly'));
    });
  });
}
