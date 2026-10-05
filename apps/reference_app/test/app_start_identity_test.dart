// The window must not wait for the keystore, and no call may start before
// this install's identity is there. Unit level: a keystore that does not
// answer until told to. The real Mac run is a rig step, not this file.
import 'dart:async';

import 'package:call_core/call_core.dart' show CallPhase;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_screen.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/live_call_controller.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:security/security.dart';

/// A pin file whose first read waits until [answer] — a keystore or disk
/// that is waiting on the person.
class _WaitingStorage implements PersistentStorage {
  final Completer<void> answer = Completer<void>();

  /// Set before [answer] completes to make the answer a refusal.
  Object? failure;
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async {
    await answer.future;
    final refused = failure;
    if (refused != null) throw refused;
    return Map<String, Object?>.from(data);
  }

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = Map<String, Object?>.from(data);
  }
}

void main() {
  tearDown(() {
    appIdentity = null;
    identityBootPending.value = false;
  });

  group('the window does not wait for the keystore', () {
    test('a boot is pending until it has an answer, then not', () async {
      expect(identityBootPending.value, isFalse, reason: 'before any boot');
      final storage = _WaitingStorage();
      final boot = bootAppIdentity(
        AppIdentity(
          engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
          pins: PinnedPeerStore(storage),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(identityBootPending.value, isTrue);
      expect(appIdentity, isNull);

      storage.answer.complete();
      await boot;
      expect(identityBootPending.value, isFalse);
      expect(appIdentity, isNotNull);
    });

    test('a boot that fails also stops being pending', () async {
      final storage = _WaitingStorage();
      final boot = bootAppIdentity(
        AppIdentity(
          engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
          pins: PinnedPeerStore(storage),
        ),
      );
      storage.failure = StateError('keystore refused');
      storage.answer.complete();
      await boot;
      expect(identityBootPending.value, isFalse);
      expect(appIdentity, isNull);
      expect(identityBootError, isA<StateError>());
    });

    test('no call starts while the identity is pending, and one can the '
        'moment it is ready', () async {
      final pending = ValueNotifier<bool>(true);
      var opened = 0;
      var notified = 0;
      final controller = LiveCallController(
        open: ({required callId, required role}) async {
          opened++;
          return null;
        },
        identityPending: pending,
      )..addListener(() => notified++);
      addTearDown(controller.dispose);

      expect(controller.waitingForIdentity, isTrue);
      expect(controller.canCall, isFalse);
      controller.placeCall();
      controller.joinCall('AbC-123_xyz.ok');
      await Future<void>.delayed(Duration.zero);
      expect(opened, 0, reason: 'no session was built');
      expect(controller.phase, CallPhase.idle);
      expect(controller.callId, isNull);

      pending.value = false;
      expect(notified, greaterThan(0), reason: 'the screen is told');
      expect(controller.canCall, isTrue);
      controller.placeCall();
      await Future<void>.delayed(Duration.zero);
      expect(opened, 1);
    });

    test('a controller given no identity signal is never held back', () {
      final controller = LiveCallController(
        open: ({required callId, required role}) async => null,
      );
      addTearDown(controller.dispose);
      expect(controller.waitingForIdentity, isFalse);
      expect(controller.canCall, isTrue);
    });

    testWidgets('the call screen says why the buttons are off', (tester) async {
      Widget screen({required bool preparing}) => MaterialApp(
        home: Scaffold(
          body: CallScreen(
            phase: CallPhase.idle,
            preparingIdentity: preparing,
            onCall: preparing ? null : () {},
          ),
        ),
      );
      await tester.pumpWidget(screen(preparing: true));
      expect(find.byKey(const Key('call-identity-preparing')), findsOneWidget);
      await tester.pumpWidget(screen(preparing: false));
      expect(find.byKey(const Key('call-identity-preparing')), findsNothing);
    });
  });
}
