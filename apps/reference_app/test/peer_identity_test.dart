// Automatic identity pinning, with no keychain, no socket and no engine
// other than the real Ed25519 one: two installs, an in-process data channel
// pair, and the same handshake the app starts on a live call.
import 'dart:async';
import 'dart:typed_data';

import 'package:call_core/call_core.dart' show CallPhase;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart' show WireCodec;
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
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Runs one call's exchange between [a] and [b]; returns both readings.
Future<(PeerTrust?, PeerTrust?)> _call(
  AppIdentity a,
  AppIdentity b, {
  String callId = 'call-1',
}) async {
  final (portA, portB) = pairLoopbackPorts();
  final ha = IdentityHandshake(port: portA, identity: a, callId: callId);
  final hb = IdentityHandshake(port: portB, identity: b, callId: callId);
  await ha.start();
  await hb.start();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final readings = (ha.trust.value, hb.trust.value);
  await ha.dispose();
  await hb.dispose();
  return readings;
}

void main() {
  group('an install makes its own identity, once', () {
    test('the key is a real 32-byte key and survives a relaunch', () async {
      final install = _Install();
      final first = await install.open().store.localIdentity();
      expect(first.publicKey, hasLength(32));
      final again = await install.open().store.localIdentity();
      expect(again.publicKey, first.publicKey);
    });

    test('the install id is made once and survives a relaunch', () async {
      final install = _Install();
      final first = await install.open().installId();
      expect(first, hasLength(AppIdentity.installIdBytes));
      expect(await install.open().installId(), first);
    });

    test('two installs never share a key, an id, or a key id', () async {
      final a = _Install().open();
      final b = _Install().open();
      expect(
        (await a.store.localIdentity()).publicKey,
        isNot((await b.store.localIdentity()).publicKey),
      );
      expect(await a.installId(), isNot(await b.installId()));
      expect(await a.store.localKeyId(), isNot(await b.store.localKeyId()));
    });

    test(
      'the signalling key id is the identity\'s own, never a role name',
      () async {
        final identity = _Install().open();
        await bootAppIdentity(identity);
        addTearDown(() => appIdentity = null);
        expect(sessionKeyId(), await identity.store.localKeyId());
        expect(sessionKeyId(), isNot(contains('initiator')));
        expect(sessionKeyId(), isNot(contains('responder')));
      },
    );
  });

  group('the first call that connects pins both sides', () {
    test(
      'both read encrypted-not-verified and each holds the other\'s key',
      () async {
        final a = _Install().open();
        final b = _Install().open();
        final (ra, rb) = await _call(a, b);
        expect(ra, PeerTrust.unverified);
        expect(rb, PeerTrust.unverified);
        // The pin is real: presenting the same key again is a match.
        expect(
          await a.store.checkRemoteIdentity(
            peerId: _hex(await b.installId()),
            presentedPublicKey: (await b.store.localIdentity()).publicKey,
          ),
          RemoteIdentityCheck.match,
        );
        expect(
          await b.store.checkRemoteIdentity(
            peerId: _hex(await a.installId()),
            presentedPublicKey: (await a.store.localIdentity()).publicKey,
          ),
          RemoteIdentityCheck.match,
        );
      },
    );

    test('a side that starts listening late is still reached', () async {
      final a = _Install().open();
      final b = _Install().open();
      final (portA, portB) = pairLoopbackPorts();
      final ha = IdentityHandshake(port: portA, identity: a, callId: 'c');
      final hb = IdentityHandshake(port: portB, identity: b, callId: 'c');
      await ha.start(); // b is not listening: this hello is lost.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(hb.trust.value, isNull);
      await hb.start(); // b's hello reaches a; a's reply reaches b.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ha.trust.value, PeerTrust.unverified);
      expect(hb.trust.value, PeerTrust.unverified);
      await ha.dispose();
      await hb.dispose();
    });

    test(
      'a second call with the same peer is a match, still unverified',
      () async {
        final a = _Install();
        final b = _Install();
        await _call(a.open(), b.open());
        final (ra, rb) = await _call(a.open(), b.open(), callId: 'call-2');
        expect(ra, PeerTrust.unverified);
        expect(rb, PeerTrust.unverified);
      },
    );

    test(
      'a compared safety number reads verified from the next call on',
      () async {
        final a = _Install();
        final b = _Install();
        await _call(a.open(), b.open());
        final bIdentity = b.open();
        await a.open().markVerified(
          _hex(await bIdentity.installId()),
          (await bIdentity.store.localIdentity()).publicKey,
        );
        final (ra, _) = await _call(a.open(), b.open(), callId: 'call-2');
        expect(ra, PeerTrust.verified);
      },
    );
  });

  group('the sighting a rig run prints', () {
    tearDown(() => lastPeerSighting.value = null);

    test('names both installs and says first use, then match', () async {
      final a = _Install();
      final b = _Install();
      final aId = _hex(await a.open().installId());
      final bId = _hex(await b.open().installId());

      await _call(a.open(), b.open());
      final first = lastPeerSighting.value!;
      // The last frame judged was on one of the two sides.
      expect({first.install, first.peerInstall}, {aId, bId});
      expect(first.check, RemoteIdentityCheck.pinnedFirstUse);
      expect(first.trust, PeerTrust.unverified);

      await _call(a.open(), b.open(), callId: 'call-2');
      final second = lastPeerSighting.value!;
      expect({second.install, second.peerInstall}, {aId, bId});
      expect(second.check, RemoteIdentityCheck.match);
      expect(second.trust, PeerTrust.unverified);
    });

    test('carries public ids and enum names only', () async {
      await _call(_Install().open(), _Install().open());
      final json = lastPeerSighting.value!.toJson();
      expect(json.keys, ['at', 'install', 'peer_install', 'check', 'trust']);
      expect(json['check'], 'pinnedFirstUse');
      expect(json['trust'], 'unverified');
      expect(json['install'], hasLength(AppIdentity.installIdBytes * 2));
    });

    test('a changed key is reported as changed', () async {
      final a = _Install();
      final b = _Install();
      await _call(a.open(), b.open());
      final impostor = _Install();
      impostor.pins.data = {'install-id': _hex(await b.open().installId())};
      final aId = _hex(await a.open().installId());
      // Both sides judge, so every sighting is kept and a's is picked out.
      final seen = <PeerSighting>[];
      void keep() {
        final s = lastPeerSighting.value;
        if (s != null) seen.add(s);
      }

      lastPeerSighting.addListener(keep);
      addTearDown(() => lastPeerSighting.removeListener(keep));
      final (portA, portI) = pairLoopbackPorts();
      final ha = IdentityHandshake(
        port: portA,
        identity: a.open(),
        callId: 'c',
      );
      final hi = IdentityHandshake(
        port: portI,
        identity: impostor.open(),
        callId: 'c',
      );
      await ha.start();
      await hi.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await hi.dispose();
      await ha.dispose();
      final changed = seen.singleWhere((s) => s.install == aId);
      expect(changed.check, RemoteIdentityCheck.changed);
      expect(changed.trust, PeerTrust.changed);
    });
  });

  group('a changed key is never accepted silently', () {
    test('the same install id with another key reads changed, the caller is '
        'told, and the first pin stays', () async {
      final a = _Install();
      final b = _Install();
      await _call(a.open(), b.open());
      final bIdentity = b.open();
      final bInstall = _hex(await bIdentity.installId());
      final bKey = (await bIdentity.store.localIdentity()).publicKey;

      // An impostor: b's public install id, a key of its own.
      final impostor = _Install();
      impostor.pins.data = {'install-id': bInstall};

      final (portA, portI) = pairLoopbackPorts();
      final told = <PeerTrust>[];
      final ha = IdentityHandshake(
        port: portA,
        identity: a.open(),
        callId: 'call-2',
        onTrust: told.add,
      );
      final hi = IdentityHandshake(
        port: portI,
        identity: impostor.open(),
        callId: 'call-2',
      );
      await ha.start();
      await hi.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ha.trust.value, PeerTrust.changed);
      expect(told, [PeerTrust.changed]);
      // Not re-pinned: b's real key is still the one on file.
      expect(
        await a.open().store.checkRemoteIdentity(
          peerId: bInstall,
          presentedPublicKey: bKey,
        ),
        RemoteIdentityCheck.match,
      );
      await ha.dispose();
      await hi.dispose();
    });

    test(
      'a verified peer whose key changes reads changed, not verified',
      () async {
        final a = _Install();
        final b = _Install();
        await _call(a.open(), b.open());
        final bIdentity = b.open();
        final bInstall = _hex(await bIdentity.installId());
        await a.open().markVerified(
          bInstall,
          (await bIdentity.store.localIdentity()).publicKey,
        );
        final impostor = _Install();
        impostor.pins.data = {'install-id': bInstall};
        final (ra, _) = await _call(a.open(), impostor.open(), callId: 'c2');
        expect(ra, PeerTrust.changed);
      },
    );
  });

  group('a frame with no proof is not a peer', () {
    Future<List<int>> capture(AppIdentity identity, String callId) async {
      final (port, tap) = pairLoopbackPorts();
      final seen = Completer<List<int>>();
      final sub = tap.inbound.listen((f) {
        if (!seen.isCompleted) seen.complete(f);
      });
      final h = IdentityHandshake(
        port: port,
        identity: identity,
        callId: callId,
      );
      await h.start();
      final frame = await seen.future;
      await sub.cancel();
      await h.dispose();
      return frame;
    }

    Future<PeerTrust?> inject(
      AppIdentity into,
      String callId,
      List<int> frame,
    ) async {
      final (port, far) = pairLoopbackPorts();
      final h = IdentityHandshake(port: port, identity: into, callId: callId);
      await h.start();
      await far.send(frame);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final reading = h.trust.value;
      await h.dispose();
      return reading;
    }

    test('a real frame is the fixed size and is not a chat frame', () async {
      final frame = await capture(_Install().open(), 'c');
      expect(frame, hasLength(IdentityHandshake.frameBytes));
      expect(frame.sublist(0, 5), IdentityHandshake.magic);
      // The chat messenger on the same channel ignores it.
      expect(WireCodec.tryDecode(frame), isNull);
    });

    test('a frame whose signature was altered pins nothing', () async {
      final a = _Install();
      final frame = await capture(_Install().open(), 'c');
      final forged = Uint8List.fromList(frame)..[frame.length - 1] ^= 0xFF;
      expect(await inject(a.open(), 'c', forged), isNull);
      expect(
        a.pins.data.keys.where((k) => k.startsWith('peer-identity:')),
        isEmpty,
      );
    });

    test('a frame recorded in another call pins nothing', () async {
      final a = _Install();
      final recorded = await capture(_Install().open(), 'call-1');
      expect(await inject(a.open(), 'call-2', recorded), isNull);
      // The same frame in the call it was made for is accepted.
      expect(await inject(a.open(), 'call-1', recorded), PeerTrust.unverified);
    });

    test('an install never pins its own looped-back frame', () async {
      final a = _Install();
      final own = await capture(a.open(), 'c');
      expect(await inject(a.open(), 'c', own), isNull);
    });
  });

  group('the three readings on the call screen', () {
    tearDown(() => peerTrust.value = null);

    test('are three different sentences', () {
      expect(PeerTrust.values.map((t) => t.label).toSet(), hasLength(3));
      expect(PeerTrust.unverified.label, contains('not yet verified'));
      expect(PeerTrust.changed.label, contains('changed'));
    });

    for (final trust in [PeerTrust.unverified, PeerTrust.verified]) {
      testWidgets('${trust.name} shows on a live call', (tester) async {
        peerTrust.value = trust;
        await tester.pumpWidget(
          const MaterialApp(home: CallScreen(phase: CallPhase.connected)),
        );
        expect(
          find.byKey(Key('call-peer-trust-${trust.name}')),
          findsOneWidget,
        );
        expect(find.text(trust.label), findsOneWidget);
      });
    }

    testWidgets('changed stays readable after the call it stopped', (
      tester,
    ) async {
      peerTrust.value = PeerTrust.changed;
      await tester.pumpWidget(
        const MaterialApp(home: CallScreen(phase: CallPhase.ended)),
      );
      expect(find.byKey(const Key('call-peer-trust-changed')), findsOneWidget);
    });

    testWidgets('nothing is shown before the peer proved its key', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: CallScreen(phase: CallPhase.connected)),
      );
      expect(find.byKey(const Key('call-peer-trust-unverified')), findsNothing);
      // An unverified reading does not outlive its call.
      peerTrust.value = PeerTrust.unverified;
      await tester.pumpWidget(
        const MaterialApp(home: CallScreen(phase: CallPhase.ended)),
      );
      expect(find.byKey(const Key('call-peer-trust-unverified')), findsNothing);
    });
  });
}
