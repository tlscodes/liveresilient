import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

QualitySignals _sig({
  PacketLossBucket loss = PacketLossBucket.low,
  RttBucket rtt = RttBucket.low,
  bool gateway = true,
  bool peers = false,
}) => QualitySignals(
  loss: loss,
  rtt: rtt,
  gatewayReachable: gateway,
  localPeersReachable: peers,
);

final _healthy = _sig();
final _constrained = _sig(loss: PacketLossBucket.elevated);
final _offlineWithPeers = _sig(gateway: false, peers: true);

void main() {
  group('classify (raw signal → profile table)', () {
    test('gateway up, low loss/rtt → healthy', () {
      expect(
        NetworkQualityPolicy.classify(_healthy),
        NetworkQualityProfile.healthy,
      );
    });

    test('elevated loss OR elevated rtt → constrained', () {
      expect(
        NetworkQualityPolicy.classify(_sig(loss: PacketLossBucket.elevated)),
        NetworkQualityProfile.constrained,
      );
      expect(
        NetworkQualityPolicy.classify(_sig(rtt: RttBucket.elevated)),
        NetworkQualityProfile.constrained,
      );
    });

    test('heavy loss OR high rtt → degraded (even with peers around)', () {
      expect(
        NetworkQualityPolicy.classify(_sig(loss: PacketLossBucket.heavy)),
        NetworkQualityProfile.degraded,
      );
      expect(
        NetworkQualityPolicy.classify(_sig(rtt: RttBucket.high, peers: true)),
        NetworkQualityProfile.degraded,
      );
    });

    test('locallyConnected gate requires gateway DOWN and peers UP — both', () {
      // Gate satisfied: no gateway, local peers reachable.
      expect(
        NetworkQualityPolicy.classify(_offlineWithPeers),
        NetworkQualityProfile.locallyConnected,
      );
      // Gateway reachable → never locallyConnected, peers or not.
      expect(
        NetworkQualityPolicy.classify(_sig(peers: true)),
        NetworkQualityProfile.healthy,
      );
      // Fully offline (no peers) → degraded, not locallyConnected.
      expect(
        NetworkQualityPolicy.classify(_sig(gateway: false)),
        NetworkQualityProfile.degraded,
      );
    });

    test('offline classification ignores loss/rtt buckets', () {
      expect(
        NetworkQualityPolicy.classify(
          _sig(
            loss: PacketLossBucket.heavy,
            rtt: RttBucket.high,
            gateway: false,
            peers: true,
          ),
        ),
        NetworkQualityProfile.locallyConnected,
      );
    });
  });

  group('knob table (every row asserted)', () {
    test('healthy row', () {
      final k = NetworkQualityPolicy.knobsFor(NetworkQualityProfile.healthy);
      expect(k.retryLimit, 2);
      expect(k.operationTimeout, const Duration(seconds: 5));
      expect(k.mediaMode, MediaModeRung.fullVideo);
      expect(k.relayPreference, RelayPreference.preferDirect);
      expect(k.telemetrySamplingRate, 1.0);
      expect(k.batteryBudgetHint, 1.0);
    });

    test('constrained row', () {
      final k = NetworkQualityPolicy.knobsFor(
        NetworkQualityProfile.constrained,
      );
      expect(k.retryLimit, 3);
      expect(k.operationTimeout, const Duration(seconds: 8));
      expect(k.mediaMode, MediaModeRung.reducedVideo);
      expect(k.relayPreference, RelayPreference.preferRelay);
      expect(k.telemetrySamplingRate, 0.5);
      expect(k.batteryBudgetHint, 0.6);
    });

    test('degraded row', () {
      final k = NetworkQualityPolicy.knobsFor(NetworkQualityProfile.degraded);
      expect(k.retryLimit, 4);
      expect(k.operationTimeout, const Duration(seconds: 12));
      expect(k.mediaMode, MediaModeRung.audioOnly);
      expect(k.relayPreference, RelayPreference.preferRelay);
      expect(k.telemetrySamplingRate, 0.25);
      expect(k.batteryBudgetHint, 0.35);
    });

    test('locallyConnected row', () {
      final k = NetworkQualityPolicy.knobsFor(
        NetworkQualityProfile.locallyConnected,
      );
      expect(k.retryLimit, 6);
      expect(k.operationTimeout, const Duration(seconds: 15));
      expect(k.mediaMode, MediaModeRung.audioOnly);
      expect(k.relayPreference, RelayPreference.localOnly);
      expect(k.telemetrySamplingRate, 0.1);
      expect(k.batteryBudgetHint, 0.2);
    });

    test(
      'NetworkQualityProfile.values exact declaration order is pinned — '
      'the hysteresis escalate/recover decision in observe() relies on '
      '.index severity ordering, so an accidental reorder must fail loudly',
      () {
        expect(NetworkQualityProfile.values, [
          NetworkQualityProfile.healthy,
          NetworkQualityProfile.constrained,
          NetworkQualityProfile.degraded,
          NetworkQualityProfile.locallyConnected,
        ]);
      },
    );

    test('telemetry sampling spans the blueprint 1.0 → 0.1 range and '
        'every knob degrades monotonically with severity', () {
      final rows = [
        for (final p in NetworkQualityProfile.values)
          NetworkQualityPolicy.knobsFor(p),
      ];
      expect(rows.first.telemetrySamplingRate, 1.0);
      expect(rows.last.telemetrySamplingRate, 0.1);
      for (var i = 1; i < rows.length; i++) {
        expect(rows[i].retryLimit, greaterThan(rows[i - 1].retryLimit));
        expect(
          rows[i].operationTimeout,
          greaterThan(rows[i - 1].operationTimeout),
        );
        expect(
          rows[i].telemetrySamplingRate,
          lessThan(rows[i - 1].telemetrySamplingRate),
        );
        expect(
          rows[i].batteryBudgetHint,
          lessThan(rows[i - 1].batteryBudgetHint),
        );
        expect(
          rows[i].mediaMode.index,
          greaterThanOrEqualTo(rows[i - 1].mediaMode.index),
        );
      }
    });

    test('knobs getter reflects the live profile', () {
      final policy = NetworkQualityPolicy(
        initialProfile: NetworkQualityProfile.degraded,
      );
      expect(policy.knobs.mediaMode, MediaModeRung.audioOnly);
      expect(policy.knobs.retryLimit, 4);
    });
  });

  group('hysteresis (anti-flapping, dwell-time margin)', () {
    const config = NetworkQualityPolicyConfig(
      escalateHold: Duration(seconds: 2),
      recoverHold: Duration(seconds: 5),
    );

    test('worse candidate adopted only after escalateHold persists', () {
      final policy = NetworkQualityPolicy(config: config);
      expect(
        policy.observe(_constrained, nowMs: 0),
        NetworkQualityProfile.healthy,
      );
      expect(
        policy.observe(_constrained, nowMs: 1999),
        NetworkQualityProfile.healthy,
        reason: 'dwell not yet reached',
      );
      expect(
        policy.observe(_constrained, nowMs: 2000),
        NetworkQualityProfile.constrained,
      );
    });

    test('a raw flip back to the current profile restarts the dwell', () {
      final policy = NetworkQualityPolicy(config: config);
      policy.observe(_constrained, nowMs: 0);
      policy.observe(_healthy, nowMs: 1000); // candidate cleared
      policy.observe(_constrained, nowMs: 1500); // dwell restarts here
      expect(
        policy.observe(_constrained, nowMs: 3400),
        NetworkQualityProfile.healthy,
        reason: '1500 + 2000ms escalate dwell not yet reached',
      );
      expect(
        policy.observe(_constrained, nowMs: 3500),
        NetworkQualityProfile.constrained,
      );
    });

    test('a different candidate also restarts the dwell', () {
      final policy = NetworkQualityPolicy(config: config);
      policy.observe(_constrained, nowMs: 0);
      // Candidate switches constrained → degraded: clock restarts.
      policy.observe(_sig(loss: PacketLossBucket.heavy), nowMs: 1900);
      expect(policy.profile, NetworkQualityProfile.healthy);
      expect(
        policy.observe(_sig(loss: PacketLossBucket.heavy), nowMs: 3800),
        NetworkQualityProfile.healthy,
      );
      expect(
        policy.observe(_sig(loss: PacketLossBucket.heavy), nowMs: 3900),
        NetworkQualityProfile.degraded,
      );
    });

    test('bounded switch count under oscillating signals (Random(7))', () {
      final rng = Random(7);
      final policy = NetworkQualityPolicy(config: config);
      var last = policy.profile;
      var stableTransitions = 0;
      var rawChanges = 0;
      var lastRaw = NetworkQualityPolicy.classify(_healthy);

      // 400 observations at 500ms cadence (~200s), raw profile flipping
      // randomly between healthy and constrained.
      for (var i = 0; i < 400; i++) {
        final signals = rng.nextBool() ? _healthy : _constrained;
        final raw = NetworkQualityPolicy.classify(signals);
        if (raw != lastRaw) rawChanges++;
        lastRaw = raw;

        final stable = policy.observe(signals, nowMs: i * 500);
        if (stable != last) stableTransitions++;
        last = stable;
      }

      expect(
        rawChanges,
        greaterThan(100),
        reason: 'the raw signal really is oscillating hard',
      );
      expect(
        stableTransitions,
        lessThanOrEqualTo(rawChanges ~/ 10),
        reason: 'hysteresis must suppress flapping on oscillating signals',
      );
    });

    test('gateway loss → locallyConnected → gateway return → recovers, '
        'each direction behind its hysteresis delay', () {
      final policy = NetworkQualityPolicy(config: config);
      // Warm steady healthy operation.
      for (var t = 0; t <= 10000; t += 1000) {
        expect(
          policy.observe(_healthy, nowMs: t),
          NetworkQualityProfile.healthy,
        );
      }

      // Gateway disappears; local peers reachable. Escalation waits out
      // the 2s dwell, then local-only mode engages.
      expect(
        policy.observe(_offlineWithPeers, nowMs: 11000),
        NetworkQualityProfile.healthy,
      );
      expect(
        policy.observe(_offlineWithPeers, nowMs: 12500),
        NetworkQualityProfile.healthy,
      );
      expect(
        policy.observe(_offlineWithPeers, nowMs: 13000),
        NetworkQualityProfile.locallyConnected,
      );
      expect(
        policy.toConditionProfile(),
        NetworkConditionProfile.isolated,
        reason: 'PathSelector bridge must report isolated while local-only',
      );
      expect(policy.knobs.relayPreference, RelayPreference.localOnly);

      // Gateway returns. Recovery is deliberately slower (5s dwell).
      expect(
        policy.observe(_healthy, nowMs: 14000),
        NetworkQualityProfile.locallyConnected,
      );
      expect(
        policy.observe(_healthy, nowMs: 18500),
        NetworkQualityProfile.locallyConnected,
        reason: '14000 + 5000ms recover dwell not yet reached',
      );
      expect(
        policy.observe(_healthy, nowMs: 19000),
        NetworkQualityProfile.healthy,
      );
      expect(policy.toConditionProfile(), NetworkConditionProfile.stable);
    });

    test('zero holds degrade to immediate (hysteresis disabled)', () {
      final policy = NetworkQualityPolicy(
        config: const NetworkQualityPolicyConfig(
          escalateHold: Duration.zero,
          recoverHold: Duration.zero,
        ),
      );
      expect(
        policy.observe(_constrained, nowMs: 0),
        NetworkQualityProfile.constrained,
      );
      expect(policy.observe(_healthy, nowMs: 1), NetworkQualityProfile.healthy);
    });
  });

  group('bridge to NetworkConditionProfile (PathSelector integration)', () {
    test('mapping table: healthy→stable, constrained→congested, '
        'degraded→degraded, locallyConnected→isolated', () {
      const expected = {
        NetworkQualityProfile.healthy: NetworkConditionProfile.stable,
        NetworkQualityProfile.constrained: NetworkConditionProfile.congested,
        NetworkQualityProfile.degraded: NetworkConditionProfile.degraded,
        NetworkQualityProfile.locallyConnected:
            NetworkConditionProfile.isolated,
      };
      for (final entry in expected.entries) {
        expect(
          NetworkQualityPolicy.conditionProfileFor(entry.key),
          entry.value,
          reason: '${entry.key.name} must bridge to ${entry.value.name}',
        );
      }
    });

    test('retryLimit stays aligned with bridged redundancy maxFailover', () {
      for (final p in NetworkQualityProfile.values) {
        final knobs = NetworkQualityPolicy.knobsFor(p);
        final redundancy = NetworkQualityPolicy(
          initialProfile: p,
        ).toConditionPolicy().redundancy();
        expect(
          knobs.retryLimit,
          redundancy.maxFailover,
          reason: 'policy and router must agree on persistence for ${p.name}',
        );
      }
    });

    test('one-call PathSelector integration via applyPolicy', () {
      final selector = PathSelector(const []);
      final policy = NetworkQualityPolicy(
        initialProfile: NetworkQualityProfile.locallyConnected,
      );
      selector.applyPolicy(policy.toConditionPolicy());
      expect(selector.config.maxFailover, 6);
      expect(selector.config.fanout, 3);
    });
  });

  group('validation', () {
    test('negative holds are rejected at construction', () {
      expect(
        () => NetworkQualityPolicy(
          config: const NetworkQualityPolicyConfig(
            escalateHold: Duration(milliseconds: -1),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => NetworkQualityPolicy(
          config: const NetworkQualityPolicyConfig(
            recoverHold: Duration(milliseconds: -1),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('nowMs must be monotonic (equal is allowed, backwards throws)', () {
      final policy = NetworkQualityPolicy();
      policy.observe(_healthy, nowMs: 1000);
      expect(
        policy.observe(_healthy, nowMs: 1000),
        NetworkQualityProfile.healthy,
      );
      expect(() => policy.observe(_healthy, nowMs: 999), throwsArgumentError);
    });
  });
}
