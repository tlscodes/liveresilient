// The rig's on-screen probe on the sealed panel's own geometry: a 220-px list
// with every row built (the rig build's cache extent), newest first — video,
// voice, a 96-px photo, then the text that full4 reported as not on screen.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';

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
}
