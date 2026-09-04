/// The near side of the app journey: the reference app ITSELF on the Mac,
/// driven through its own screens — joining the phone's call by key,
/// reporting what the live monitor bar shows, then sending a text, a photo,
/// a voice note and a video note through the chat thread that rides the
/// live call, each measured to the phone's verified receipt.
///
/// Orchestrated by tools/t2/journey_run.sh: this test writes READY once the
/// app is on screen, waits for GO (a file whose content is the call key),
/// joins through the "Join with key" dialog, samples the gauge for the hold
/// period, runs the four chat features, and prints one `JOURNEY_APP` line
/// per event plus a `summary` line the orchestrator reads. The phone's side
/// of every feature is read from the hub's `phone_events.jsonl` in the run
/// directory (tools/t2/journey_hub.py): a feature PASSES only when the
/// phone reported the item verified with the same sha256 this side sent.
///
/// Defines:
///   JOURNEY_READY_FILE        path this test creates when the app is on screen
///   JOURNEY_GO_FILE           path the orchestrator writes the key into
///   JOURNEY_RUN_DIR           directory holding phone_events.jsonl
///   JOURNEY_HOLD_S            seconds to sample the gauge once connected (45)
///   E2E_CONNECT_BUDGET_S      seconds to wait for Connected (300)
///   JOURNEY_FEATURE_BUDGET_S  seconds allowed per feature, link-derived (240)
///   JOURNEY_PHOTO_BYTES       photo fixture target size (48000)
///   JOURNEY_VOICE_S           voice note length in seconds (6)
///   JOURNEY_VIDEO_BYTES       video note fixture size (96000)
@Timeout(Duration(minutes: 30))
library;

// Evidence lines are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:messaging/messaging.dart'
    show Attachment, DeliveryState, MediaKind, contentSha256Hex;
import 'package:reference_app/main.dart';
import 'package:reference_app/src/chat_screen.dart' show ChatEntry;
import 'package:reference_app/src/demo_feeds.dart' show demoQualitySourceLabel;
import 'package:reference_app/src/live_chat_registry.dart';
import 'package:reference_app/src/live_quality_feed.dart'
    show liveQualitySourceLabel;
import 'package:reference_app/src/photo_source.dart';

const String readyFile = String.fromEnvironment('JOURNEY_READY_FILE');
const String goFile = String.fromEnvironment('JOURNEY_GO_FILE');
const String runDir = String.fromEnvironment('JOURNEY_RUN_DIR');
const int holdS = int.fromEnvironment('JOURNEY_HOLD_S', defaultValue: 45);
const int connectBudgetS = int.fromEnvironment(
  'E2E_CONNECT_BUDGET_S',
  defaultValue: 300,
);
const int featureBudgetS = int.fromEnvironment(
  'JOURNEY_FEATURE_BUDGET_S',
  defaultValue: 240,
);
const int photoTargetBytes = int.fromEnvironment(
  'JOURNEY_PHOTO_BYTES',
  defaultValue: 48000,
);
const int voiceSeconds = int.fromEnvironment(
  'JOURNEY_VOICE_S',
  defaultValue: 6,
);
const int videoBytes = int.fromEnvironment(
  'JOURNEY_VIDEO_BYTES',
  defaultValue: 96000,
);

final RegExp _rttShape = RegExp(r'^(\d+) ms$');
final RegExp _lossShape = RegExp(r'^([\d.]+)% loss$');
final RegExp _attemptShape = RegExp(r'^Attempt (\d+)$');

Iterable<String> _visibleTexts() => find
    .byType(Text)
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>();

Future<T?> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() found, {
  required Duration budget,
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    final value = found();
    if (value != null) return value;
  }
  return found();
}

String _phaseOnScreen() {
  const phases = [
    'Idle',
    'Connecting…',
    'Negotiating…',
    'Connected',
    'Connected — survival mode',
    'Reconnecting…',
    'Ending call…',
    'Call ended',
    'Call failed',
  ];
  for (final text in _visibleTexts()) {
    if (phases.contains(text)) return text;
  }
  return '?';
}

bool _callOver() {
  final phase = _phaseOnScreen();
  return phase == 'Call ended' || phase == 'Call failed';
}

// ── Fixtures ────────────────────────────────────────────────────────────────

/// Deterministic pseudo-random bytes (LCG), so a row's sha256 is reproducible
/// from its seed and size alone.
Uint8List _noise(int length, int seed) {
  final out = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

/// A real JPEG the staged pipeline can decode, grown until it weighs at
/// least [photoTargetBytes]: noise compresses poorly, so a modest canvas
/// reaches the target quickly. The actual byte count is what the row reports.
Uint8List _photoFixture() {
  var width = 160;
  var height = 120;
  for (var attempt = 0; attempt < 12; attempt++) {
    final image = img.Image(width: width, height: height);
    var x = 0x5EED ^ (width * 31 + height);
    for (var y = 0; y < height; y++) {
      for (var i = 0; i < width; i++) {
        x = (x * 1103515245 + 12345) & 0x7fffffff;
        image.setPixelRgb(i, y, x >> 16 & 0xff, x >> 8 & 0xff, x & 0xff);
      }
    }
    final encoded = Uint8List.fromList(img.encodeJpg(image, quality: 90));
    if (encoded.length >= photoTargetBytes) return encoded;
    width = (width * 1.25).round();
    height = (height * 1.25).round();
  }
  throw StateError('photo fixture never reached $photoTargetBytes bytes');
}

// ── Phone-side evidence ─────────────────────────────────────────────────────

/// One event the phone POSTed to the hub (one JSON line each).
class PhoneEvent {
  final String event;
  final Map<String, Object?> fields;

  PhoneEvent(this.event, this.fields);

  String? get sha256 => fields['sha256'] as String?;

  /// Photos, video notes and attachments carry the peer's own verdict; a
  /// text event carries only the sha256 of what arrived — matching the sha
  /// this side sent IS its verification (first normal run: the text landed,
  /// sha equal, and the row failed on the missing flag alone).
  bool get verified => fields['verified'] == true || event == 'text';
}

List<PhoneEvent> _phoneEvents() {
  if (runDir.isEmpty) return const [];
  final file = File('$runDir/phone_events.jsonl');
  if (!file.existsSync()) return const [];
  final events = <PhoneEvent>[];
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) {
        events.add(PhoneEvent(decoded['event'] as String? ?? '?', decoded));
      }
    } on FormatException {
      // A half-written line: the next poll reads it whole.
    }
  }
  return events;
}

/// The phone's verified event for [sha256] under [kind], or null.
PhoneEvent? _phoneVerified(String kind, String sha256) {
  for (final event in _phoneEvents()) {
    if (event.event == kind && event.sha256 == sha256 && event.verified) {
      return event;
    }
  }
  return null;
}

// ── Features ────────────────────────────────────────────────────────────────

class FeatureOutcome {
  final String feature;
  final int bytes;
  final int? senderMs;
  final int? peerMs;
  final bool shaMatch;
  final String status;
  final String note;

  const FeatureOutcome({
    required this.feature,
    required this.bytes,
    required this.senderMs,
    required this.peerMs,
    required this.shaMatch,
    required this.status,
    required this.note,
  });

  String get line =>
      'JOURNEY_APP feature=$feature status=$status bytes=$bytes '
      'sender_ms=${senderMs ?? '-'} peer_ms=${peerMs ?? '-'} '
      'sha_match=$shaMatch budget_s=$featureBudgetS '
      'note=${note.replaceAll(' ', '_')}';
}

/// Waits for the phone's verified receipt of [sha256] (kind [kind]) and for
/// [senderDone] to turn true, both inside the feature budget, and folds
/// them into one outcome. The call ending early is a FAIL with its reason.
Future<FeatureOutcome> _await(
  WidgetTester tester, {
  required String feature,
  required int bytes,
  required String sha256,
  required String kind,
  required bool Function() senderDone,
  required DateTime startedAt,
  String note = '',
}) async {
  int? senderMs;
  int? peerMs;
  final deadline = startedAt.add(Duration(seconds: featureBudgetS));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    final now = DateTime.now();
    if (senderMs == null && senderDone()) {
      senderMs = now.difference(startedAt).inMilliseconds;
    }
    if (peerMs == null && _phoneVerified(kind, sha256) != null) {
      peerMs = now.difference(startedAt).inMilliseconds;
    }
    if (senderMs != null && peerMs != null) break;
    if (_callOver()) break;
  }
  final over = _callOver();
  final pass = peerMs != null && senderMs != null && !over;
  final why = over
      ? 'call ended (${_phaseOnScreen()}) before the feature completed'
      : (peerMs == null
            ? 'phone never reported it verified within the budget'
            : (senderMs == null ? 'no sender-side delivery receipt' : ''));
  final outcome = FeatureOutcome(
    feature: feature,
    bytes: bytes,
    senderMs: senderMs,
    peerMs: peerMs,
    shaMatch: peerMs != null,
    status: pass ? 'PASS' : 'FAIL',
    note: [if (note.isNotEmpty) note, if (why.isNotEmpty) why].join('; '),
  );
  print(outcome.line);
  return outcome;
}

FeatureOutcome _skipped(String feature, String why) {
  final outcome = FeatureOutcome(
    feature: feature,
    bytes: 0,
    senderMs: null,
    peerMs: null,
    shaMatch: false,
    status: 'FAIL',
    note: why,
  );
  print(outcome.line);
  return outcome;
}

ChatEntry? _lastMine(ChatDemoController chat) {
  for (final entry in chat.entries.reversed) {
    if (entry.message.senderId == chat.localSenderId) return entry;
  }
  return null;
}

Future<List<FeatureOutcome>> _runFeatures(
  WidgetTester tester,
  DateTime joinedAt,
) async {
  final outcomes = <FeatureOutcome>[];
  String t() => 't=${DateTime.now().difference(joinedAt).inSeconds}s';

  // The Chat tab, then the thread bound to the live call.
  await tester.tap(find.byIcon(Icons.chat_bubble));
  await tester.pump(const Duration(milliseconds: 400));
  final row = await _pumpUntil<bool>(
    tester,
    () => find.text('Call peer').evaluate().isNotEmpty ? true : null,
    budget: const Duration(seconds: 30),
  );
  final chat = liveChatController.value;
  if (row != true || chat == null) {
    print('JOURNEY_APP chat ${t()} live thread absent (row=$row chat=$chat)');
    for (final f in const ['chat_text', 'photo', 'voice_note', 'video_note']) {
      outcomes.add(_skipped(f, 'the live-call thread never appeared'));
    }
    return outcomes;
  }
  await tester.tap(find.text('Call peer'));
  await tester.pump(const Duration(milliseconds: 600));
  print(
    'JOURNEY_APP chat ${t()} thread open lanes=chat'
    '${chat.canPickPhoto ? '+photo' : ''}${chat.canSendVideo ? '+video' : ''}',
  );

  // Each feature is fenced: an exception inside one (a send that threw,
  // a finder that found nothing) is that feature's FAIL row, and the next
  // feature still runs — the bandwidth run lost three rows to one throw.
  // 1. Text.
  try {
    final text = 'journey ${DateTime.now().millisecondsSinceEpoch} hello';
    final sha = contentSha256Hex(utf8.encode(text));
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 150));
    final startedAt = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pump(const Duration(milliseconds: 100));
    outcomes.add(
      await _await(
        tester,
        feature: 'chat_text',
        bytes: utf8.encode(text).length,
        sha256: sha,
        kind: 'text',
        senderDone: () {
          final mine = _lastMine(chat);
          return mine != null &&
              mine.message.text == text &&
              chat.deliveryStates[mine.message.id] == DeliveryState.delivered;
        },
        startedAt: startedAt,
        note: 'typed in the composer, sent with the send button',
      ),
    );
  } catch (error) {
    outcomes.add(_skipped('chat_text', 'threw: $error'));
  }

  // 2. Photo: the staged ladder (thumbhash → preview → sha-verified original).
  try {
    if (!chat.canPickPhoto) {
      outcomes.add(_skipped('photo', 'no photo lane on this thread'));
    } else {
      final before = Set<String>.of(chat.outgoingPhotos.keys);
      await tester.tap(find.byIcon(Icons.photo_camera_outlined));
      await tester.pump(const Duration(milliseconds: 400));
      final startedAt = DateTime.now();
      await tester.tap(find.text('Photo library'));
      await tester.pump(const Duration(milliseconds: 200));
      final photoId = await _pumpUntil<String>(tester, () {
        for (final id in chat.outgoingPhotos.keys) {
          if (!before.contains(id)) return id;
        }
        return null;
      }, budget: const Duration(seconds: 30));
      if (photoId == null) {
        outcomes.add(_skipped('photo', 'the picker produced no photo'));
      } else {
        final sha = chat.sentSha256[photoId] ?? '';
        outcomes.add(
          await _await(
            tester,
            feature: 'photo',
            bytes: _photoBytes,
            sha256: sha,
            kind: 'photo',
            senderDone: () => chat.outgoingPhotos[photoId]?.done ?? false,
            startedAt: startedAt,
            note:
                'JPEG fixture via the photo button, staged ladder, '
                'phone verified the original sha256',
          ),
        );
      }
    }
  } catch (error) {
    outcomes.add(_skipped('photo', 'threw: $error'));
  }

  // 3. Voice note: the composer's mic, held for the note length, then send.
  try {
    final micKey = find.byKey(const ValueKey('composer-mic'));
    final beforeIds = chat.sentSha256.keys.toSet();
    final startedAt = DateTime.now();
    var how = '';
    if (micKey.evaluate().isNotEmpty) {
      await tester.tap(micKey);
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil<bool>(
        tester,
        () => null,
        budget: Duration(seconds: voiceSeconds),
      );
      final send = find.byIcon(Icons.send);
      if (send.evaluate().isNotEmpty) {
        await tester.tap(send.first);
        how = 'recorded ${voiceSeconds}s with the composer mic, sent';
      }
    }
    if (how.isEmpty) {
      // The mic control is gated on ambient motion (hidden under
      // FLUTTER_TEST); the same controller path the button calls.
      await chat.sendVoiceNote(Duration(seconds: voiceSeconds));
      how = 'sent via the controller path (mic control hidden under test)';
    }
    await tester.pump(const Duration(milliseconds: 200));
    final voiceId = await _pumpUntil<String>(tester, () {
      for (final id in chat.sentSha256.keys) {
        if (!beforeIds.contains(id) && id.startsWith('voice-')) return id;
      }
      return null;
    }, budget: const Duration(seconds: 15));
    if (voiceId == null) {
      outcomes.add(_skipped('voice_note', 'no voice note was produced ($how)'));
    } else {
      final sha = chat.sentSha256[voiceId]!;
      final attachment = chat.entries
          .map((e) => e.attachment)
          .whereType<Attachment>()
          .firstWhere((a) => a.id == voiceId);
      outcomes.add(
        await _await(
          tester,
          feature: 'voice_note',
          bytes: attachment.bytes.length,
          sha256: sha,
          kind: 'attachment',
          senderDone: () => (chat.attachmentProgress[voiceId] ?? 0) >= 1.0,
          startedAt: startedAt,
          note:
              '$how; content is the app\'s placeholder audio (no recorder '
              'dependency), transfer and integrity are real',
        ),
      );
    }
  } catch (error) {
    outcomes.add(_skipped('voice_note', 'threw: $error'));
  }

  // 4. Video note: attach a clip; it rides the video lane, sha-verified.
  try {
    final beforeIds = chat.sentSha256.keys.toSet();
    final startedAt = DateTime.now();
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump(const Duration(milliseconds: 300));
    final videoId = await _pumpUntil<String>(tester, () {
      for (final id in chat.sentSha256.keys) {
        if (!beforeIds.contains(id) && id.startsWith('video-')) return id;
      }
      return null;
    }, budget: const Duration(seconds: 15));
    if (videoId == null) {
      outcomes.add(
        _skipped('video_note', 'the attach picker produced no clip'),
      );
    } else {
      final sha = chat.sentSha256[videoId]!;
      final lane = chat.canSendVideo;
      outcomes.add(
        await _await(
          tester,
          feature: 'video_note',
          bytes: videoBytes,
          sha256: sha,
          kind: lane ? 'video' : 'attachment',
          senderDone: () => lane
              ? chat.outgoingVideos.values.any((s) => s.done)
              : (chat.attachmentProgress[videoId] ?? 0) >= 1.0,
          startedAt: startedAt,
          note: lane
              ? 'synthetic clip bytes via the attach button, binary video '
                    'lane, phone verified the sha256'
              : 'synthetic clip bytes via the chunked text path (no video lane)',
        ),
      );
    }
  } catch (error) {
    outcomes.add(_skipped('video_note', 'threw: $error'));
  }

  // What the lane budget was last derived from — the row's explanation for
  // a slow or a fast transfer.
  print(
    'JOURNEY_APP lane ${t()} budget_reason='
    '${(chat.laneBudgetReason ?? 'none').replaceAll(' ', '_')} '
    'last_failure=${(chat.lastSendFailure ?? '-').replaceAll(' ', '_')}',
  );

  // Back to the call screen for the hang-up.
  final back = find.byType(BackButton);
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back);
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.tap(find.byIcon(Icons.call));
  await tester.pump(const Duration(milliseconds: 400));
  return outcomes;
}

int _photoBytes = 0;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('journey driver: the app joins the phone\'s call by key, '
      'reports its monitor bar, and sends text, photo, voice and video '
      'notes over the live call', (tester) async {
    expect(readyFile, isNotEmpty, reason: 'JOURNEY_READY_FILE is required');
    expect(goFile, isNotEmpty, reason: 'JOURNEY_GO_FILE is required');

    final photo = _photoFixture();
    _photoBytes = photo.length;
    final clip = _noise(videoBytes, 0xC11F);
    await tester.pumpWidget(
      MyApp(
        photoPicker: (PhotoSource source) async => photo,
        attachmentPicker: () async => Attachment(
          id: 'video-${DateTime.now().millisecondsSinceEpoch}',
          kind: MediaKind.video,
          contentType: 'video/mp4',
          bytes: clip,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Idle'), findsOneWidget);
    File(readyFile).writeAsStringSync('ready\n');
    print(
      'JOURNEY_APP ready hold=${holdS}s budget=${connectBudgetS}s '
      'feature_budget=${featureBudgetS}s photo_bytes=${photo.length} '
      'voice_s=$voiceSeconds video_bytes=$videoBytes',
    );

    final key = await _pumpUntil<String>(
      tester,
      () {
        final file = File(goFile);
        if (!file.existsSync()) return null;
        final text = file.readAsStringSync().trim();
        return text.isEmpty ? null : text;
      },
      budget: const Duration(minutes: 10),
      step: const Duration(milliseconds: 500),
    );
    expect(key, isNotNull, reason: 'GO file never carried a key');
    print('JOURNEY_APP go key=$key');

    final joinButton = find.widgetWithText(OutlinedButton, 'Join with key');
    await tester.ensureVisible(joinButton);
    await tester.tap(joinButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), key!);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pump(const Duration(milliseconds: 300));
    final joinedAt = DateTime.now();
    print('JOURNEY_APP joined phase=${_phaseOnScreen()}');

    var lastSeen = '';
    final outcome = await _pumpUntil<String>(tester, () {
      final phase = _phaseOnScreen();
      final attempt = _visibleTexts()
          .map((t) => _attemptShape.firstMatch(t)?.group(1))
          .whereType<String>()
          .join(',');
      final seen = '$phase/$attempt';
      if (seen != lastSeen) {
        lastSeen = seen;
        print(
          'JOURNEY_APP phase t=${DateTime.now().difference(joinedAt).inSeconds}s '
          '$phase attempt=${attempt.isEmpty ? '-' : attempt}',
        );
      }
      if (phase == 'Connected' || phase == 'Connected — survival mode') {
        return phase;
      }
      if (phase == 'Call failed' || phase == 'Call ended') return phase;
      return null;
    }, budget: Duration(seconds: connectBudgetS));
    final connectMs = DateTime.now().difference(joinedAt).inMilliseconds;
    final visible = _visibleTexts().where((t) => t.length < 400).join(' | ');
    print(
      'JOURNEY_APP outcome=${(outcome ?? 'timeout').replaceAll(' ', '_')} '
      'connect_ms=$connectMs screen=$visible',
    );

    var samples = 0;
    int? rttMin;
    int? rttMax;
    double lossMax = 0;
    var reconnects = 0;
    var attemptMax = 0;
    var chipLive = 0;
    var chipDemo = 0;
    var lastPhase = '';
    var endedOnScreen = outcome == 'Call failed' || outcome == 'Call ended';
    final connected =
        outcome == 'Connected' || outcome == 'Connected — survival mode';
    if (connected) {
      final holdUntil = DateTime.now().add(Duration(seconds: holdS));
      while (DateTime.now().isBefore(holdUntil)) {
        await tester.pump(const Duration(milliseconds: 500));
        final phase = _phaseOnScreen();
        int? rtt;
        double? loss;
        String? chip;
        int? attempt;
        for (final text in _visibleTexts()) {
          final r = _rttShape.firstMatch(text);
          if (r != null) rtt = int.parse(r.group(1)!);
          final l = _lossShape.firstMatch(text);
          if (l != null) loss = double.parse(l.group(1)!);
          final a = _attemptShape.firstMatch(text);
          if (a != null) attempt = int.parse(a.group(1)!);
          if (text == liveQualitySourceLabel) chip = 'live';
          if (text == demoQualitySourceLabel) chip = 'demo';
        }
        samples++;
        if (rtt != null) {
          rttMin = rttMin == null ? rtt : (rtt < rttMin ? rtt : rttMin);
          rttMax = rttMax == null ? rtt : (rtt > rttMax ? rtt : rttMax);
        }
        if (loss != null && loss > lossMax) lossMax = loss;
        if (attempt != null && attempt > attemptMax) attemptMax = attempt;
        if (chip == 'live') chipLive++;
        if (chip == 'demo') chipDemo++;
        if (phase == 'Reconnecting…' && lastPhase != 'Reconnecting…') {
          reconnects++;
        }
        lastPhase = phase;
        print(
          'JOURNEY_APP sample t=${DateTime.now().difference(joinedAt).inSeconds}s '
          'phase=$phase rtt=${rtt ?? '-'} loss=${loss ?? '-'} '
          'chip=${chip ?? 'none'} attempt=${attempt ?? '-'}',
        );
        if (phase == 'Call ended' || phase == 'Call failed') {
          endedOnScreen = true;
          break;
        }
      }
    }

    var features = <FeatureOutcome>[];
    if (connected && !endedOnScreen) {
      features = await _runFeatures(tester, joinedAt);
      endedOnScreen = _callOver();
    } else {
      for (final f in const [
        'chat_text',
        'photo',
        'voice_note',
        'video_note',
      ]) {
        features.add(_skipped(f, 'no connected call to send over'));
      }
    }

    if (!endedOnScreen) {
      final hangUp = find.widgetWithText(FilledButton, 'Hang up');
      if (hangUp.evaluate().isNotEmpty) {
        await tester.ensureVisible(hangUp);
        await tester.tap(hangUp);
      }
      await _pumpUntil<bool>(tester, () {
        final phase = _phaseOnScreen();
        return (phase == 'Call ended' || phase == 'Call failed') ? true : null;
      }, budget: const Duration(seconds: 30));
    }
    final endTexts = _visibleTexts().where((t) => t.length < 70).join(' | ');
    final passed = features.where((f) => f.status == 'PASS').length;
    print(
      'JOURNEY_APP summary outcome=${(outcome ?? 'timeout').replaceAll(' ', '_')} '
      'connect_ms=$connectMs samples=$samples rtt_min=${rttMin ?? '-'} '
      'rtt_max=${rttMax ?? '-'} loss_max=$lossMax chip_live=$chipLive '
      'chip_demo=$chipDemo reconnects=$reconnects attempt_max=$attemptMax '
      'features_pass=$passed/${features.length} '
      'end=${_phaseOnScreen().replaceAll(' ', '_')} screen=$endTexts',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
