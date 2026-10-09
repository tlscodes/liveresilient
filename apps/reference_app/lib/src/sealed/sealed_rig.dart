// The rig's hands inside the real app (phase پ, tools/t2/sealed_txt_phone_rig.sh
// with SEALED_TARGET=real). Compiled in only with --dart-define=SEALED_RIG=true:
// every use sits behind the const [kSealedRig], so a normal build drops this
// code and its strings (the release binary is checked for "SEALED_RIG").
//
// What it does, and nothing more:
//   - answers the chat panel's attach button from the rig box — photo,
//     30 s voice note, short video, in that order — so no file picker and
//     no microphone is ever asked;
//   - a text from a pinned peer ending in `#rig-reply-after=<seconds>`
//     makes this install write back that much later, through the panel's
//     own field, send button and attach button;
//   - reads each letter's line off the widget tree and writes it to the
//     journal (`rig_screen`, `screen_text`).
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:messaging/messaging.dart' show Attachment, MediaKind;

import '../intelligence/device_bindings.dart';
import 'sealed_letter_service.dart';

const bool kSealedRig = bool.fromEnvironment('SEALED_RIG');
const String _rigDir = String.fromEnvironment('SEALED_RIG_DIR');

/// The install the rig writes to when it is not answering a letter; empty =
/// the panel's own choice.
const String kSealedRigPeer = String.fromEnvironment('SEALED_RIG_PEER');

/// The panel's own controls, handed to the rig by the panel itself.
class SealedRigHands {
  SealedRigHands({
    required this.address,
    required this.write,
    required this.attach,
  });

  /// Chooses the recipient, as the dropdown would.
  final void Function(String to) address;

  /// Puts [text] in the field and presses send.
  final Future<void> Function(String text) write;

  /// Presses attach; [SealedRig.pick] answers.
  final Future<void> Function() attach;
}

class SealedRig {
  SealedRig._();

  static final SealedRig instance = SealedRig._();

  static const List<(String, String, MediaKind, Duration)> fixtures = [
    ('photo.jpg', 'image/jpeg', MediaKind.image, Duration.zero),
    ('voice.m4a', 'audio/mp4', MediaKind.file, Duration(seconds: 30)),
    ('video.mp4', 'video/mp4', MediaKind.video, Duration(seconds: 10)),
  ];

  final DateTime _booted = DateTime.now();
  SealedRigHands? _hands;
  SealedLetterService? _service;
  final Set<String> _asked = {};
  final Map<String, String> _seen = {};
  int _next = 0;

  /// The length of the fixture [pick] handed out last.
  Duration pickedDuration = Duration.zero;

  Directory get box => Directory(
    _rigDir.isNotEmpty
        ? _rigDir
        : '${intelligenceStorageDirectory().parent.path}/sealed_rig',
  );

  void _note(String what, Map<String, Object?> fields) {
    debugPrint(
      'SEALED_RIG $what ${fields.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
    );
    _service?.onEvent?.call('rig_$what', fields);
  }

  /// Called by the panel when it is built for [service].
  void attachPanel(SealedLetterService service, SealedRigHands hands) {
    _hands = hands;
    if (identical(_service, service)) return;
    _service = service;
    service.inbox.addListener(_onInbox);
    _onInbox();
    _note('ready', {'box': box.path, 'booted': _iso(_booted)});
  }

  void detachPanel(SealedRigHands hands) {
    if (identical(_hands, hands)) _hands = null;
  }

  /// The attach button's answer: the next rig fixture.
  Future<Attachment?> pick() async {
    final (name, type, kind, duration) = fixtures[_next % fixtures.length];
    _next++;
    final file = File('${box.path}/$name');
    if (!file.existsSync()) {
      _note('missing', {'file': file.path});
      return null;
    }
    pickedDuration = duration;
    return Attachment(
      id: 'rig-$name',
      kind: kind,
      contentType: type,
      bytes: await file.readAsBytes(),
    );
  }

  /// A text and the three fixtures to [to], through the panel's controls.
  Future<void> writeAll(String to, String text) async {
    for (var i = 0; i < 40 && _hands == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final hands = _hands;
    if (hands == null) {
      _note('no_panel', {'to': to});
      return;
    }
    _next = 0;
    hands.address(to);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await hands.write(text);
    for (var i = 0; i < fixtures.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await hands.attach();
    }
    _note('wrote', {'to': to, 'letters': 1 + fixtures.length});
  }

  void _onInbox() {
    final service = _service;
    if (service == null) return;
    // What was opened before this launch is history, not a request.
    final history = _booted.subtract(const Duration(seconds: 90));
    for (final l in service.inbox.value) {
      final wait = RegExp(
        r'#rig-reply-after=(\d+)$',
      ).firstMatch(l.content.text ?? '');
      if (wait == null || l.receivedAt.isBefore(history)) continue;
      if (!_asked.add(l.id)) continue;
      final seconds = int.parse(wait.group(1)!);
      _note('reply_due', {'id': l.id, 'after_s': seconds});
      Timer(
        Duration(seconds: seconds),
        () => unawaited(
          writeAll(l.from, 'written on the phone at ${_iso(DateTime.now())}'),
        ),
      );
    }
  }

  /// Reads the first line of every letter row under [panel] off the widget
  /// tree and journals each one the first time it shows, and when it changes.
  void readScreen(BuildContext panel) {
    final service = _service;
    if (service == null) return;
    final rows = <String, String>{};
    void visit(Element e) {
      final key = e.widget.key;
      if (key is ValueKey<String> &&
          (key.value.startsWith('sealed-received-') ||
              key.value.startsWith('sealed-sent-'))) {
        String? first;
        void text(Element t) {
          if (first != null) return;
          final w = t.widget;
          if (w is Text && w.data != null) {
            first = w.data;
            return;
          }
          t.visitChildren(text);
        }

        e.visitChildren(text);
        if (first != null) rows[key.value] = first!;
        return;
      }
      e.visitChildren(visit);
    }

    (panel as Element).visitChildren(visit);
    for (final MapEntry(key: key, value: line) in rows.entries) {
      if (_seen[key] == line) continue;
      _seen[key] = line;
      final inbound = key.startsWith('sealed-received-');
      final id = key.substring(inbound ? 16 : 12);
      final (kind, sentAt) = inbound
          ? service.inbox.value
                    .where((r) => r.id == id)
                    .map((r) => (r.content.kindLabel, r.sentAt))
                    .firstOrNull ??
                ('-', null)
          : service.outbox.value
                    .where((s) => s.id == id)
                    .map((s) => (s.content.kindLabel, s.at))
                    .firstOrNull ??
                ('-', null);
      _note('screen', {
        'dir': inbound ? 'in' : 'out',
        'kind': kind,
        'id': id,
        'sent_at': _iso(sentAt),
        'screen_text': line,
      });
    }
  }
}

String _iso(DateTime? at) => at == null ? '-' : at.toUtc().toIso8601String();
