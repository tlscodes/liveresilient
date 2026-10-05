// "Verified" arrives only by the person's comparison. Two real installs (real
// Ed25519, in-process data channel), the same handshake the app starts on a
// live call, and the call screen wired the way main.dart wires it. Lab only:
// the loopback stands in for a call; nothing here is a device result.
import 'dart:io';
import 'dart:typed_data';

import 'package:call_core/call_core.dart' show CallPhase;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_screen.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/loopback_port.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:security/security.dart';

class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async => Map<String, Object?>.from(data);

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = Map<String, Object?>.from(data);
  }
}

/// One install: its own seed store and its own pin file.
class _Install {
  _Install() : seeds = InMemoryKeyStore(), pins = _MemoryStorage();

  final InMemoryKeyStore seeds;
  final _MemoryStorage pins;

  /// A fresh object over the same stores — what a relaunch is.
  AppIdentity open() => AppIdentity(
    engine: CryptographyIdentityKeyEngine(keyStore: seeds),
    pins: PinnedPeerStore(pins),
  );

  Iterable<String> get confirmations =>
      pins.data.keys.where((k) => k.startsWith('verified:'));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// One live call between side A (the screen under test) and side B, wired
/// as main.dart wires it: onTrust publishes the reading and rebuilds.
class _Rig {
  IdentityHandshake? a;
  IdentityHandshake? b;
  final told = <PeerTrust>[];
  final tick = ValueNotifier<int>(0);

  /// Must run inside `tester.runAsync`: real Ed25519, real timers.
  Future<void> call(AppIdentity sideA, AppIdentity sideB, String id) async {
    await hangUp();
    peerTrust.value = null;
    final (portA, portB) = pairLoopbackPorts();
    a = IdentityHandshake(
      port: portA,
      identity: sideA,
      callId: id,
      onTrust: (reading) {
        told.add(reading);
        peerTrust.value = reading;
        tick.value++;
      },
    );
    b = IdentityHandshake(port: portB, identity: sideB, callId: id);
    await a!.start();
    await b!.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    tick.value++;
  }

  Future<void> hangUp() async {
    final (oldA, oldB) = (a, b);
    a = null;
    b = null;
    await oldA?.dispose();
    await oldB?.dispose();
  }

  Widget screen() => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<int>(
        valueListenable: tick,
        builder: (context, _, _) => CallScreen(
          phase: CallPhase.connected,
          safetyNumber: a?.safetyNumber,
          onSafetyNumbersMatch: a?.confirmMatch,
          onSafetyNumbersDiffer: a?.denyMatch,
        ),
      ),
    ),
  );
}

const _unverifiedRow = Key('call-peer-trust-unverified');
const _verifiedRow = Key('call-peer-trust-verified');
const _changedRow = Key('call-peer-trust-changed');
const _hint = Key('call-peer-trust-compare-hint');
const _sheet = Key('safety-number-sheet');
const _digits = Key('safety-number-digits');
const _match = Key('safety-number-match');
const _mismatch = Key('safety-number-mismatch');

String _shownDigits(WidgetTester tester) => tester
    .widget<SelectableText>(find.byKey(_digits))
    .data!
    .split(RegExp(r'\s+'))
    .join(' ');

/// Taps [key], lets the queued disk write finish, then settles the screen.
Future<void> _tapAndSettle(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => peerTrust.value = null);

  group('unverified: the number is on screen, nothing is automatic', () {
    testWidgets('the row opens the same sixty digits both sides compute', (
      tester,
    ) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());

      expect(find.byKey(_unverifiedRow), findsOneWidget);
      expect(find.byKey(_hint), findsOneWidget);
      expect(find.text('Compare safety numbers to confirm'), findsOneWidget);

      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsOneWidget);

      final expected = (await tester.runAsync(() async {
        final ia = a.open();
        final ib = b.open();
        return ia.store.safetyNumber(
          localPublicKey: (await ia.store.localIdentity()).publicKey,
          remotePublicKey: (await ib.store.localIdentity()).publicKey,
        );
      }))!;
      final shown = _shownDigits(tester);
      expect(shown, expected);
      expect(shown, rig.b!.safetyNumber, reason: 'both phones show it');
      expect(shown, matches(RegExp(r'^\d{5}( \d{5}){11}$')));

      await tester.runAsync(rig.hangUp);
    });

    testWidgets('closing the sheet, or another call, never verifies', (
      tester,
    ) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());

      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsOneWidget);
      // Dismissed with no answer.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsNothing);
      expect(find.byKey(_unverifiedRow), findsOneWidget);
      expect(a.confirmations, isEmpty);

      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-2'));
      await tester.pump();
      expect(find.byKey(_unverifiedRow), findsOneWidget);
      expect(rig.told, everyElement(PeerTrust.unverified));
      expect(a.confirmations, isEmpty);

      await tester.runAsync(rig.hangUp);
    });
  });

  group('verified: only after the person taps "They match"', () {
    testWidgets('the tap stores the confirmation for that key, on one side', (
      tester,
    ) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());

      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, _match);

      expect(find.byKey(_sheet), findsNothing);
      expect(find.byKey(_verifiedRow), findsOneWidget);
      expect(find.byKey(_hint), findsNothing);
      final (bInstall, bKey) = (await tester.runAsync(() async {
        final ib = b.open();
        return (
          _hex(await ib.installId()),
          (await ib.store.localIdentity()).publicKey,
        );
      }))!;
      expect(a.pins.data['verified:$bInstall'], _hex(bKey));
      // Each side confirms for itself.
      expect(rig.b!.trust.value, PeerTrust.unverified);
      expect(b.confirmations, isEmpty);

      await tester.runAsync(rig.hangUp);
    });

    testWidgets('the confirmation survives a relaunch with no tap', (
      tester,
    ) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());
      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, _match);

      // Fresh objects over the same stores, and a new call id.
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-2'));
      await tester.pump();
      expect(find.byKey(_verifiedRow), findsOneWidget);
      expect(rig.told.last, PeerTrust.verified);

      await tester.runAsync(rig.hangUp);
    });

    test('the confirmation is on disk, read back by a new store', () async {
      final dir = await Directory.systemTemp.createTemp('vck-safety-');
      addTearDown(() => dir.delete(recursive: true));
      PinnedPeerStore store() => PinnedPeerStore(
        DiskJsonStorage(
          directoryFactory: () => dir,
          fileName: 'peer_identities.json',
        ),
      );
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final other = Uint8List.fromList(List<int>.generate(32, (i) => 31 - i));
      final first = AppIdentity(
        engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
        pins: store(),
      );
      await first.markVerified('peer-1', key);

      final relaunched = AppIdentity(
        engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
        pins: store(),
      );
      expect(await relaunched.isVerified('peer-1', key), isTrue);
      expect(await relaunched.isVerified('peer-1', other), isFalse);
      await relaunched.clearVerified('peer-1');
      expect(await store().read('verified:peer-1'), isNull);
    });

    testWidgets('"Not the same" takes the confirmation back', (tester) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());
      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, _match);
      expect(find.byKey(_verifiedRow), findsOneWidget);

      await tester.tap(find.byKey(_verifiedRow));
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, _mismatch);

      expect(find.byKey(_sheet), findsNothing);
      expect(find.byKey(_unverifiedRow), findsOneWidget);
      expect(a.confirmations, isEmpty);

      await tester.runAsync(rig.hangUp);
    });
  });

  group('changed: the call stops, the old key keeps its confirmation', () {
    testWidgets('an impostor under a verified install id', (tester) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-1'));
      await tester.pumpWidget(rig.screen());
      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      await _tapAndSettle(tester, _match);
      expect(find.byKey(_verifiedRow), findsOneWidget);

      final (bInstall, bKey) = (await tester.runAsync(() async {
        final ib = b.open();
        return (
          _hex(await ib.installId()),
          (await ib.store.localIdentity()).publicKey,
        );
      }))!;
      // b's public install id, a key of its own.
      final impostor = _Install();
      impostor.pins.data = {'install-id': bInstall};
      rig.told.clear();
      await tester.runAsync(
        () => rig.call(a.open(), impostor.open(), 'call-2'),
      );
      await tester.pump();

      expect(find.byKey(_changedRow), findsOneWidget);
      expect(rig.told, [PeerTrust.changed], reason: 'the hang-up hook fired');
      expect(rig.a!.safetyNumber, isNull);
      expect(find.byKey(_hint), findsNothing);
      await tester.tap(find.byKey(_changedRow));
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsNothing);
      // The stranger erased nothing: what was confirmed was b's key.
      expect(a.pins.data['verified:$bInstall'], _hex(bKey));

      // The real b again: still pinned and still verified. An impostor
      // cannot make the person verify twice.
      await tester.runAsync(() => rig.call(a.open(), b.open(), 'call-3'));
      await tester.pump();
      expect(find.byKey(_verifiedRow), findsOneWidget);
      expect(
        await tester.runAsync(
          () => a.open().store.checkRemoteIdentity(
            peerId: bInstall,
            presentedPublicKey: bKey,
          ),
        ),
        RemoteIdentityCheck.match,
      );

      await tester.runAsync(rig.hangUp);
    });
  });

  group('guards', () {
    testWidgets('a confirm after changed, or after dispose, writes nothing', (
      tester,
    ) async {
      final a = _Install();
      final b = _Install();
      final rig = _Rig();
      await tester.runAsync(() async {
        await rig.call(a.open(), b.open(), 'call-1');
        final bInstall = _hex(await b.open().installId());
        final impostor = _Install();
        impostor.pins.data = {'install-id': bInstall};
        await rig.call(a.open(), impostor.open(), 'call-2');
        expect(rig.a!.trust.value, PeerTrust.changed);
        await rig.a!.confirmMatch();
        expect(a.confirmations, isEmpty);
        expect(rig.a!.trust.value, PeerTrust.changed);

        await rig.call(a.open(), b.open(), 'call-3');
        final ended = rig.a!;
        await rig.hangUp();
        await ended.confirmMatch();
        expect(a.confirmations, isEmpty);
      });
    });

    testWidgets('no number: the row shows, no hint, the tap does nothing', (
      tester,
    ) async {
      peerTrust.value = PeerTrust.unverified;
      await tester.pumpWidget(
        const MaterialApp(home: CallScreen(phase: CallPhase.connected)),
      );
      expect(find.byKey(_unverifiedRow), findsOneWidget);
      expect(find.byKey(_hint), findsNothing);
      await tester.tap(find.byKey(_unverifiedRow));
      await tester.pumpAndSettle();
      expect(find.byKey(_sheet), findsNothing);
    });
  });
}
