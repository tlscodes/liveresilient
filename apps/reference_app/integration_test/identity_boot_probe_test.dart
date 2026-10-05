// Boots this install's identity inside the real desktop app and prints
// where the time went. No call, no phone, no rig.
//
//   flutter test integration_test/identity_boot_probe_test.dart -d macos
//
// `keystore_ms` is the read through the device keystore. On a Mac whose
// build is signed ad hoc, the login keychain asks for its password on
// every rebuild and this number is however long that took to answer; with
// a stable signature ("Always Allow" given once) it is the read alone.
// The line carries public ids and durations only.
@Timeout(Duration(minutes: 20))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart'
    show identityStorageDirectory;
import 'package:reference_app/src/peer_identity.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('identity boot probe: this install has an identity, and the '
      'boot says where its time went', (tester) async {
    final watch = Stopwatch()..start();
    await tester.runAsync(bootAppIdentity);
    final booted = appIdentity;
    final install = booted == null
        ? null
        : await tester.runAsync(booted.installId);
    final error = identityBootError;
    // ignore: avoid_print
    print(
      'IDENTITY_BOOT identity=${booted == null ? 'absent' : 'present'} '
      'cause=${booted != null
          ? 'none'
          : error == null
          ? 'unknown'
          : 'error:${error.runtimeType}'} '
      'ms=${watch.elapsedMilliseconds} '
      '${identityBootTimings.entries.map((e) => '${e.key}=${e.value}').join(' ')} '
      'pins=${identityStorageDirectory().path.contains('/Library/Application Support/') ? 'app_support' : 'shared'} '
      'install=${install == null ? '-' : _hex(install)}',
    );
    expect(booted, isNotNull, reason: 'this install has no identity: $error');
  });
}
