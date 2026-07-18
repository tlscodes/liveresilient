import 'dart:convert';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('DeviceLinkAdapter', () {
    late FakeLocalLinkPort link;
    late FakeConsent consent;
    late FakeSigner signer;
    late FakeVerifier verifier;
    late EnvelopeValidator validator;
    late DeviceLinkAdapter adapter;
    const nowMs = 1700000000000;

    setUp(() {
      link = FakeLocalLinkPort();
      consent = FakeConsent(granted: false);
      signer = FakeSigner('local-device');
      verifier = FakeVerifier({'local-device'});
      validator = EnvelopeValidator(verifier: verifier);
      adapter = DeviceLinkAdapter(
        link: link,
        consent: consent,
        signer: signer,
        validator: validator,
        nowMs: () => nowMs,
      );
    });

    tearDown(() async {
      await adapter.dispose();
    });

    test('send is blocked without consent, even in degraded mode', () async {
      consent.granted = false;
      adapter.degradedModeActive = true;

      final result = await adapter.send(utf8.encode('payload'));

      expect(result.status, SendStatus.unavailable);
      expect(link.sentBytes, isEmpty);
    });

    test(
      'send is blocked when degraded mode is not active, even with consent',
      () async {
        consent.granted = true;
        adapter.degradedModeActive = false;

        final result = await adapter.send(utf8.encode('payload'));

        expect(result.status, SendStatus.unavailable);
        expect(link.sentBytes, isEmpty);
      },
    );

    test(
      'send delivers once consent is granted and degraded mode is active',
      () async {
        consent.granted = true;
        adapter.degradedModeActive = true;

        final result = await adapter.send(utf8.encode('payload'));

        expect(result.status, SendStatus.ok);
        expect(link.sentBytes, hasLength(1));
      },
    );

    test('revoking consent mid-session blocks the very next send', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;

      final first = await adapter.send(utf8.encode('first'));
      expect(first.status, SendStatus.ok);

      consent.granted = false;

      final second = await adapter.send(utf8.encode('second'));

      expect(second.status, SendStatus.unavailable);
      expect(
        link.sentBytes,
        hasLength(1),
        reason: 'the second send must never reach the link',
      );
    });

    test('a malformed inbound frame is dropped silently and never surfaces on '
        'inbound', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;

      final received = <AuthenticatedEnvelope>[];
      final sub = adapter.inbound.listen(received.add);

      link.pushIncoming(utf8.encode('not a valid envelope'));
      // Let the frame-handling futures resolve without a real timer.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      await sub.cancel();
    });

    test(
      'probe returns false without even checking the link when inactive',
      () async {
        consent.granted = false;
        adapter.degradedModeActive = false;

        expect(await adapter.probe(), isFalse);
      },
    );

    test('probe reflects link reachability once activated', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;

      link.reachable = true;
      expect(await adapter.probe(), isTrue);

      link.reachable = false;
      expect(await adapter.probe(), isFalse);
    });

    test('probe returns false, not an error, when the link throws', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;
      link.throwOnReachable = true;

      expect(await adapter.probe(), isFalse);
    });

    test('send reports unavailable (not transient) when the payload exceeds '
        'the local link limit', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;
      final oversized = List<int>.filled(maxLocalPayloadBytes + 1, 1);

      final result = await adapter.send(oversized);

      expect(result.status, SendStatus.unavailable);
      expect(result.error, isA<FormatException>());
      expect(link.sentBytes, isEmpty);
    });

    test('send reports transient when the link itself throws', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;
      link.throwOnSend = true;

      final result = await adapter.send(utf8.encode('payload'));

      expect(result.status, SendStatus.transient);
    });

    test('send lets a programming Error from the link propagate instead of '
        'masquerading as SendStatus.transient', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;
      link.throwErrorOnSend = true;

      expect(
        () => adapter.send(utf8.encode('payload')),
        throwsA(isA<StateError>()),
      );
    });

    test('name identifies this as the local-peer path', () {
      expect(adapter.name, 'local-peer');
    });

    test('degradedModeActive getter reflects what the setter last set', () {
      expect(adapter.degradedModeActive, isFalse);

      adapter.degradedModeActive = true;

      expect(adapter.degradedModeActive, isTrue);
    });

    test('a validly authenticated inbound frame surfaces on inbound', () async {
      consent.granted = true;
      adapter.degradedModeActive = true;

      final received = <AuthenticatedEnvelope>[];
      final sub = adapter.inbound.listen(received.add);

      final peerEnvelope = await AuthenticatedEnvelope.create(
        signer: signer,
        payload: utf8.encode('from peer'),
        nowMs: nowMs,
      );
      link.pushIncoming(peerEnvelope.toBytes());

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.nonce, peerEnvelope.nonce);
      await sub.cancel();
    });
  });
}
