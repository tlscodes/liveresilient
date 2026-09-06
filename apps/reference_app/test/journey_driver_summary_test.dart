/// Pins the Mac journey driver's `JOURNEY_APP summary` line to the two
/// consumers that read it, and pins the queue proof the whitelist profile
/// judges the run by.
///
/// Scenario pinned (refuter finding, journey_driver_test.dart:841): the driver
/// printed outcome/connect_ms/samples/rtt/loss/chip/reconnects/attempt_max/
/// features_pass/end/screen and nothing else, while
/// `tools/t2/journey_whitelist_rows.py:157-158` reads `queued_clips` and
/// `degraded_voice_notes` out of that same line. On a perfect whitelist run
/// both parsed as None, `None != 0` held for both, and the two rows printed
/// FAIL with `queued_clips=None,degraded_voice_notes=None` — the profile could
/// never go green. The python test passed only because its GREEN_SUMMARY
/// fixture invented a line the driver never printed.
///
/// So these tests build the summary from the SAME function the driver prints
/// with, and check it against the consumer script and against that fixture,
/// both read from disk. A key added to the consumer without an emitter, or a
/// fixture that drifts from the emitter, fails here.
library;

import 'dart:io';

import 'package:call_core/call_core.dart' show CallPhase, DegradedMode;
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/journey_driver_test.dart'
    show
        SurvivalProof,
        journeySummaryLine,
        queuedBundlesFor,
        storeAndForwardPutRecords,
        survivalLogFile;

/// Repo paths, relative to the package directory `flutter test` runs in.
const String consumerPath = '../../tools/t2/journey_whitelist_rows.py';
const String consumerTestPath = '../../tools/t2/test_journey_whitelist_rows.py';
const String callSessionPath = 'lib/src/call_session.dart';

String readRepoFile(String path) {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: '$path not found from ${Directory.current.path}',
  );
  return file.readAsStringSync();
}

/// A summary line as a green whitelist run would print it.
String greenSummary({
  int queuedClips = 0,
  int degradedVoiceNotes = 0,
  int survivalTicks = 180,
  String outcome = 'Connected',
  String end = 'Call ended',
}) => journeySummaryLine(
  outcome: outcome,
  connectMs: 5000,
  samples: 90,
  rttMin: 12,
  rttMax: 48,
  lossMax: 0.4,
  chipLive: 90,
  chipDemo: 0,
  reconnects: 0,
  attemptMax: 1,
  featuresPass: 4,
  featuresTotal: 4,
  queuedClips: queuedClips,
  degradedVoiceNotes: degradedVoiceNotes,
  survivalTicks: survivalTicks,
  queueSource: 'survival_log+call_screen_mode',
  end: end,
  screen: 'Call ended | Idle',
);

/// Every key `journey_whitelist_rows.py` pulls out of the summary line, read
/// from the script itself rather than restated here.
Set<String> consumerSummaryKeys(String source) => RegExp(
  r"""summary_number\(\s*summary,\s*'([a-z_]+)'\s*\)""",
).allMatches(source).map((m) => m.group(1)!).toSet();

/// The consumer's own reader, in Dart: `summary_number` is
/// `re.search(rf'\b{name}=(-?\d+)\b', summary)`.
int? summaryNumber(String summary, String name) {
  final match = RegExp(r'\b' + name + r'=(-?\d+)\b').firstMatch(summary);
  return match == null ? null : int.parse(match.group(1)!);
}

/// The runner's own reader, in Dart: journey_run.sh:599 is
/// `grep -oE "$1=[^ ]+" | head -1 | cut -d= -f2`.
String? runnerField(String summary, String name) {
  final match = RegExp('$name=([^ ]+)').firstMatch(summary);
  return match?.group(1);
}

void main() {
  group('the summary line and the whitelist consumer', () {
    test('every key the consumer reads is emitted as a number', () {
      final keys = consumerSummaryKeys(readRepoFile(consumerPath));
      expect(keys, contains('queued_clips'));
      expect(keys, contains('degraded_voice_notes'));
      final line = greenSummary();
      for (final key in keys) {
        expect(
          summaryNumber(line, key),
          isNotNull,
          reason: '$key is read by journey_whitelist_rows.py but not printed',
        );
      }
      expect(summaryNumber(line, 'queued_clips'), 0);
      expect(summaryNumber(line, 'degraded_voice_notes'), 0);
    });

    test('the python test fixture agrees with what this file prints', () {
      final fixture = RegExp(
        r"GREEN_SUMMARY = \(\n((?:\s*'[^']*'\n)+)\)",
      ).firstMatch(readRepoFile(consumerTestPath));
      expect(fixture, isNotNull, reason: 'GREEN_SUMMARY not found');
      final fixtureLine = RegExp(
        "'([^']*)'",
      ).allMatches(fixture!.group(1)!).map((m) => m.group(1)!).join();
      final line = greenSummary();
      for (final key in consumerSummaryKeys(readRepoFile(consumerPath))) {
        expect(
          summaryNumber(fixtureLine, key),
          summaryNumber(line, key),
          reason: 'fixture and emitter disagree on $key',
        );
      }
    });

    test('a queue proof that could not be taken fails the row', () {
      // -1 is what an absent survival log emits; the consumer fails any row
      // whose queued_clips is not exactly 0.
      final line = greenSummary(queuedClips: -1);
      expect(summaryNumber(line, 'queued_clips'), -1);
      expect(summaryNumber(line, 'queued_clips'), isNot(0));
    });

    test('the new keys do not shadow the fields the runner greps', () {
      final line = greenSummary();
      expect(runnerField(line, 'outcome'), 'Connected');
      expect(runnerField(line, 'connect_ms'), '5000');
      expect(runnerField(line, 'rtt_min'), '12');
      expect(runnerField(line, 'rtt_max'), '48');
      expect(runnerField(line, 'loss_max'), '0.4');
      expect(runnerField(line, 'chip_live'), '90');
      expect(runnerField(line, 'chip_demo'), '0');
      expect(runnerField(line, 'reconnects'), '0');
      expect(runnerField(line, 'end'), 'Call_ended');
    });

    test('spaces in outcome and end are replaced, so no field splits', () {
      final line = greenSummary(
        outcome: 'Connected — survival mode',
        end: 'Call failed',
      );
      expect(runnerField(line, 'outcome'), 'Connected_—_survival_mode');
      expect(runnerField(line, 'end'), 'Call_failed');
      expect(line.split(' ').where((t) => t.startsWith('outcome=')).length, 1);
    });

    test('screen stays last, so its free text swallows nothing', () {
      final line = greenSummary();
      expect(
        line.substring(line.indexOf('screen=')),
        'screen=Call ended | Idle',
      );
    });
  });

  group('the voice-note observation', () {
    test('a voice-note mode sample is counted, other modes are not', () {
      final proof = SurvivalProof();
      proof.record(phase: CallPhase.connected, mode: null);
      proof.record(phase: CallPhase.degraded, mode: DegradedMode.lowRateVoice);
      proof.record(phase: CallPhase.degraded, mode: DegradedMode.tokenVoice);
      expect(proof.voiceNoteTicks, 0);
      expect(proof.degradedTicks, 2);
      expect(proof.ticks, 3);
      proof.record(phase: CallPhase.degraded, mode: DegradedMode.voiceNotes);
      expect(proof.voiceNoteTicks, 1);
    });

    test('voice-note mode counts even without the degraded phase', () {
      // The mode is judged on its own value: a mode published while the phase
      // reads something else still fails the run rather than passing silently.
      final proof = SurvivalProof();
      proof.record(phase: CallPhase.connected, mode: DegradedMode.voiceNotes);
      expect(proof.voiceNoteTicks, 1);
      expect(proof.degradedTicks, 0);
    });
  });

  group('the store-and-forward log count', () {
    test('put records are counted, removes and torn lines are not', () {
      final lines = [
        '{"op":"put","id":"a","payload":""}',
        '',
        '{"op":"remove","id":"a"}',
        '{"op":"put","id":"b","payload":""}',
        '{"op":"put","id":"b"',
        'not json at all',
      ];
      expect(storeAndForwardPutRecords(lines), 2);
    });

    test('an empty log counts zero', () {
      expect(storeAndForwardPutRecords(const <String>[]), 0);
    });

    test('an absent log reads -1, a present one reads its puts', () {
      final dir = Directory.systemTemp.createTempSync('journey_summary_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(queuedBundlesFor('callKEY', storeDir: dir), -1);
      final log = survivalLogFile('callKEY', storeDir: dir);
      expect(log.path, '${dir.path}/survival_callKEY.jsonl');
      log.writeAsStringSync(
        '{"op":"put","id":"voice-note-0"}\n'
        '{"op":"remove","id":"voice-note-0"}\n'
        '{"op":"put","id":"voice-note-1"}\n',
      );
      expect(queuedBundlesFor('callKEY', storeDir: dir), 2);
    });

    test('the log path this test rebuilds still matches call_session.dart', () {
      // The directory name and the file name are private in call_session.dart
      // (`_defaultStoreAndForwardDir`, and the literal at the DurableBundleStore
      // it opens), so the driver states them again. This pins the copy: a
      // rename in the app fails here instead of silently reading nothing.
      final source = readRepoFile(callSessionPath);
      expect(source, contains('voice_call_kit_survival'));
      expect(source, contains(r'survival_$callId.jsonl'));
    });
  });
}
