@Tags(['golden'])
library;

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/quality_gauge.dart';
import 'package:reference_app/src/ui/tokens.dart';

const String _bannerText =
    'Live voice degraded — voice-note mode keeps audio flowing';

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: buildAppThemeData(brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('qualityScore', () {
    test('null reading gives null (no invented needle)', () {
      expect(qualityScore(null), isNull);
    });

    test('empty reading (no rtt, no loss) gives null', () {
      expect(qualityScore(const CallQualityReading(at: Duration.zero)), isNull);
    });

    test('rtt=100 loss=0.01 scores high and bands good', () {
      const reading = CallQualityReading(
        at: Duration(seconds: 1),
        rttMs: 100,
        lossFraction: 0.01,
      );
      final score = qualityScore(reading);
      expect(score, isNotNull);
      expect(score, closeTo(1 - (100 / 1000) * 0.5 - (0.01 / 0.3) * 0.5, 1e-9));
      expect(bandOf(reading), QualityBand.good);
    });

    test('rtt=800 bands poor', () {
      const reading = CallQualityReading(
        at: Duration(seconds: 1),
        rttMs: 800,
        lossFraction: 0,
      );
      expect(bandOf(reading), QualityBand.poor);
      expect(qualityScore(reading), closeTo(0.6, 1e-9));
    });

    test('null rtt or loss contributes zero penalty', () {
      const reading = CallQualityReading(at: Duration.zero, rttMs: 200);
      expect(qualityScore(reading), closeTo(0.9, 1e-9));
    });

    test('extremes clamp to 0..1', () {
      expect(
        qualityScore(
          const CallQualityReading(
            at: Duration.zero,
            rttMs: 5000,
            lossFraction: 1,
          ),
        ),
        0,
      );
      expect(
        qualityScore(
          const CallQualityReading(
            at: Duration.zero,
            rttMs: 0,
            lossFraction: 0,
          ),
        ),
        1,
      );
    });
  });

  group('ladderStepOf', () {
    test('maps all 8 rungs to the right coarse step', () {
      expect(ladderStepOf(OperatingRung.fullVideo), LadderStep.hd);
      expect(ladderStepOf(OperatingRung.reducedVideo), LadderStep.sd);
      expect(ladderStepOf(OperatingRung.audioOnly), LadderStep.audio);
      for (final rung in [
        OperatingRung.lowRateVoice,
        OperatingRung.tokenVoiceFull,
        OperatingRung.tokenVoiceRow0,
        OperatingRung.voiceNotes,
        OperatingRung.textOnly,
      ]) {
        expect(ladderStepOf(rung), LadderStep.survival, reason: rung.name);
      }
    });
  });

  group('QualityGauge', () {
    testWidgets('renders the numbers and band from a real reading', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const QualityGauge(
            reading: CallQualityReading(
              at: Duration(seconds: 1),
              rttMs: 120,
              lossFraction: 0.02,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('120 ms'), findsOneWidget);
      expect(find.text('2.0% loss'), findsOneWidget);
      expect(find.text('good'), findsOneWidget);
    });

    testWidgets('renders dashes and no-signal with no reading', (tester) async {
      await tester.pumpWidget(wrap(const QualityGauge()));

      expect(find.text('—'), findsNWidgets(2));
      expect(find.text('no signal'), findsOneWidget);
    });
  });

  group('LadderRungIndicator', () {
    testWidgets('shows the exact rung name for every rung', (tester) async {
      for (final rung in OperatingRung.values) {
        await tester.pumpWidget(wrap(LadderRungIndicator(rung: rung)));
        expect(find.text(rung.name), findsOneWidget, reason: rung.name);
      }
    });

    testWidgets('always shows the four coarse step labels', (tester) async {
      await tester.pumpWidget(
        wrap(const LadderRungIndicator(rung: OperatingRung.tokenVoiceRow0)),
      );
      for (final label in ['HD', 'SD', 'Audio', 'Survival']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('tokenVoiceRow0'), findsOneWidget);
    });

    testWidgets('null rung shows the no-signal text', (tester) async {
      await tester.pumpWidget(wrap(const LadderRungIndicator(rung: null)));
      expect(find.text('no ladder signal'), findsOneWidget);
    });
  });

  group('VoiceNoteModeBanner', () {
    testWidgets('toggles by active', (tester) async {
      await tester.pumpWidget(wrap(const VoiceNoteModeBanner(active: false)));
      expect(find.text(_bannerText), findsNothing);

      await tester.pumpWidget(wrap(const VoiceNoteModeBanner(active: true)));
      await tester.pumpAndSettle();
      expect(find.text(_bannerText), findsOneWidget);
      expect(find.byIcon(Icons.voicemail), findsOneWidget);
    });
  });

  group('goldens', () {
    const reading = CallQualityReading(
      at: Duration(seconds: 3),
      rttMs: 140,
      lossFraction: 0.02,
      bitrateBps: 32000,
    );

    testWidgets('gauge light', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const QualityGauge(reading: reading)));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/gauge_light.png'),
      );
    });

    testWidgets('gauge dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(const QualityGauge(reading: reading), brightness: Brightness.dark),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/gauge_dark.png'),
      );
    });
  });
}
