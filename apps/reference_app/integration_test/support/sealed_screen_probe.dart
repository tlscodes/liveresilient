// What the sealed panel shows for one received letter, read the way a person
// sees it: inside THAT letter's row only, after the row is scrolled into the
// panel's viewport.
//
// Born 2026-10-10 (phase پ, full4): the rig asked `find.textContaining(text)`
// over the whole tree. Finders skip offstage widgets, and the panel's list is
// 220 px tall, so the oldest of four letters — built, drawn, journaled by the
// app's own reader, but below a photo row — printed `on_screen=false`.
//
// The sent side had the same blind spot: a written letter's state line, read
// with a plain finder, printed `screen=not_built` for a row below the fold.
// And the two rigs printed different fields for the same row: no `id=` on a
// sent row in either, no `state=` in the real-app test, `receipt_at=` in the
// offline send and no `screen=` in its receive. One format now lives here.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

/// [inView]: the body was visible before any scrolling.
/// [shown]: the body is in its own row once that row is scrolled to.
typedef SealedRowSight = ({bool inView, bool shown});

/// Looks for letter [id]'s body in its row `sealed-received-<id>`: the photo
/// keyed `sealed-photo-<id>` when [photo], otherwise a Text equal to [text].
Future<SealedRowSight> sealedRowSight(
  WidgetTester tester, {
  required String id,
  required String text,
  required bool photo,
}) async {
  final row = find.byKey(Key('sealed-received-$id'), skipOffstage: false);
  bool visible() => find
      .descendant(
        of: row,
        matching: photo
            ? find.byKey(Key('sealed-photo-$id'))
            : find.text(text, findRichText: true),
      )
      .evaluate()
      .isNotEmpty;

  if (row.evaluate().isEmpty) return (inView: false, shown: false);
  final inView = visible();
  if (inView) return (inView: true, shown: true);
  await tester.ensureVisible(row);
  await tester.pump();
  return (inView: false, shown: visible());
}

/// The state line of sent letter [id] (`sealed-state-<id>` in its row
/// `sealed-sent-<id>`) once that row is scrolled into the panel's viewport,
/// spaces as `_`: `not_built` when the panel has no such row, `not_in_view`
/// when it would not come into view. Informational: no verdict reads it.
Future<String> sealedSentLine(WidgetTester tester, String id) async {
  final row = find.byKey(Key('sealed-sent-$id'), skipOffstage: false);
  if (row.evaluate().isEmpty) return 'not_built';
  final line = find.descendant(
    of: row,
    matching: find.byKey(Key('sealed-state-$id')),
  );
  if (line.evaluate().isEmpty) {
    try {
      await tester.ensureVisible(row);
      await tester.pump();
    } catch (_) {
      // Reported as not in view; a screen field never fails a rig run.
    }
  }
  return line.evaluate().isEmpty
      ? 'not_in_view'
      : tester.widget<Text>(line).data!.replaceAll(' ', '_');
}

String _iso(DateTime? at) => at == null ? '-' : at.toUtc().toIso8601String();

/// `SEALED_RIG written`: a letter this app wrote, seen onto the relay.
String sealedWrittenLine(
  SealedSent s, {
  required String own,
  required String screen,
}) =>
    'SEALED_RIG written dir=mac_to_phone kind=${s.content.kindLabel} '
    'id=${s.id} from=$own to=${s.to} bytes=${s.bytes} '
    'sent_at=${_iso(s.at)} on_relay=${s.onShelf} receipt=${s.delivered} '
    'attempts=${s.attempts} screen=$screen';

/// `SEALED_RIG row dir=mac_to_phone`: a letter this app wrote, and whether
/// its receipt was read.
String sealedSentRowLine(
  SealedSent s, {
  required String own,
  required String screen,
}) =>
    'SEALED_RIG row dir=mac_to_phone kind=${s.content.kindLabel} '
    'id=${s.id} from=$own to=${s.to} bytes=${s.bytes} '
    'sent_at=${_iso(s.at)} receipt_read_at=${_iso(s.deliveredAt)} '
    'receipt=${s.delivered} state=${s.state.name} attempts=${s.attempts} '
    'screen=$screen';

/// `SEALED_RIG row dir=phone_to_mac`: a letter that opened here. [sha] is
/// the first four bytes of SHA-256 over its body, in hex.
String sealedReceivedRowLine(
  SealedReceived r, {
  required String own,
  required String sha,
  required SealedRowSight sight,
}) =>
    'SEALED_RIG row dir=phone_to_mac kind=${r.content.kindLabel} '
    'id=${r.id} from=${r.from} to=$own bytes=${r.bytes} '
    'sent_at=${_iso(r.sentAt)} opened_at=${_iso(r.receivedAt)} '
    'opened=true verified=${r.verified} sha=$sha '
    'on_screen=${sight.shown} in_view=${sight.inView}';
