// Two answers only a person can give, and what the app remembers of them:
// "these numbers are not the same", and "this peer really has a new key".
// Real Ed25519, an in-process data channel, the handshake the app starts on
// a live call and the call screen wired as main.dart wires it. Lab only: a
// second install with the same install id is built here, not on a device.
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

  Iterable<String> keys(String prefix) =>
      pins.data.keys.where((k) => k.startsWith(prefix));
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The same person after a reinstall: [of]'s public install id, a new key.
Future<_Install> _reinstalled(_Install of) async {
  final next = _Install();
  next.pins.data = {'install-id': _hex(await of.open().installId())};
  return next;
}

/// One call between [a] and [b]. Returns a's handshake still open, so the
/// test can answer as the person would; [after] closes both.
Future<(IdentityHandshake, Future<void> Function())> _call(
  _Install a,
  _Install b,
  String callId, {
  void Function(PeerTrust)? onTrust,
}) async {
  final (portA, portB) = pairLoopbackPorts();
  final ha = IdentityHandshake(
    port: portA,
    identity: a.open(),
    callId: callId,
    onTrust: onTrust,
  );
  final hb = IdentityHandshake(port: portB, identity: b.open(), callId: callId);
  await ha.start();
  await hb.start();
  await Future<void>.delayed(const Duration(milliseconds: 80));
  return (
    ha,
    () async {
      await ha.dispose();
      await hb.dispose();
    },
  );
}

Future<(String, Uint8List)> _idAndKey(_Install install) async {
  final identity = install.open();
  return (
    _hex(await identity.installId()),
    (await identity.store.localIdentity()).publicKey,
  );
}

void main() {
  setUp(() {
    pendingKeyChange.value = null;
    peerTrust.value = null;
  });

  group('"Not the same" is remembered', () {
    test('the next call still says the person refused this key', () async {
      final a = _Install();
      final b = _Install();
      final (bId, _) = await _idAndKey(b);

      var (ha, after) = await _call(a, b, 'call-1');
      expect(ha.trust.value, PeerTrust.unverified);
      expect(ha.saidDifferent, isFalse);
      await ha.denyMatch();
      expect(ha.trust.value, PeerTrust.unverified);
      expect(ha.saidDifferent, isTrue);
      expect(a.keys('differed:'), ['differed:$bId']);
      await after();

      // A relaunch and another call: nothing forgot.
      (ha, after) = await _call(a, b, 'call-2');
      expect(ha.trust.value, PeerTrust.unverified);
      expect(ha.saidDifferent, isTrue);
      expect(ha.safetyNumber, isNotNull, reason: 'it can still be compared');
      await after();
    });

    test('a later match takes the refusal back, for good', () async {
      final a = _Install();
      final b = _Install();

      var (ha, after) = await _call(a, b, 'call-1');
      await ha.denyMatch();
      await ha.confirmMatch();
      expect(ha.trust.value, PeerTrust.verified);
      expect(ha.saidDifferent, isFalse);
      expect(a.keys('differed:'), isEmpty);
      await after();

      (ha, after) = await _call(a, b, 'call-2');
      expect(ha.trust.value, PeerTrust.verified);
      expect(ha.saidDifferent, isFalse);
      await after();
    });

    test('it is said about one key, and never follows another', () async {
      final a = _Install();
      final b = _Install();
      final (bId, bKey) = await _idAndKey(b);
      final (ha, after) = await _call(a, b, 'call-1');
      await ha.denyMatch();
      await after();

      final identity = a.open();
      expect(await identity.saidDifferent(bId, bKey), isTrue);
      final (_, otherKey) = await _idAndKey(_Install());
      expect(await identity.saidDifferent(bId, otherKey), isFalse);
      expect(await identity.saidDifferent('someone-else', bKey), isFalse);
    });

    test('"Not the same" also drops an earlier confirmation', () async {
      final a = _Install();
      final b = _Install();
      final (ha, after) = await _call(a, b, 'call-1');
      await ha.confirmMatch();
      expect(a.keys('verified:'), hasLength(1));
      await ha.denyMatch();
      expect(a.keys('verified:'), isEmpty);
      expect(a.keys('differed:'), hasLength(1));
      await after();
    });
  });

  group('a legitimately new key is accepted only by the person', () {
    test('a changed key waits; nothing accepts it on its own', () async {
      final a = _Install();
      final b = _Install();
      final (bId, bKey) = await _idAndKey(b);
      var (ha, after) = await _call(a, b, 'call-1');
      await ha.confirmMatch();
      await after();
      expect(pendingKeyChange.value, isNull, reason: 'an ordinary call');

      final newB = await _reinstalled(b);
      (ha, after) = await _call(a, newB, 'call-2');
      expect(ha.trust.value, PeerTrust.changed);
      expect(pendingKeyChange.value?.peerInstall, bId);
      // Presenting a key erases nothing: the old key keeps what the person
      // confirmed about it.
      expect(a.pins.data['verified:$bId'], _hex(bKey));
      await after();

      // Unanswered: the pin is still the old key — which still reads
      // verified — and the new one is stopped again on the next call.
      (ha, after) = await _call(a, b, 'call-old');
      expect(ha.trust.value, PeerTrust.verified);
      await after();
      expect(
        await a.open().store.checkRemoteIdentity(
          peerId: bId,
          presentedPublicKey: bKey,
        ),
        RemoteIdentityCheck.match,
      );
      (ha, after) = await _call(a, newB, 'call-3');
      expect(ha.trust.value, PeerTrust.changed);
      await after();
    });

    test('accepted: the new key is pinned, starts not verified, and the old '
        'key is no longer trusted', () async {
      final a = _Install();
      final b = _Install();
      final (bId, _) = await _idAndKey(b);
      var (ha, after) = await _call(a, b, 'call-1');
      await ha.confirmMatch();
      await after();

      final newB = await _reinstalled(b);
      final (_, newKey) = await _idAndKey(newB);
      (ha, after) = await _call(a, newB, 'call-2');
      expect(ha.trust.value, PeerTrust.changed);
      await after();

      await pendingKeyChange.value!.accept();
      expect(pendingKeyChange.value, isNull);
      expect(a.keys('verified:'), isEmpty);
      expect(
        await a.open().store.checkRemoteIdentity(
          peerId: bId,
          presentedPublicKey: newKey,
        ),
        RemoteIdentityCheck.match,
      );

      // The new key: a match, and exactly as trusted as a first contact.
      (ha, after) = await _call(a, newB, 'call-3');
      expect(ha.trust.value, PeerTrust.unverified);
      expect(ha.saidDifferent, isFalse);
      expect(ha.safetyNumber, isNotNull);
      await ha.confirmMatch();
      expect(ha.trust.value, PeerTrust.verified);
      await after();

      // The old key, presented again, is now the stranger.
      (ha, after) = await _call(a, b, 'call-4');
      expect(ha.trust.value, PeerTrust.changed);
      // And, like any stranger, it erases nothing: the confirmation given
      // to the new key is still the new key's.
      expect(a.pins.data['verified:$bId'], _hex(newKey));
      await after();
    });

    test('accepting clears a refusal said about the old key', () async {
      final a = _Install();
      final b = _Install();
      var (ha, after) = await _call(a, b, 'call-1');
      await ha.denyMatch();
      await after();
      expect(a.keys('differed:'), hasLength(1));

      final newB = await _reinstalled(b);
      (ha, after) = await _call(a, newB, 'call-2');
      await after();
      await pendingKeyChange.value!.accept();
      expect(a.keys('differed:'), isEmpty);

      (ha, after) = await _call(a, newB, 'call-3');
      expect(ha.saidDifferent, isFalse);
      await after();
    });
  });

  group('on the call screen', () {
    Widget screen({
      String? number,
      bool differed = false,
      Future<void> Function()? onAccept,
    }) => MaterialApp(
      home: Scaffold(
        body: CallScreen(
          phase: CallPhase.connected,
          safetyNumber: number,
          safetyNumbersDiffered: differed,
          onAcceptNewKey: onAccept,
        ),
      ),
    );
    const number =
        '11111 22222 33333 44444 55555 66666 '
        '77777 88888 99999 00000 11111 22222';

    testWidgets('a remembered refusal replaces the plain hint', (tester) async {
      peerTrust.value = PeerTrust.unverified;
      await tester.pumpWidget(screen(number: number));
      expect(
        find.byKey(const Key('call-peer-trust-compare-hint')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('call-peer-trust-differed-note')),
        findsNothing,
      );

      await tester.pumpWidget(screen(number: number, differed: true));
      expect(
        find.byKey(const Key('call-peer-trust-differed-note')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('call-peer-trust-compare-hint')),
        findsNothing,
      );
      // Still comparable: the person may have misread the first time.
      await tester.tap(find.byKey(const Key('call-peer-trust-unverified')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('safety-number-sheet')), findsOneWidget);
    });

    testWidgets('a verified reading never shows the refusal note', (
      tester,
    ) async {
      peerTrust.value = PeerTrust.verified;
      await tester.pumpWidget(screen(number: number, differed: true));
      expect(
        find.byKey(const Key('call-peer-trust-differed-note')),
        findsNothing,
      );
    });

    testWidgets('changed offers the new key only when there is one to '
        'accept, asks twice, and Cancel accepts nothing', (tester) async {
      var accepted = 0;
      peerTrust.value = PeerTrust.changed;
      await tester.pumpWidget(screen());
      expect(find.byKey(const Key('call-peer-accept-new-key')), findsNothing);

      await tester.pumpWidget(screen(onAccept: () async => accepted++));
      await tester.tap(find.byKey(const Key('call-peer-accept-new-key')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('accept-new-key-dialog')), findsOneWidget);
      expect(accepted, 0, reason: 'the first tap only asks');
      await tester.tap(find.byKey(const Key('accept-new-key-cancel')));
      await tester.pumpAndSettle();
      expect(accepted, 0);

      await tester.tap(find.byKey(const Key('call-peer-accept-new-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('accept-new-key-confirm')));
      await tester.pumpAndSettle();
      expect(accepted, 1);
    });

    testWidgets('no other reading offers to accept a key', (tester) async {
      for (final reading in [PeerTrust.unverified, PeerTrust.verified]) {
        peerTrust.value = reading;
        await tester.pumpWidget(screen(number: number, onAccept: () async {}));
        expect(find.byKey(const Key('call-peer-accept-new-key')), findsNothing);
      }
    });
  });
}
