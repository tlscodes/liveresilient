// The rig's on-screen probe on the sealed panel's own geometry: a 220-px list
// with every row built (the rig build's cache extent), newest first — video,
// voice, a 96-px photo, then the text that full4 reported as not on screen.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

import '../integration_test/support/sealed_screen_probe.dart';

const _text = 'written on the phone at 2026-10-10T00:10:34.065991Z';

Widget _row(String id, Widget title) => ListTile(
  key: Key('sealed-received-$id'),
  dense: true,
  contentPadding: EdgeInsets.zero,
  leading: const Icon(Icons.lock_outline, size: 18),
  title: title,
  subtitle: const Text('from a08887e8… · not yet verified · opened here 01:10'),
);

Widget _panel() => MaterialApp(
  home: Scaffold(
    body: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
        children: [
          _row('video', const Text('video · 16 KB · 10 s')),
          _row('voice', const Text('voice · 27 KB · 30 s')),
          _row(
            'photo',
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SizedBox(key: Key('sealed-photo-photo'), height: 96, width: 96),
                Text('photo · 17 KB'),
              ],
            ),
          ),
          _row('text', const Text(_text)),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('a built row below the fold: the old finder misses it, '
      'the probe scrolls to it and finds it', (tester) async {
    await tester.pumpWidget(_panel());
    // The full4 symptom, reproduced: built in the tree, offstage for a finder.
    expect(find.textContaining(_text), findsNothing);
    expect(find.textContaining(_text, skipOffstage: false), findsOneWidget);

    final sight = await sealedRowSight(
      tester,
      id: 'text',
      text: _text,
      photo: false,
    );
    expect(sight, (inView: false, shown: true));
  });

  testWidgets('another body in the row, or a row that is not there, '
      'does not match', (tester) async {
    await tester.pumpWidget(_panel());
    expect(
      await sealedRowSight(
        tester,
        id: 'text',
        text: 'written on the phone at 2026-10-09T21:06:45.139666Z',
        photo: false,
      ),
      (inView: false, shown: false),
    );
    // The text exists, but not in this letter's row.
    expect(
      await sealedRowSight(tester, id: 'voice', text: _text, photo: false),
      (inView: false, shown: false),
    );
    expect(
      await sealedRowSight(tester, id: 'gone', text: _text, photo: false),
      (inView: false, shown: false),
    );
  });

  testWidgets('rows already in view need no scroll', (tester) async {
    await tester.pumpWidget(_panel());
    expect(await sealedRowSight(tester, id: 'photo', text: '', photo: true), (
      inView: true,
      shown: true,
    ));
    expect(
      await sealedRowSight(
        tester,
        id: 'voice',
        text: 'voice · 27 KB · 30 s',
        photo: false,
      ),
      (inView: true, shown: true),
    );
  });

  testWidgets('a sent row below the fold: its state line is read after '
      'the row is scrolled to', (tester) async {
    await tester.pumpWidget(_sentPanel());
    // The sender-side twin of full4: built, but offstage for a plain finder.
    expect(find.byKey(const Key('sealed-state-s1')), findsNothing);
    expect(
      find.byKey(const Key('sealed-state-s1'), skipOffstage: false),
      findsOneWidget,
    );
    expect(await sealedSentLine(tester, 's1'), 'to_a08887e8…_·_opened_by_them');
    expect(await sealedSentLine(tester, 'gone'), 'not_built');
  });

  test('both rig tests print one format: id right after kind', () {
    const own = '323c3ca6c1105f43449749bb8d799496';
    final at = DateTime.utc(2026, 10, 9, 23, 22, 17, 93, 326);
    final sent = SealedSent(
      id: '5fa0224e92fbb777c7ccdc347ce7645b',
      to: 'a08887e8c641b475cc4c50722640e68f',
      content: const SealedContent.text('hi'),
      at: at,
      attempts: 1,
      onShelf: true,
      nextAt: at,
      deliveredAt: DateTime.utc(2026, 10, 10, 1, 10, 1, 323, 903),
    );
    expect(
      sealedWrittenLine(sent, own: own, screen: 'not_built'),
      'SEALED_RIG written dir=mac_to_phone kind=text '
      'id=5fa0224e92fbb777c7ccdc347ce7645b from=$own '
      'to=a08887e8c641b475cc4c50722640e68f bytes=2 '
      'sent_at=2026-10-09T23:22:17.093326Z on_relay=true receipt=true '
      'attempts=1 screen=not_built',
    );
    expect(
      sealedSentRowLine(sent, own: own, screen: 'x'),
      'SEALED_RIG row dir=mac_to_phone kind=text '
      'id=5fa0224e92fbb777c7ccdc347ce7645b from=$own '
      'to=a08887e8c641b475cc4c50722640e68f bytes=2 '
      'sent_at=2026-10-09T23:22:17.093326Z '
      'receipt_read_at=2026-10-10T01:10:01.323903Z receipt=true '
      'state=opened attempts=1 screen=x',
    );
    final got = SealedReceived(
      id: 'b24480cd336abc9ac7e6d70be10582af',
      from: 'a08887e8c641b475cc4c50722640e68f',
      content: const SealedContent.text('hi'),
      media: null,
      sentAt: DateTime.utc(2026, 10, 10, 0, 10, 34, 405),
      receivedAt: DateTime.utc(2026, 10, 10, 1, 10, 1, 631, 533),
      verified: false,
    );
    expect(
      sealedReceivedRowLine(
        got,
        own: own,
        sha: 'edbea39d',
        sight: (inView: false, shown: true),
      ),
      'SEALED_RIG row dir=phone_to_mac kind=text '
      'id=b24480cd336abc9ac7e6d70be10582af '
      'from=a08887e8c641b475cc4c50722640e68f to=$own bytes=2 '
      'sent_at=2026-10-10T00:10:34.405Z '
      'opened_at=2026-10-10T01:10:01.631533Z opened=true verified=false '
      'sha=edbea39d on_screen=true in_view=false',
    );
  });
}

// The sender-side panel: four 96-px received rows put the sent row at 384 px,
// under the 220-px fold — built (the rig's cache extent), offstage for a
// finder that skips offstage widgets.
Widget _sentPanel() => MaterialApp(
  home: Scaffold(
    body: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
        children: [
          for (final id in ['r1', 'r2', 'r3', 'r4'])
            SizedBox(key: Key('sealed-received-$id'), height: 96),
          const ListTile(
            key: Key('sealed-sent-s1'),
            dense: true,
            title: Text('written on the mac at 2026-10-09T23:22:12.925095Z'),
            subtitle: Text(
              'to a08887e8… · opened by them',
              key: Key('sealed-state-s1'),
            ),
          ),
        ],
      ),
    ),
  ),
);
