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
}
