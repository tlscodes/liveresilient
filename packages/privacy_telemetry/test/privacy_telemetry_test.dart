import 'dart:async';

import 'package:privacy_telemetry/privacy_telemetry.dart';
import 'package:test/test.dart';

class FakeConsent implements TelemetryConsent {
  @override
  bool granted;

  FakeConsent({this.granted = true});
}

class FakeExporter implements TelemetryExporter {
  final List<TelemetrySnapshot> exported = [];
  bool shouldThrow = false;

  @override
  Future<void> exportAggregates(TelemetrySnapshot snapshot) async {
    if (shouldThrow) {
      throw StateError('export failed');
    }
    exported.add(snapshot);
  }
}

/// Exporter with an artificial delay, for pinning overlapping-exportNow()
/// behavior.
class _SlowFakeExporter implements TelemetryExporter {
  final List<TelemetrySnapshot> exported = [];

  @override
  Future<void> exportAggregates(TelemetrySnapshot snapshot) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    exported.add(snapshot);
  }
}

/// Minimal fake [Timer]: tracks whether [cancel] was called, does nothing
/// else. Used with [PrivacyTelemetry]'s `timerFactory` override so the
/// periodic auto-export path can be driven deterministically in tests.
class _FakeTimer implements Timer {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void main() {
  group('PrivacyTelemetry', () {
    late FakeConsent consent;
    late FakeExporter exporter;
    late PrivacyTelemetry telemetry;

    setUp(() {
      consent = FakeConsent(granted: false);
      exporter = FakeExporter();
      telemetry = PrivacyTelemetry(
        consent: consent,
        exporter: exporter,
        appVersion: '2.0.0-test',
        // A real 6h periodic export timer must not leak past this test;
        // dispose() in tearDown cancels it, this just keeps it from ever
        // firing during the (sub-second) test run.
        exportInterval: const Duration(days: 365),
      );
    });

    tearDown(() async {
      await telemetry.dispose();
    });

    test(
      'without consent, recordEvent/recordMetric/exportNow are all no-ops',
      () async {
        telemetry.recordEvent(TelemetryEvent.callAttempted);
        telemetry.recordMetric(TelemetryMetric.callSetupTimeMs, 100);
        await telemetry.exportNow();

        expect(telemetry.snapshot().isEmpty, isTrue);
        expect(exporter.exported, isEmpty);
      },
    );

    test('once consent is granted, events and metrics are recorded', () {
      consent.granted = true;

      telemetry.recordEvent(TelemetryEvent.callAttempted);
      telemetry.recordEvent(TelemetryEvent.callAttempted);

      final snapshot = telemetry.snapshot();
      expect(snapshot.counters['callAttempted'], 2);
    });

    test('revoking consent mid-session immediately stops recording', () {
      consent.granted = true;
      telemetry.recordEvent(TelemetryEvent.callAttempted);

      consent.granted = false;
      telemetry.recordEvent(TelemetryEvent.callAttempted);
      telemetry.recordMetric(TelemetryMetric.callSetupTimeMs, 50);

      final snapshot = telemetry.snapshot();
      expect(snapshot.counters['callAttempted'], 1);
      expect(snapshot.histograms, isEmpty);
    });

    test(
      'a value exactly at a bucket boundary lands in the <= boundary bucket',
      () {
        consent.granted = true;

        // callSetupTimeMs boundaries: [500, 1000, 2000, 5000, 10000, 30000].
        telemetry.recordMetric(TelemetryMetric.callSetupTimeMs, 500);

        final snapshot = telemetry.snapshot();
        final buckets = snapshot.histograms['callSetupTimeMs']!;
        expect(buckets['500'], 1);
        expect(buckets.containsKey('inf'), isFalse);
      },
    );

    test(
      'exportNow failure retains aggregates; a later success clears them',
      () async {
        consent.granted = true;
        telemetry.recordEvent(TelemetryEvent.callAttempted);

        exporter.shouldThrow = true;
        await telemetry.exportNow();

        expect(
          telemetry.snapshot().isEmpty,
          isFalse,
          reason: 'a failed export must not drop local aggregates',
        );
        expect(exporter.exported, isEmpty);

        exporter.shouldThrow = false;
        await telemetry.exportNow();

        expect(telemetry.snapshot().isEmpty, isTrue);
        expect(exporter.exported, hasLength(1));
      },
    );

    test('snapshot.toJson exposes only aggregate counters/histograms', () {
      consent.granted = true;
      telemetry.recordEvent(TelemetryEvent.callAttempted);
      telemetry.recordMetric(TelemetryMetric.callSetupTimeMs, 500);

      final json = telemetry.snapshot().toJson();

      expect(json['schemaVersion'], 1);
      expect(json['appVersion'], '2.0.0-test');
      expect(json['counters'], {'callAttempted': 1});
      expect(json['histograms'], {
        'callSetupTimeMs': {'500': 1},
      });
    });

    test('purgeLocalData empties all locally held aggregates', () {
      consent.granted = true;
      telemetry.recordEvent(TelemetryEvent.callAttempted);
      telemetry.recordMetric(TelemetryMetric.callSetupTimeMs, 100);

      telemetry.purgeLocalData();

      expect(telemetry.snapshot().isEmpty, isTrue);
    });
  });

  group('PrivacyTelemetry auto-export timer', () {
    test('a fake timerFactory captures the callback; firing it triggers an '
        'export via the fake exporter, and firing after dispose() does '
        'nothing', () async {
      void Function()? capturedCallback;
      var factoryCalls = 0;
      final fakeTimer = _FakeTimer();

      final consent = FakeConsent(granted: true);
      final exporter = FakeExporter();
      final telemetry = PrivacyTelemetry(
        consent: consent,
        exporter: exporter,
        appVersion: '2.0.0-test',
        exportInterval: const Duration(minutes: 1),
        timerFactory: (duration, callback) {
          factoryCalls++;
          expect(duration, const Duration(minutes: 1));
          capturedCallback = callback;
          return fakeTimer;
        },
      );

      expect(
        factoryCalls,
        1,
        reason: 'the factory must be used instead of a real Timer.periodic',
      );
      expect(capturedCallback, isNotNull);

      telemetry.recordEvent(TelemetryEvent.callAttempted);
      capturedCallback!();
      await Future<void>.delayed(Duration.zero);

      expect(exporter.exported, hasLength(1));
      expect(exporter.exported.single.counters['callAttempted'], 1);

      // A second event, left unexported, pending across dispose().
      telemetry.recordEvent(TelemetryEvent.callConnected);
      await telemetry.dispose();

      expect(fakeTimer.cancelled, isTrue);

      // Firing the (still-held) callback after dispose must not export:
      // exportNow() is a no-op once _disposed is set.
      capturedCallback!();
      await Future<void>.delayed(Duration.zero);
      expect(exporter.exported, hasLength(1));
    });
  });

  group('PrivacyTelemetry.exportNow re-entrancy', () {
    test('overlapping exportNow() calls with a slow exporter both succeed '
        '(pins current behavior: no re-entrancy guard, so an event recorded '
        'while the first export is in flight can be captured and sent by '
        'both calls)', () async {
      final consent = FakeConsent(granted: true);
      final exporter = _SlowFakeExporter();
      final telemetry = PrivacyTelemetry(
        consent: consent,
        exporter: exporter,
        appVersion: '2.0.0-test',
        exportInterval: const Duration(days: 365),
      );

      telemetry.recordEvent(TelemetryEvent.callAttempted);
      final first = telemetry.exportNow();

      // Recorded before the first export's snapshot has been cleared —
      // both calls' snapshot() reads see it.
      telemetry.recordEvent(TelemetryEvent.callConnected);
      final second = telemetry.exportNow();

      await Future.wait([first, second]);

      expect(exporter.exported, hasLength(2));
      expect(exporter.exported[0].counters['callAttempted'], 1);
      expect(exporter.exported[0].counters['callConnected'], isNull);
      expect(exporter.exported[1].counters['callAttempted'], 1);
      expect(exporter.exported[1].counters['callConnected'], 1);

      await telemetry.dispose();
    });
  });

  group('phase 10 allowlist extensions', () {
    late FakeConsent consent;
    late FakeExporter exporter;
    late PrivacyTelemetry telemetry;

    PrivacyTelemetry build({
      String appVersion = '2.1.0',
      String osVersion = 'ios-17.4',
      Set<String> allowedRegions = const {'eu-central', 'us-east'},
    }) => PrivacyTelemetry(
      consent: consent,
      exporter: exporter,
      appVersion: appVersion,
      osVersion: osVersion,
      allowedRegions: allowedRegions,
      exportInterval: const Duration(days: 365),
    );

    setUp(() {
      consent = FakeConsent(granted: true);
      exporter = FakeExporter();
      telemetry = build();
    });

    tearDown(() async {
      await telemetry.dispose();
    });

    test('new metrics use exactly the pinned bucket boundaries', () {
      // These lists ARE the privacy review: changing a boundary is a
      // reviewed code change, so the test pins them exactly.
      const pinned = <TelemetryMetric, List<int>>{
        TelemetryMetric.rttMsBucket: [50, 100, 200, 400, 800, 1600],
        TelemetryMetric.jitterMsBucket: [10, 20, 50, 100, 250],
        TelemetryMetric.packetLossPctBucket: [1, 2, 5, 10, 25],
        TelemetryMetric.bitrateKbpsBucket: [16, 32, 64, 128, 256, 512],
      };

      for (final entry in pinned.entries) {
        final metric = entry.key;
        final boundaries = entry.value;
        // One observation exactly at each boundary -> one count in exactly
        // that bucket; one observation above the last boundary -> 'inf'.
        for (final boundary in boundaries) {
          telemetry.recordMetric(metric, boundary);
        }
        telemetry.recordMetric(metric, boundaries.last + 1);

        final buckets = telemetry.snapshot().histograms[metric.name]!;
        expect(buckets, {
          for (final boundary in boundaries) '$boundary': 1,
          'inf': 1,
        }, reason: '$metric boundary math must match the pinned list');
      }
    });

    test('a value just above a boundary lands in the next bucket', () {
      // rttMsBucket boundaries: [50, 100, 200, 400, 800, 1600].
      telemetry.recordMetric(TelemetryMetric.rttMsBucket, 51);
      final buckets = telemetry.snapshot().histograms['rttMsBucket']!;
      expect(buckets, {'100': 1});
    });

    test('ICE candidate type outcomes are three distinct counter events', () {
      telemetry.recordEvent(TelemetryEvent.iceSelectedHost);
      telemetry.recordEvent(TelemetryEvent.iceSelectedSrflx);
      telemetry.recordEvent(TelemetryEvent.iceSelectedRelay);
      telemetry.recordEvent(TelemetryEvent.iceSelectedRelay);

      final counters = telemetry.snapshot().counters;
      expect(counters['iceSelectedHost'], 1);
      expect(counters['iceSelectedSrflx'], 1);
      expect(counters['iceSelectedRelay'], 2);
    });

    test('failure categories are enum-valued events, never strings', () {
      telemetry.recordEvent(TelemetryEvent.failureSignaling);
      telemetry.recordEvent(TelemetryEvent.failureIce);
      telemetry.recordEvent(TelemetryEvent.failureMedia);
      telemetry.recordEvent(TelemetryEvent.failureAuth);

      final counters = telemetry.snapshot().counters;
      expect(counters['failureSignaling'], 1);
      expect(counters['failureIce'], 1);
      expect(counters['failureMedia'], 1);
      expect(counters['failureAuth'], 1);
    });

    test('codec ids come from the pinned closed enum set only', () {
      expect(TelemetryCodec.values.map((c) => c.name), [
        'opus',
        'pcmu',
        'pcma',
        'g722',
        'vp8',
        'vp9',
        'h264',
        'av1',
      ]);

      telemetry.recordCodec(TelemetryCodec.opus);
      telemetry.recordCodec(TelemetryCodec.opus);
      telemetry.recordCodec(TelemetryCodec.vp8);

      final counters = telemetry.snapshot().counters;
      expect(counters['codec.opus'], 2);
      expect(counters['codec.vp8'], 1);
    });

    test('region: only members of the closed allowedRegions set count', () {
      telemetry.recordRegion('eu-central');
      telemetry.recordRegion('eu-central');
      telemetry.recordRegion('us-east');

      final counters = telemetry.snapshot().counters;
      expect(counters['region.eu-central'], 2);
      expect(counters['region.us-east'], 1);
    });

    test('region: format-valid but non-allowlisted ids are dropped', () {
      // Matches ^[a-z0-9-]{1,32}$ but is NOT in the closed set — e.g. a
      // bug that funnels a bare digit string (phone-shaped) in here.
      telemetry.recordRegion('us-west');
      telemetry.recordRegion('0301234567');

      expect(telemetry.snapshot().counters, isEmpty);
    });

    test('region: format-invalid ids (IP, city, uppercase) are dropped', () {
      telemetry.recordRegion('192.168.1.7');
      telemetry.recordRegion('Berlin');
      telemetry.recordRegion('+49 30 123456');
      telemetry.recordRegion('eu central');
      telemetry.recordRegion('');
      telemetry.recordRegion('a' * 33);

      expect(telemetry.snapshot().counters, isEmpty);
    });

    test('constructor rejects allowedRegions outside the id format', () async {
      expect(() => build(allowedRegions: {'EU_Central'}), throwsArgumentError);
      expect(
        () => build(allowedRegions: {'52.5200,13.4050'}),
        throwsArgumentError,
      );
    });

    test('constructor rejects app/OS versions shaped like secrets/PII', () {
      // An access token, an email, an SDP fragment — none can even be
      // constructed into the schema's only free-text fields.
      expect(
        () => build(appVersion: 'Bearer eyJhbGciOiJIUzI1NiJ9.x.y' * 2),
        throwsArgumentError,
      );
      expect(() => build(appVersion: 'alice@example.com'), throwsArgumentError);
      expect(
        () => build(osVersion: 'c=IN IP4 198.51.100.7 a=candidate:1'),
        throwsArgumentError,
      );
      expect(() => build(appVersion: ''), throwsArgumentError);
    });

    test('snapshot schema is counters+histograms only and unmodifiable', () {
      telemetry.recordEvent(TelemetryEvent.iceSelectedRelay);
      telemetry.recordCodec(TelemetryCodec.opus);
      telemetry.recordRegion('eu-central');
      telemetry.recordMetric(TelemetryMetric.rttMsBucket, 80);

      final snapshot = telemetry.snapshot();
      final json = snapshot.toJson();

      // Exact top-level shape: no field exists that could carry a token,
      // an SDP blob, a phone number, or a raw IP.
      expect(json.keys.toSet(), {
        'schemaVersion',
        'appVersion',
        'osVersion',
        'counters',
        'histograms',
      });

      // Counter values are pure occurrence counts; keys come from enum
      // names / pinned prefixes only.
      final counters = json['counters']! as Map<String, int>;
      final keyFormat = RegExp(r'^[a-zA-Z0-9.-]+$');
      for (final entry in counters.entries) {
        expect(keyFormat.hasMatch(entry.key), isTrue);
      }
      final histograms = json['histograms']! as Map<String, Map<String, int>>;
      final bucketKeyFormat = RegExp(r'^(\d+|inf)$');
      for (final buckets in histograms.values) {
        for (final key in buckets.keys) {
          expect(bucketKeyFormat.hasMatch(key), isTrue);
        }
      }

      // The aggregate maps cannot be extended after the fact.
      expect(() => snapshot.counters['x'] = 1, throwsUnsupportedError);
      expect(
        () => snapshot.histograms['rttMsBucket']!['x'] = 1,
        throwsUnsupportedError,
      );
    });

    test('without consent, the new record APIs are all no-ops', () {
      consent.granted = false;

      telemetry.recordEvent(TelemetryEvent.failureIce);
      telemetry.recordCodec(TelemetryCodec.opus);
      telemetry.recordRegion('eu-central');
      telemetry.recordMetric(TelemetryMetric.jitterMsBucket, 15);

      expect(telemetry.snapshot().isEmpty, isTrue);
    });

    test('consent revoke + purge discards codec/region/new-metric data', () {
      telemetry.recordEvent(TelemetryEvent.iceSelectedHost);
      telemetry.recordCodec(TelemetryCodec.opus);
      telemetry.recordRegion('us-east');
      telemetry.recordMetric(TelemetryMetric.packetLossPctBucket, 3);

      consent.granted = false;
      telemetry.purgeLocalData();

      expect(telemetry.snapshot().isEmpty, isTrue);
    });

    test('successful export clears codec/region aggregates too', () async {
      telemetry.recordCodec(TelemetryCodec.av1);
      telemetry.recordRegion('eu-central');

      await telemetry.exportNow();

      expect(exporter.exported, hasLength(1));
      expect(exporter.exported.single.counters['codec.av1'], 1);
      expect(exporter.exported.single.counters['region.eu-central'], 1);
      expect(telemetry.snapshot().isEmpty, isTrue);
    });
  });
}
