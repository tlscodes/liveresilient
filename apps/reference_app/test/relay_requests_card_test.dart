// The request counter on the diagnostics screen: what this install has
// cost the relay today, as the service itself counts it. Lab only.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/relay_requests.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:reference_app/src/ui/relay_requests_card.dart';
import 'package:reference_app/src/ui/settings_screen.dart';
import 'package:reference_app/src/ui/tokens.dart';
import 'package:security/security.dart';

import 'support/memory_shelf.dart';

class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async =>
      jsonDecode(jsonEncode(data)) as Map<String, Object?>;

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = jsonDecode(jsonEncode(data)) as Map<String, Object?>;
  }
}

SealedLetterService _service(RequestBudget? budget) => SealedLetterService(
  identity: AppIdentity(
    engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
    pins: PinnedPeerStore(_MemoryStorage()),
  ),
  shelf: MemoryRelay().shelfOf('00' * 16),
  storage: _MemoryStorage(),
  budget: budget,
);

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  Future<void> show(
    WidgetTester tester,
    ValueListenable<SealedLetterService?> service,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: RelayRequestsCard(service: service)),
    ),
  );

  testWidgets('no letter service, no card', (tester) async {
    await show(tester, ValueNotifier<SealedLetterService?>(null));
    expect(find.byKey(const Key('relay-requests')), findsNothing);
  });

  testWidgets('a service that counts against nothing shows nothing', (
    tester,
  ) async {
    await show(tester, ValueNotifier<SealedLetterService?>(_service(null)));
    expect(find.byKey(const Key('relay-requests')), findsNothing);
  });

  testWidgets('the count, the cap and the longest open request, as they '
      'change', (tester) async {
    final budget = RequestBudget(dailyCap: 10, lookShare: 0.5);
    await show(tester, ValueNotifier<SealedLetterService?>(_service(budget)));
    expect(find.text('Relay requests today'), findsOneWidget);
    expect(_text(tester, 'relay-requests-today'), '0 of 10');
    expect(
      _text(tester, 'relay-requests-state'),
      'looking stops at 5; the rest is kept for writing',
    );

    expect(budget.take(write: false), isTrue);
    budget.done(const Duration(milliseconds: 310));
    await tester.pump();
    expect(_text(tester, 'relay-requests-today'), '1 of 10');
    expect(
      _text(tester, 'relay-requests-detail'),
      'since this start 1 · longest open 310 ms · not sent today 0',
    );

    while (budget.take(write: false)) {
      budget.done(Duration.zero);
    }
    await tester.pump();
    expect(_text(tester, 'relay-requests-today'), '5 of 10');
    expect(
      _text(tester, 'relay-requests-state'),
      'looking has stopped until 00:00 UTC; the rest is kept for writing',
    );
    expect(
      _text(tester, 'relay-requests-detail'),
      contains('not sent today 1'),
    );

    while (budget.take(write: true)) {
      budget.done(Duration.zero);
    }
    await tester.pump();
    expect(_text(tester, 'relay-requests-today'), '10 of 10');
    expect(
      _text(tester, 'relay-requests-state'),
      'used up — nothing more is sent until 00:00 UTC',
    );
  });

  testWidgets('it is on the settings screen, under the network section, '
      'once the app has a letter service', (tester) async {
    final budget = RequestBudget();
    final service = _service(budget);
    sealedLetterService.value = service;
    addTearDown(() => sealedLetterService.value = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppThemeData(Brightness.light),
        home: SettingsScreen(themeMode: ThemeMode.light, onThemeMode: (_) {}),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('relay-requests')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(_text(tester, 'relay-requests-today'), '0 of 3000');
  });
}
