/// The recovery screen must never be able to deadlock itself.
///
/// This is the sheet a person opens when nothing else in the app works. Its
/// first version had no try/catch around the import, and `OobManifestImport`
/// only converts `FormatException` into a verdict — so a `TypeError` from a
/// JSON document of the wrong shape escaped, `_busy` stayed true forever, and
/// all three buttons were permanently disabled with no message shown. The user
/// could do nothing but dismiss the last-resort screen.
///
/// Everything here is a widget test rather than a unit test on purpose: the
/// defect lives in the interaction between the async import and `setState`, and
/// no unit test of either half can see it.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/import_manifest_sheet.dart';
import 'package:signed_config/signed_config.dart';

class _AlwaysThrows implements Ed25519Verifier {
  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async => throw StateError('crypto backend unavailable');
}

class _Accepts implements Ed25519Verifier {
  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async => true;
}

OobManifestImport _import(Ed25519Verifier crypto) => OobManifestImport(
  verifier: ManifestVerifier(
    pinnedKeys: [
      PinnedManifestKey(keyId: 'key-a', publicKey: List.filled(32, 9)),
    ],
    crypto: crypto,
  ),
  lastAcceptedRevision: () => 0,
);

String _validCode() {
  final doc = jsonEncode({
    'manifest': {
      'schemaVersion': manifestSchemaVersion,
      'revision': 4,
      'signingKeyId': 'key-a',
      'issuedAt': DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String(),
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(days: 7))
          .toIso8601String(),
      'signalingEndpoints': ['wss://relay.example/signal'],
      'iceServers': [
        {
          'urls': ['turns:relay.example:443'],
          'username': 'u',
          'credential': 'c',
        },
      ],
      'configServiceUris': ['https://config.example/manifest'],
    },
    'alg': 'ed25519',
    'signature': base64Encode(Uint8List(64)),
  });
  return CompactManifestCode.encode(utf8.encode(doc));
}

Future<void> _pump(WidgetTester tester, OobManifestImport import) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ImportManifestSheet(import: import)),
    ),
  );
}

void main() {
  testWidgets('an import that THROWS still leaves the sheet usable', (
    tester,
  ) async {
    await _pump(tester, _import(_AlwaysThrows()));

    await tester.enterText(find.byType(TextField), _validCode());
    await tester.tap(find.text('Check this code'));
    await tester.pumpAndSettle();

    // The defect: _busy stuck true and every button dead. The property that
    // matters is not the wording of the error — it is that the screen can be
    // used again at all.
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Check this code'),
    );
    expect(
      button.onPressed,
      isNotNull,
      reason: 'the recovery screen deadlocked itself',
    );
    expect(find.textContaining('fault in the app'), findsOneWidget);
  });

  testWidgets('a crash is named as an app fault, not as a trust failure', (
    tester,
  ) async {
    await _pump(tester, _import(_AlwaysThrows()));
    await tester.enterText(find.byType(TextField), _validCode());
    await tester.tap(find.text('Check this code'));
    await tester.pumpAndSettle();

    // Three failure classes, three recoveries: "read it again", "distrust the
    // source", "this is our bug". Collapsing the third into either of the
    // others sends the user to fix something that is not broken.
    expect(find.textContaining('not in your code'), findsOneWidget);
    expect(find.textContaining('Do not use it'), findsNothing);
  });

  testWidgets('an unreadable code is a READ failure, and offers no manifest', (
    tester,
  ) async {
    await _pump(tester, _import(_Accepts()));

    await tester.enterText(find.byType(TextField), 'CFM1-ZZZZZ-ZZZZZ');
    await tester.tap(find.text('Check this code'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not read'), findsOneWidget);
    expect(
      find.text('Use these settings'),
      findsNothing,
      reason: 'nothing verified, so nothing may be adopted',
    );
  });

  testWidgets('empty input does not offer a manifest either', (tester) async {
    await _pump(tester, _import(_Accepts()));
    await tester.tap(find.text('Check this code'));
    await tester.pumpAndSettle();
    expect(find.text('Use these settings'), findsNothing);
  });

  testWidgets('a verified code offers itself for adoption', (tester) async {
    await _pump(tester, _import(_Accepts()));

    await tester.enterText(find.byType(TextField), _validCode());
    await tester.tap(find.text('Check this code'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Verified'), findsOneWidget);
    expect(find.text('Use these settings'), findsOneWidget);
  });
}
