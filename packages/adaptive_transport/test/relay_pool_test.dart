import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' as wall;
import 'package:security/security.dart';
import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// Mutable fake time shared by the pool and (through it) every per-region
/// circuit breaker, so cool-downs advance coherently in tests.
class FakeTime {
  DateTime now = DateTime.utc(2026, 1, 1);

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}

List<Uri> _urisFor(String regionId) => [
  Uri.parse('turn:$regionId.relay.example.com:3478?transport=udp'),
  Uri.parse('turn:$regionId.relay.example.com:3478?transport=tcp'),
  Uri.parse('turns:$regionId.relay.example.com:5349?transport=tcp'),
];

RelayRegion _region(String id, {int priority = 0}) =>
    RelayRegion(id: id, uris: _urisFor(id), priority: priority);

/// Feeds [count] successful observations at a constant RTT so the EWMA
/// converges toward it.
void _warm(RelayPool pool, String id, int rttMs, {int count = 40}) {
  for (var i = 0; i < count; i++) {
    pool.reportSuccess(id, rtt: Duration(milliseconds: rttMs));
  }
}

EndpointManifest _manifest({List<String> relayRegions = const []}) =>
    EndpointManifest(
      revision: 1,
      signingKeyId: 'key-1',
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2026, 1, 2),
      signalingEndpoints: [Uri.parse('wss://sig.example.com/ws')],
      iceServers: [],
      configServiceUris: [Uri.parse('https://config.example.com/manifest')],
      relayRegions: relayRegions,
    );

void main() {
  group('RelayRegion validation', () {
    test('accepts manifest-format ids and turn/turns URIs', () {
      final r = _region('eu-central');
      expect(r.id, 'eu-central');
      expect(r.uris, hasLength(3));
    });

    test('rejects ids not matching ^[a-z0-9-]{1,32}\$', () {
      for (final bad in ['', 'EU-Central', 'eu_central', 'a' * 33, 'eu.c']) {
        expect(
          () => RelayRegion(id: bad, uris: _urisFor('eu-central')),
          throwsFormatException,
          reason: 'id "$bad" should be rejected',
        );
      }
    });

    test('rejects empty uris and non-relay (stun) schemes', () {
      expect(
        () => RelayRegion(id: 'eu-central', uris: const []),
        throwsFormatException,
      );
      expect(
        () => RelayRegion(
          id: 'eu-central',
          uris: [Uri.parse('stun:stun.example.com:3478')],
        ),
        throwsFormatException,
      );
    });
  });

  group('RelayPool construction', () {
    test('empty region list fails at construction (documented contract)', () {
      expect(() => RelayPool(regions: const []), throwsArgumentError);
    });

    test('duplicate region ids are rejected', () {
      expect(
        () =>
            RelayPool(regions: [_region('eu-central'), _region('eu-central')]),
        throwsArgumentError,
      );
    });

    test('invalid config is rejected', () {
      expect(
        () => RelayPool(
          regions: [_region('eu-central')],
          config: const RelayPoolConfig(ewmaAlpha: 0),
        ),
        throwsRangeError,
      );
      expect(
        () => RelayPool(
          regions: [_region('eu-central')],
          config: const RelayPoolConfig(hysteresisMargin: -0.1),
        ),
        throwsRangeError,
      );
    });
  });

  group('selectRegion scoring (property tests, seeded Random(7))', () {
    test('consistently lower-RTT region wins, all else equal', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final pool = RelayPool(
          regions: [_region('fast-region'), _region('slow-region')],
          clock: FakeTime().call,
        );
        final fastRtt = 20 + rng.nextInt(280);
        final slowRtt = fastRtt + 50 + rng.nextInt(500);
        _warm(pool, 'fast-region', fastRtt);
        _warm(pool, 'slow-region', slowRtt);
        expect(
          pool.selectRegion().id,
          'fast-region',
          reason: 'iteration $i: fastRtt=$fastRtt slowRtt=$slowRtt',
        );
      }
    });

    test('healthier region (fewer failures) wins at equal RTT', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final pool = RelayPool(
          regions: [_region('healthy'), _region('flaky')],
          clock: FakeTime().call,
          // failureThreshold high enough that flakiness never trips the
          // breaker: this isolates the EWMA-score effect.
          config: const RelayPoolConfig(
            breaker: CircuitBreakerConfig(failureThreshold: 1000),
          ),
        );
        final rtt = 20 + rng.nextInt(400);
        for (var n = 0; n < 40; n++) {
          pool.reportSuccess('healthy', rtt: Duration(milliseconds: rtt));
          if (n % 3 == 0) {
            pool.reportFailure('flaky');
          } else {
            pool.reportSuccess('flaky', rtt: Duration(milliseconds: rtt));
          }
        }
        expect(pool.selectRegion().id, 'healthy', reason: 'iteration $i');
      }
    });

    test('priority breaks exact score ties (fresh pool, no observations)', () {
      final pool = RelayPool(
        regions: [_region('us-east'), _region('eu-central', priority: 5)],
        clock: FakeTime().call,
      );
      expect(pool.selectRegion().id, 'eu-central');
    });
  });

  group('hysteresis (anti-flapping)', () {
    test('marginal challenger advantage does NOT switch the selection', () {
      final pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: FakeTime().call,
      );
      _warm(pool, 'eu-central', 50);
      _warm(pool, 'us-east', 80);
      expect(pool.selectRegion().id, 'eu-central');

      // us-east becomes marginally better (~2% score edge, margin is 15%).
      _warm(pool, 'us-east', 40);
      _warm(pool, 'eu-central', 60);
      final euScore = pool.healthOf('eu-central').score();
      final usScore = pool.healthOf('us-east').score();
      expect(usScore, greaterThan(euScore), reason: 'challenger must lead');
      expect(pool.selectRegion().id, 'eu-central');
      expect(pool.currentRegionId, 'eu-central');
    });

    test('margin-exceeding improvement DOES switch the selection', () {
      final pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: FakeTime().call,
      );
      _warm(pool, 'eu-central', 50);
      _warm(pool, 'us-east', 80);
      expect(pool.selectRegion().id, 'eu-central');

      // eu-central degrades hard while us-east improves: the challenger
      // now clears the 15% relative bar.
      _warm(pool, 'us-east', 20);
      _warm(pool, 'eu-central', 600);
      expect(pool.selectRegion().id, 'us-east');
      expect(pool.currentRegionId, 'us-east');
    });

    test('bounded switch count under oscillating near-equal health', () {
      final pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: FakeTime().call,
      );
      _warm(pool, 'eu-central', 50);
      _warm(pool, 'us-east', 55);

      var switches = 0;
      var previous = pool.selectRegion().id;
      for (var round = 0; round < 100; round++) {
        // Advantage flips every round, but only by ~5ms of RTT.
        final euRtt = round.isEven ? 55 : 50;
        final usRtt = round.isEven ? 50 : 55;
        for (var n = 0; n < 3; n++) {
          pool.reportSuccess('eu-central', rtt: Duration(milliseconds: euRtt));
          pool.reportSuccess('us-east', rtt: Duration(milliseconds: usRtt));
        }
        final selected = pool.selectRegion().id;
        if (selected != previous) switches++;
        previous = selected;
      }
      expect(
        switches,
        lessThanOrEqualTo(2),
        reason: 'hysteresis must suppress flapping on marginal oscillation',
      );
    });
  });

  group('failover and recovery (region kill gate, simulated)', () {
    late FakeTime time;
    late RelayPool pool;

    setUp(() {
      time = FakeTime();
      pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: time.call,
        config: const RelayPoolConfig(
          breaker: CircuitBreakerConfig(
            failureThreshold: 3,
            openDuration: Duration(seconds: 10),
            halfOpenSuccessesToClose: 2,
          ),
        ),
      );
      _warm(pool, 'eu-central', 50);
      _warm(pool, 'us-east', 80);
      expect(pool.selectRegion().id, 'eu-central');
    });

    test('consecutive failures open the circuit and selection moves', () {
      for (var i = 0; i < 3; i++) {
        pool.reportFailure('eu-central');
      }
      expect(pool.breakerStateOf('eu-central'), CircuitState.open);
      expect(pool.selectRegion().id, 'us-east');
      expect(pool.currentRegionId, 'us-east');
    });

    test('killed region earns its way back after cool-down + sustained '
        'success, without instant flap-back', () {
      for (var i = 0; i < 3; i++) {
        pool.reportFailure('eu-central');
      }
      expect(pool.selectRegion().id, 'us-east');

      // Cool-down elapses: breaker reads half-open, but the region's EWMA
      // score is still wrecked — hysteresis + score keep us-east selected.
      time.advance(const Duration(seconds: 11));
      expect(pool.breakerStateOf('eu-central'), CircuitState.halfOpen);
      pool.reportSuccess('eu-central', rtt: const Duration(milliseconds: 20));
      expect(pool.selectRegion().id, 'us-east', reason: 'no instant flap-back');

      // Sustained success closes the breaker and rebuilds the score while
      // us-east degrades; eu-central eventually clears the hysteresis bar.
      _warm(pool, 'eu-central', 20);
      expect(pool.breakerStateOf('eu-central'), CircuitState.closed);
      _warm(pool, 'us-east', 400);
      expect(pool.selectRegion().id, 'eu-central');
    });

    test('all regions dead surfaces an explicit typed failure', () {
      for (var i = 0; i < 3; i++) {
        pool.reportFailure('eu-central');
        pool.reportFailure('us-east');
      }
      expect(pool.breakerStateOf('eu-central'), CircuitState.open);
      expect(pool.breakerStateOf('us-east'), CircuitState.open);
      expect(
        () => pool.selectRegion(),
        throwsA(
          isA<NoHealthyRelayException>().having(
            (e) => e.reason,
            'reason',
            contains('2 relay regions'),
          ),
        ),
      );
    });
  });

  group('regionsDueForProbe', () {
    test('never-observed regions are due; fresh observations clear them '
        'until probeInterval elapses', () {
      final time = FakeTime();
      final pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: time.call,
        config: const RelayPoolConfig(probeInterval: Duration(seconds: 30)),
      );
      expect(pool.regionsDueForProbe().map((r) => r.id), [
        'eu-central',
        'us-east',
      ]);

      pool.reportSuccess('eu-central', rtt: const Duration(milliseconds: 50));
      expect(pool.regionsDueForProbe().map((r) => r.id), ['us-east']);

      pool.reportSuccess('us-east', rtt: const Duration(milliseconds: 80));
      expect(pool.regionsDueForProbe(), isEmpty);

      time.advance(const Duration(seconds: 31));
      expect(pool.regionsDueForProbe(), hasLength(2));
    });

    test('open-circuit regions are withheld until cool-down, then offered '
        'as half-open probes', () {
      final time = FakeTime();
      final pool = RelayPool(
        regions: [_region('eu-central')],
        clock: time.call,
        config: const RelayPoolConfig(
          probeInterval: Duration(seconds: 1),
          breaker: CircuitBreakerConfig(
            failureThreshold: 3,
            openDuration: Duration(seconds: 10),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        pool.reportFailure('eu-central');
      }

      // Stale per probeInterval, but the circuit is still open: withheld.
      time.advance(const Duration(seconds: 2));
      expect(pool.breakerStateOf('eu-central'), CircuitState.open);
      expect(pool.regionsDueForProbe(), isEmpty);

      // Cool-down elapsed: half-open breaker admits a trial probe.
      time.advance(const Duration(seconds: 9));
      expect(pool.breakerStateOf('eu-central'), CircuitState.halfOpen);
      expect(pool.regionsDueForProbe().map((r) => r.id), ['eu-central']);
    });
  });

  group('fromManifest (signed_config as single source of truth)', () {
    test('relayRegions [eu-central, us-east] build two regions with the '
        'builder-supplied URIs', () {
      final manifest = _manifest(relayRegions: ['eu-central', 'us-east']);
      final pool = RelayPool.fromManifest(
        manifest,
        regionUriBuilder: _urisFor,
        clock: FakeTime().call,
      );
      expect(pool.regions.map((r) => r.id), ['eu-central', 'us-east']);
      expect(pool.regions.first.uris, _urisFor('eu-central'));
      expect(pool.regions.last.uris, _urisFor('us-east'));
    });

    test('empty relayRegions fails pool creation (documented contract)', () {
      expect(
        () => RelayPool.fromManifest(_manifest(), regionUriBuilder: _urisFor),
        throwsArgumentError,
      );
    });

    test('priorityOf hook maps manifest region ids to priorities', () {
      final manifest = _manifest(relayRegions: ['eu-central', 'us-east']);
      final pool = RelayPool.fromManifest(
        manifest,
        regionUriBuilder: _urisFor,
        priorityOf: (id) => id == 'us-east' ? 9 : 0,
        clock: FakeTime().call,
      );
      expect(pool.selectRegion().id, 'us-east');
    });
  });

  group('credential glue (TurnCredentialsIssuer composition)', () {
    test('issued grant matches the pinned coturn use-auth-secret vector and '
        'carries the region URIs', () {
      final pool = RelayPool(
        regions: [_region('eu-central')],
        clock: FakeTime().call,
      );
      final issuer = TurnCredentialsIssuer(sharedSecret: 'north');
      final fixedNow = DateTime.utc(2026, 7, 16);

      final grant = wall.withClock(
        wall.Clock.fixed(fixedNow),
        () => pool.issueRelay(issuer: issuer, userId: 'alice'),
      );

      // Known vector from packages/security/test/turn_credentials_test.dart
      // (pinned via an independent reference implementation).
      expect(grant.credentials.username, '1784163600:alice');
      expect(grant.credentials.credential, 'kT+YbrLv/M7+b6yIQZRAeEnc244=');
      expect(grant.credentials.expiresAt, DateTime.utc(2026, 7, 16, 1));
      expect(
        grant.credentials.uris,
        _urisFor('eu-central').map((u) => u.toString()).toList(),
      );

      expect(grant.region.id, 'eu-central');
      expect(grant.iceServer.urls, _urisFor('eu-central'));
      expect(grant.iceServer.username, grant.credentials.username);
      expect(grant.iceServer.credential, grant.credentials.credential);
    });

    test('credentials expire exactly per the issuer TTL', () {
      final pool = RelayPool(
        regions: [_region('eu-central')],
        clock: FakeTime().call,
      );
      final issuer = TurnCredentialsIssuer(
        sharedSecret: 's3cret',
        ttl: const Duration(minutes: 30),
      );
      final fixedNow = DateTime.utc(2026, 1, 1, 12);

      final grant = wall.withClock(
        wall.Clock.fixed(fixedNow),
        () => pool.issueRelay(issuer: issuer, userId: 'bob'),
      );

      expect(grant.credentials.expiresAt, DateTime.utc(2026, 1, 1, 12, 30));
      expect(
        issuer.isExpired(
          grant.credentials,
          now: fixedNow.add(const Duration(minutes: 29, seconds: 59)),
        ),
        isFalse,
      );
      expect(
        issuer.isExpired(
          grant.credentials,
          now: fixedNow.add(const Duration(minutes: 30)),
        ),
        isTrue,
        reason: 'boundary is inclusive, matching the TURN server check',
      );
    });

    test('issueRelay honors failover: grants come from the selected healthy '
        'region', () {
      final pool = RelayPool(
        regions: [_region('eu-central'), _region('us-east')],
        clock: FakeTime().call,
        config: const RelayPoolConfig(
          breaker: CircuitBreakerConfig(failureThreshold: 3),
        ),
      );
      _warm(pool, 'eu-central', 50);
      _warm(pool, 'us-east', 80);
      final issuer = TurnCredentialsIssuer(sharedSecret: 's3cret');

      expect(
        pool.issueRelay(issuer: issuer, userId: 'carol').region.id,
        'eu-central',
      );

      for (var i = 0; i < 3; i++) {
        pool.reportFailure('eu-central');
      }
      final grant = pool.issueRelay(issuer: issuer, userId: 'carol');
      expect(grant.region.id, 'us-east');
      expect(grant.iceServer.urls, _urisFor('us-east'));
    });
  });
}
