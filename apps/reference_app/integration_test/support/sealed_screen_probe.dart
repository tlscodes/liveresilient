// What the sealed panel shows for one received letter, read the way a person
// sees it: inside THAT letter's row only, after the row is scrolled into the
// panel's viewport.
//
// Born 2026-10-10 (phase پ, full4): the rig asked `find.textContaining(text)`
// over the whole tree. Finders skip offstage widgets, and the panel's list is
// 220 px tall, so the oldest of four letters — built, drawn, journaled by the
// app's own reader, but below a photo row — printed `on_screen=false`.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

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
