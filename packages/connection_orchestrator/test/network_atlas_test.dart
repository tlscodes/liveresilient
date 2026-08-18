/// Pins the NetworkAtlas contract: hash-only persistence (raw labels
/// never serialized), Welford mean/stddev against hand-computed values,
/// the 3-sample hour-cell vs all-hours-aggregate fallback boundary,
/// JSON round-trip fidelity, and corrupt-JSON safety.
import 'dart:convert';

import 'package:connection_orchestrator/src/network_atlas.dart';
import 'package:test/test.dart';

void main() {
  group('privacy: hash-only persistence', () {
    test('serialized JSON never contains the raw network label', () {
      final atlas = NetworkAtlas();
      const label = 'HomeWiFi-5G-Behnam';
      atlas.record(
        networkLabel: label,
        nowMs: 1000,
        hourOfDay: 9,
        lossFraction: 0.1,
        rttMs: 80,
        deliveryRate: 0.9,
      );
      final encoded = jsonEncode(atlas.toJson());
      expect(encoded.contains(label), isFalse);
      expect(encoded.contains('HomeWiFi'), isFalse);
      expect(encoded.contains('Behnam'), isFalse);
      // The hash IS present — that is the stored identity.
      expect(encoded.contains(NetworkAtlas.identityHash(label)), isTrue);
    });

    test('identityHash is 16 hex chars, deterministic, label-sensitive', () {
      final a = NetworkAtlas.identityHash('CafeNet');
      final b = NetworkAtlas.identityHash('CafeNet');
      final c = NetworkAtlas.identityHash('CafeNet2');
      expect(a, hasLength(16));
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('Welford correctness', () {
    test('mean and population stddev match hand-computed 5-value series', () {
      // Series 100,110,120,130,140: mean 120,
      // population variance (400+100+0+100+400)/5 = 200, stddev sqrt(200).
      final atlas = NetworkAtlas();
      const rtts = [100.0, 110.0, 120.0, 130.0, 140.0];
      for (final r in rtts) {
        atlas.record(networkLabel: 'net', nowMs: 0, hourOfDay: 9, rttMs: r);
      }
      final f = atlas.forecast(networkLabel: 'net', hourOfDay: 9)!;
      expect(f.expectedRttMs, closeTo(120.0, 1e-9));
      expect(f.rttMsStddev, closeTo(14.142135623730951, 1e-9));
      expect(f.sampleCount, 5);
      // Metrics never recorded stay absent.
      expect(f.expectedLossFraction, isNull);
      expect(f.expectedDeliveryRate, isNull);
    });

    test('single sample has stddev 0, not NaN', () {
      final atlas = NetworkAtlas();
      atlas.record(
        networkLabel: 'net',
        nowMs: 0,
        hourOfDay: 3,
        lossFraction: 0.25,
      );
      // 1 cell sample < 3 -> aggregate path, which is the same lone cell.
      final f = atlas.forecast(networkLabel: 'net', hourOfDay: 3)!;
      expect(f.expectedLossFraction, closeTo(0.25, 1e-12));
      expect(f.lossFractionStddev, 0.0);
      expect(f.lossFractionStddev!.isNaN, isFalse);
    });
  });

  group('hour-cell vs aggregate fallback at the 3-sample boundary', () {
    test('cell with 2 samples falls back to the all-hours aggregate', () {
      final atlas = NetworkAtlas();
      // Hour 3: two samples (100, 110). Hour 5: three samples of 300.
      atlas.record(networkLabel: 'n', nowMs: 0, hourOfDay: 3, rttMs: 100);
      atlas.record(networkLabel: 'n', nowMs: 1, hourOfDay: 3, rttMs: 110);
      for (var i = 0; i < 3; i++) {
        atlas.record(networkLabel: 'n', nowMs: 2 + i, hourOfDay: 5, rttMs: 300);
      }
      final f = atlas.forecast(networkLabel: 'n', hourOfDay: 3)!;
      // Aggregate of all 5 samples: (100+110+900)/5 = 222.
      expect(f.expectedRttMs, closeTo(222.0, 1e-9));
      expect(f.sampleCount, 5);
    });

    test('cell reaching exactly 3 samples is used directly', () {
      final atlas = NetworkAtlas();
      atlas.record(networkLabel: 'n', nowMs: 0, hourOfDay: 3, rttMs: 100);
      atlas.record(networkLabel: 'n', nowMs: 1, hourOfDay: 3, rttMs: 110);
      for (var i = 0; i < 3; i++) {
        atlas.record(networkLabel: 'n', nowMs: 2 + i, hourOfDay: 5, rttMs: 300);
      }
      // Third sample at hour 3 crosses the boundary.
      atlas.record(networkLabel: 'n', nowMs: 10, hourOfDay: 3, rttMs: 120);
      final f = atlas.forecast(networkLabel: 'n', hourOfDay: 3)!;
      expect(f.expectedRttMs, closeTo(110.0, 1e-9));
      expect(f.sampleCount, 3);
    });

    test('unknown identity forecasts null', () {
      final atlas = NetworkAtlas();
      atlas.record(networkLabel: 'known', nowMs: 0, hourOfDay: 1, rttMs: 50);
      expect(atlas.forecast(networkLabel: 'never-seen', hourOfDay: 1), isNull);
    });

    test('hourOfDay outside 0..23 is clamped, not thrown on', () {
      final atlas = NetworkAtlas();
      for (var i = 0; i < 3; i++) {
        // 27 clamps to 23.
        atlas.record(networkLabel: 'n', nowMs: i, hourOfDay: 27, rttMs: 60);
      }
      final atTop = atlas.forecast(networkLabel: 'n', hourOfDay: 23)!;
      expect(atTop.expectedRttMs, closeTo(60.0, 1e-9));
      expect(atTop.sampleCount, 3);
      // -1 clamps to 0: empty cell there, so the aggregate answers.
      final atBottom = atlas.forecast(networkLabel: 'n', hourOfDay: -1)!;
      expect(atBottom.expectedRttMs, closeTo(60.0, 1e-9));
    });
  });

  group('JSON round-trip', () {
    test('restored atlas forecasts identically to the original', () {
      final atlas = NetworkAtlas();
      const rtts = [100.0, 110.0, 120.0, 130.0, 140.0];
      for (var i = 0; i < rtts.length; i++) {
        atlas.record(
          networkLabel: 'roundtrip-net',
          nowMs: i * 1000,
          hourOfDay: 21,
          lossFraction: 0.05 * i,
          rttMs: rtts[i],
          deliveryRate: 1.0 - 0.02 * i,
        );
      }
      // Through real JSON text, so num/int coercion is exercised too.
      final restored = NetworkAtlas.fromJson(
        jsonDecode(jsonEncode(atlas.toJson())) as Map<String, Object?>,
      );
      final a = atlas.forecast(networkLabel: 'roundtrip-net', hourOfDay: 21)!;
      final b = restored.forecast(
        networkLabel: 'roundtrip-net',
        hourOfDay: 21,
      )!;
      expect(b.expectedRttMs, closeTo(a.expectedRttMs!, 1e-9));
      expect(b.rttMsStddev, closeTo(a.rttMsStddev!, 1e-9));
      expect(b.expectedLossFraction, closeTo(a.expectedLossFraction!, 1e-9));
      expect(b.lossFractionStddev, closeTo(a.lossFractionStddev!, 1e-9));
      expect(b.expectedDeliveryRate, closeTo(a.expectedDeliveryRate!, 1e-9));
      expect(b.deliveryRateStddev, closeTo(a.deliveryRateStddev!, 1e-9));
      expect(b.sampleCount, a.sampleCount);
    });

    test('whole-number doubles surviving JSON as int still restore', () {
      // jsonEncode writes 120.0 as 120; fromJson must accept int for
      // any mean/m2 field via (v as num).toDouble().
      final hash = NetworkAtlas.identityHash('int-net');
      final atlas = NetworkAtlas.fromJson({
        'hourBuckets': 24,
        'identities': {
          hash: {
            '9': {
              'n': 3,
              'last': 5000,
              'loss': {'n': 3, 'mean': 0, 'm2': 0},
              'rtt': {'n': 3, 'mean': 120, 'm2': 200},
              'rate': {'n': 0, 'mean': 0, 'm2': 0},
            },
          },
        },
      });
      final f = atlas.forecast(networkLabel: 'int-net', hourOfDay: 9)!;
      expect(f.expectedRttMs, closeTo(120.0, 1e-9));
      expect(f.expectedLossFraction, closeTo(0.0, 1e-12));
      expect(f.expectedDeliveryRate, isNull);
    });
  });

  group('corrupt-JSON safety', () {
    test('malformed cells are dropped silently, healthy cells survive', () {
      final goodHash = NetworkAtlas.identityHash('good-net');
      final badHash = NetworkAtlas.identityHash('bad-net');
      final atlas = NetworkAtlas.fromJson({
        'hourBuckets': 24,
        'identities': {
          goodHash: {
            '9': {
              'n': 3,
              'last': 1,
              'loss': {'n': 0, 'mean': 0.0, 'm2': 0.0},
              'rtt': {'n': 3, 'mean': 100.0, 'm2': 0.0},
              'rate': {'n': 0, 'mean': 0.0, 'm2': 0.0},
            },
            // Negative sample count -> dropped.
            '10': {
              'n': -2,
              'last': 1,
              'loss': {'n': 0, 'mean': 0.0, 'm2': 0.0},
              'rtt': {'n': 3, 'mean': 100.0, 'm2': 0.0},
              'rate': {'n': 0, 'mean': 0.0, 'm2': 0.0},
            },
            // NaN mean -> dropped.
            '11': {
              'n': 3,
              'last': 1,
              'loss': {'n': 0, 'mean': 0.0, 'm2': 0.0},
              'rtt': {'n': 3, 'mean': double.nan, 'm2': 0.0},
              'rate': {'n': 0, 'mean': 0.0, 'm2': 0.0},
            },
            // Negative m2 -> dropped.
            '12': {
              'n': 3,
              'last': 1,
              'loss': {'n': 3, 'mean': 0.1, 'm2': -1.0},
              'rtt': {'n': 0, 'mean': 0.0, 'm2': 0.0},
              'rate': {'n': 0, 'mean': 0.0, 'm2': 0.0},
            },
            // Out-of-range hour key -> dropped.
            '99': {
              'n': 3,
              'last': 1,
              'loss': {'n': 0, 'mean': 0.0, 'm2': 0.0},
              'rtt': {'n': 3, 'mean': 100.0, 'm2': 0.0},
              'rate': {'n': 0, 'mean': 0.0, 'm2': 0.0},
            },
            // Wrong shapes -> dropped.
            '13': 'not a map',
            '14': {'n': 'three', 'last': 1},
          },
          badHash: 'entire identity is garbage',
        },
      });
      // The one healthy cell answers; nothing threw.
      final good = atlas.forecast(networkLabel: 'good-net', hourOfDay: 9)!;
      expect(good.expectedRttMs, closeTo(100.0, 1e-9));
      expect(good.sampleCount, 3);
      // Dropped hours contribute nothing: hour 10 falls back to the
      // aggregate, which contains only the healthy hour-9 cell.
      final fallback = atlas.forecast(networkLabel: 'good-net', hourOfDay: 10)!;
      expect(fallback.sampleCount, 3);
      expect(atlas.forecast(networkLabel: 'bad-net', hourOfDay: 9), isNull);
    });

    test('entirely non-atlas JSON restores to a fresh atlas, no throw', () {
      final empty = NetworkAtlas.fromJson({'something': 'else'});
      expect(empty.forecast(networkLabel: 'any', hourOfDay: 0), isNull);
      final alsoEmpty = NetworkAtlas.fromJson({
        'hourBuckets': 'twenty-four',
        'identities': [1, 2, 3],
      });
      expect(alsoEmpty.hourBuckets, 24);
      expect(alsoEmpty.forecast(networkLabel: 'any', hourOfDay: 0), isNull);
    });
  });

  group('hour-of-week refinement (v4)', () {
    test('a trained week cell beats the hour-of-day cell', () {
      final atlas = NetworkAtlas();
      // Same hour of day (9), two different week hours: Tuesday 9 (33)
      // sees loss 0.2, Saturday 9 (129) sees loss 0.6.
      for (var i = 0; i < 3; i++) {
        atlas.record(
          networkLabel: 'home',
          nowMs: i,
          hourOfDay: 9,
          hourOfWeek: 33,
          lossFraction: 0.2,
        );
      }
      for (var i = 0; i < 3; i++) {
        atlas.record(
          networkLabel: 'home',
          nowMs: 10 + i,
          hourOfDay: 9,
          hourOfWeek: 129,
          lossFraction: 0.6,
        );
      }
      // Week cell answers when asked with a week hour...
      final tuesday = atlas.forecast(
        networkLabel: 'home',
        hourOfDay: 9,
        hourOfWeek: 33,
      )!;
      expect(tuesday.expectedLossFraction, closeTo(0.2, 1e-12));
      expect(tuesday.sampleCount, 3);
      final saturday = atlas.forecast(
        networkLabel: 'home',
        hourOfDay: 9,
        hourOfWeek: 129,
      )!;
      expect(saturday.expectedLossFraction, closeTo(0.6, 1e-12));
      // ...and the v3 call shape still sees the pooled hour-of-day cell.
      final v3View = atlas.forecast(networkLabel: 'home', hourOfDay: 9)!;
      expect(v3View.expectedLossFraction, closeTo(0.4, 1e-12));
      expect(v3View.sampleCount, 6);
    });

    test('a thin week cell falls back to exactly the v3 chain', () {
      final atlas = NetworkAtlas();
      for (var i = 0; i < 3; i++) {
        atlas.record(
          networkLabel: 'home',
          nowMs: i,
          hourOfDay: 9,
          hourOfWeek: 33,
          lossFraction: 0.2,
        );
      }
      // Week hour 57 was seen 0 times; the hour-9 day cell (3 samples)
      // answers, exactly as a v3 caller would get.
      final fallback = atlas.forecast(
        networkLabel: 'home',
        hourOfDay: 9,
        hourOfWeek: 57,
      )!;
      expect(fallback.expectedLossFraction, closeTo(0.2, 1e-12));
      expect(fallback.sampleCount, 3);
    });

    test('week cells round-trip through JSON', () {
      final atlas = NetworkAtlas();
      for (var i = 0; i < 3; i++) {
        atlas.record(
          networkLabel: 'home',
          nowMs: i,
          hourOfDay: 9,
          hourOfWeek: 33,
          lossFraction: 0.2,
        );
      }
      final restored = NetworkAtlas.fromJson(
        jsonDecode(jsonEncode(atlas.toJson())) as Map<String, Object?>,
      );
      final week = restored.forecast(
        networkLabel: 'home',
        hourOfDay: 9,
        hourOfWeek: 33,
      )!;
      expect(week.expectedLossFraction, closeTo(0.2, 1e-12));
      expect(week.sampleCount, 3);
    });
  });

  group('network transitions (v4)', () {
    test('counts hops and forecasts the modal successor', () {
      final atlas = NetworkAtlas();
      atlas.recordTransition(fromLabel: 'wifi:home', toLabel: 'cell:tls');
      atlas.recordTransition(fromLabel: 'wifi:home', toLabel: 'cell:tls');
      atlas.recordTransition(fromLabel: 'wifi:home', toLabel: 'wifi:cafe');
      // Same-label hops are not hops.
      atlas.recordTransition(fromLabel: 'wifi:home', toLabel: 'wifi:home');
      final next = atlas.likelyNextNetwork(networkLabel: 'wifi:home')!;
      expect(next.toIdentityHash, NetworkAtlas.identityHash('cell:tls'));
      expect(next.transitionCount, 2);
      expect(next.totalTransitions, 3);
      expect(next.probability, closeTo(2 / 3, 1e-12));
      expect(atlas.likelyNextNetwork(networkLabel: 'cell:tls'), isNull);
    });

    test('successors are capped at 8, weakest evicted', () {
      final atlas = NetworkAtlas();
      // 'to0' gets 2 hops; to1..to8 get 1 each -> 9 successors, so the
      // weakest (one of the count-1 entries) leaves and to0 survives.
      atlas.recordTransition(fromLabel: 'from', toLabel: 'to0');
      atlas.recordTransition(fromLabel: 'from', toLabel: 'to0');
      for (var i = 1; i <= 8; i++) {
        atlas.recordTransition(fromLabel: 'from', toLabel: 'to$i');
      }
      final next = atlas.likelyNextNetwork(networkLabel: 'from')!;
      expect(next.toIdentityHash, NetworkAtlas.identityHash('to0'));
      expect(next.transitionCount, 2);
      // 8 successors kept: to0 (2 hops) + seven count-1 survivors.
      expect(next.totalTransitions, 9);
    });

    test('transitions round-trip and never leak a raw label', () {
      final atlas = NetworkAtlas();
      atlas.recordTransition(
        fromLabel: 'wifi:SecretHomeSSID',
        toLabel: 'cellular:secret-carrier',
      );
      final encoded = jsonEncode(atlas.toJson());
      expect(encoded.contains('SecretHomeSSID'), isFalse);
      expect(encoded.contains('secret-carrier'), isFalse);
      final restored = NetworkAtlas.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      );
      final next = restored.likelyNextNetwork(
        networkLabel: 'wifi:SecretHomeSSID',
      )!;
      expect(
        next.toIdentityHash,
        NetworkAtlas.identityHash('cellular:secret-carrier'),
      );
      expect(next.transitionCount, 1);
    });
  });
}
