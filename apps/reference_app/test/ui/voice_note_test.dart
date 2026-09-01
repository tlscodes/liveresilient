/// Widget + golden coverage for the voice-note UI pair (recorder overlay +
/// player bar).
///
/// Determinism notes:
///  * [AppMotion.ambientEnabled] is false under `flutter test`, so the
///    recording pulse never starts and every `pumpAndSettle` here settles.
///  * The recorder is fed from a local [StreamController] — the widget
///    renders whatever amplitude stream it is given.
///  * Seek assertions use LOGICAL fractions: the same physical tap point
///    must report a mirrored fraction under RTL.
@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/tokens.dart';
import 'package:reference_app/src/ui/voice_note.dart';

Future<void> pumpHost(
  WidgetTester tester, {
  required Widget child,
  Brightness brightness = Brightness.light,
  bool rtl = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final home = Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: child,
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppThemeData(brightness),
      home: rtl
          ? Directionality(textDirection: TextDirection.rtl, child: home)
          : home,
    ),
  );
}

void main() {
  group('voiceClockLabel', () {
    test('formats m:ss with zero-padded seconds', () {
      expect(voiceClockLabel(Duration.zero), '0:00');
      expect(voiceClockLabel(const Duration(seconds: 7)), '0:07');
      expect(voiceClockLabel(const Duration(seconds: 65)), '1:05');
      expect(voiceClockLabel(const Duration(seconds: 3661)), '61:01');
      // Clock skew must never render a negative label.
      expect(voiceClockLabel(const Duration(seconds: -3)), '0:00');
    });
  });

  group('decorativeWaveformPeaks', () {
    test('is deterministic per byte content and stays in 0..1', () {
      final bytes = List<int>.generate(300, (i) => (i * 37) % 256);
      final a = decorativeWaveformPeaks(bytes);
      final b = decorativeWaveformPeaks(bytes);
      expect(a, b, reason: 'same bytes must produce the same bars');
      expect(a.length, 32);
      for (final peak in a) {
        expect(peak, inInclusiveRange(0.0, 1.0));
      }
      final other = decorativeWaveformPeaks(List<int>.filled(300, 9));
      expect(other, isNot(a), reason: 'different bytes, different bars');
    });

    test('tolerates empty byte lists', () {
      final peaks = decorativeWaveformPeaks(const [], barCount: 8);
      expect(peaks.length, 8);
      for (final peak in peaks) {
        expect(peak, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('VoiceNoteRecorderOverlay', () {
    testWidgets('renders timer, waveform from a live stream, and the '
        'slide-to-cancel affordance; settles with ambient off', (tester) async {
      final amplitude = StreamController<double>.broadcast();
      addTearDown(amplitude.close);
      var cancelled = 0;

      await pumpHost(
        tester,
        child: VoiceNoteRecorderOverlay(
          amplitude: amplitude.stream,
          elapsed: const Duration(seconds: 7),
          onCancel: () => cancelled++,
        ),
      );

      // Feed more samples than the ring holds — wrap-around must be safe.
      for (var i = 0; i < recorderWaveformSampleCount + 12; i++) {
        amplitude.add((i % 10) / 10);
      }
      await tester.pump();

      expect(find.text('0:07'), findsOneWidget);
      expect(find.text('Slide to cancel'), findsOneWidget);
      expect(find.bySemanticsLabel('Recording voice note'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(VoiceNoteRecorderOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      // Nothing repeats under flutter test: this must return, not hang.
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Cancel recording'));
      expect(cancelled, 1);
    });

    testWidgets('cancelArmed tints the bar and keeps rendering', (
      tester,
    ) async {
      final amplitude = StreamController<double>.broadcast();
      addTearDown(amplitude.close);

      await pumpHost(
        tester,
        child: VoiceNoteRecorderOverlay(
          amplitude: amplitude.stream,
          elapsed: const Duration(seconds: 3),
          cancelArmed: true,
          onCancel: () {},
        ),
      );
      amplitude.add(0.8);
      await tester.pumpAndSettle();

      expect(find.text('0:03'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('VoiceNotePlayerBar', () {
    Widget bar({
      bool playing = false,
      VoidCallback? onToggle,
      ValueChanged<double>? onSeek,
      Duration position = const Duration(seconds: 15),
      Duration duration = const Duration(seconds: 60),
    }) {
      return SizedBox(
        width: 320,
        child: VoiceNotePlayerBar(
          peaks: List<double>.filled(24, 0.8),
          position: position,
          duration: duration,
          playing: playing,
          onToggle: onToggle,
          onSeek: onSeek,
        ),
      );
    }

    testWidgets('tap at 75% of the waveform seeks near 0.75 in LTR', (
      tester,
    ) async {
      final seeks = <double>[];
      await pumpHost(
        tester,
        child: bar(onToggle: () {}, onSeek: seeks.add),
      );

      final rect = tester.getRect(find.byKey(voiceNoteWaveformKey));
      await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single, closeTo(0.75, 0.05));
    });

    testWidgets('the same physical tap point seeks near 0.25 in RTL', (
      tester,
    ) async {
      final seeks = <double>[];
      await pumpHost(
        tester,
        rtl: true,
        child: bar(onToggle: () {}, onSeek: seeks.add),
      );

      final rect = tester.getRect(find.byKey(voiceNoteWaveformKey));
      await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));
      await tester.pump();

      expect(seeks, hasLength(1));
      expect(seeks.single, closeTo(0.25, 0.05));
    });

    testWidgets('playing state toggles the play/pause icon', (tester) async {
      await pumpHost(tester, child: bar(onToggle: () {}));
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.pause_circle_outline), findsNothing);

      await pumpHost(tester, child: bar(playing: true, onToggle: () {}));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
    });

    testWidgets('tapping the play button invokes onToggle', (tester) async {
      var toggles = 0;
      await pumpHost(tester, child: bar(onToggle: () => toggles++));
      await tester.tap(find.bySemanticsLabel('Play voice note'));
      expect(toggles, 1);
    });

    testWidgets('clock shows position/duration, hidden for zero duration', (
      tester,
    ) async {
      await pumpHost(tester, child: bar(onToggle: () {}));
      expect(find.text('0:15 / 1:00'), findsOneWidget);

      await pumpHost(
        tester,
        child: bar(onToggle: () {}, duration: Duration.zero),
      );
      expect(find.textContaining('/'), findsNothing);
    });
  });

  group('goldens', () {
    Widget scene() => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Seekable, mid-playback.
        VoiceNotePlayerBar(
          peaks: decorativeWaveformPeaks(
            List<int>.generate(96, (i) => (i * 31) % 256),
          ),
          position: const Duration(seconds: 31),
          duration: const Duration(seconds: 83),
          playing: true,
          onToggle: () {},
          onSeek: (_) {},
        ),
        const SizedBox(height: AppSpacing.s16),
        // Idle, unknown length (the chat-bubble configuration).
        VoiceNotePlayerBar(
          peaks: decorativeWaveformPeaks(
            List<int>.generate(64, (i) => (i * 7) % 256),
          ),
          duration: Duration.zero,
          onToggle: () {},
        ),
      ],
    );

    testWidgets('voice player light', (tester) async {
      await pumpHost(tester, child: scene());
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/voice_player_light.png'),
      );
    });

    testWidgets('voice player dark', (tester) async {
      await pumpHost(tester, child: scene(), brightness: Brightness.dark);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/voice_player_dark.png'),
      );
    });
  });
}
