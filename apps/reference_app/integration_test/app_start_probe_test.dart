// Starts the real app through its own main() on a desktop and prints what
// came first: the window, or this install's identity.
//
//   flutter test integration_test/app_start_probe_test.dart -d macos
//
// main() no longer waits for the keystore, so the first frame must not
// depend on it. If the keychain is asking for its password, the line says
// `identity=pending` after the wait below and the run ends there — it does
// not wait for the person. Durations and public ids only.
@Timeout(Duration(minutes: 20))
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/intelligence/device_bindings.dart'
    show intelligenceStorageDirectory, letterQueueDirectory;
import 'package:reference_app/src/peer_identity.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app start probe: the window is up without waiting for the '
      'keystore', (tester) async {
    final watch = Stopwatch()..start();
    int? readyMs;
    void onPending() {
      if (!identityBootPending.value) readyMs ??= watch.elapsedMilliseconds;
    }

    identityBootPending.addListener(onPending);
    addTearDown(() => identityBootPending.removeListener(onPending));

    // The app's own entry point, not awaited to the end of its boot: the
    // probe pumps frames while main() goes on.
    final booted = app.main();
    int? windowMs;
    bool? pendingAtWindow;
    for (var i = 0; i < 300 && windowMs == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(app.MyApp).evaluate().isNotEmpty &&
          find.byType(Scaffold).evaluate().isNotEmpty) {
        windowMs = watch.elapsedMilliseconds;
        pendingAtWindow = identityBootPending.value;
      }
    }
    await tester.runAsync(() => booted.timeout(const Duration(seconds: 60)));
    // Up to 15 s for the identity, then report whatever is true.
    for (var i = 0; i < 150 && identityBootPending.value; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final identity = identityBootPending.value
        ? 'pending'
        : appIdentity != null
        ? 'present'
        : 'absent';
    final support = '/Library/Application Support/';
    // ignore: avoid_print
    print(
      'APP_START window_ms=${windowMs ?? '-'} '
      'identity_pending_at_window=${pendingAtWindow ?? '-'} '
      'identity=$identity identity_ready_ms=${readyMs ?? '-'} '
      '${identityBootTimings.entries.map((e) => '${e.key}=${e.value}').join(' ')} '
      'cards_dir=${intelligenceStorageDirectory().path.contains(support) ? 'app_support' : 'temp'} '
      'queue_dir=${letterQueueDirectory().path.contains(support) ? 'app_support' : 'temp'}',
    );
    expect(windowMs, isNotNull, reason: 'the app never showed its window');
  });
}
