import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:clock/clock.dart';
import 'package:security/security.dart';
import 'package:test/test.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

/// RFC 5769 section 2.1 — the official sample STUN request, byte for byte.
final rfc5769Request = hex('''
  000100582112a442b7e7a701bc34d686fa87dfae
  802200105354554e207465737420636c69656e74
  002400046e0001ff
  80290008932ff9b151263b36
  000600096576746a3a68367659202020
  000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2
  80280004e57a3bcf
''');
const rfc5769Password = 'VOkJxbRl1RmTxUk/WvJxBt';

void main() {
  group('STUN codec against RFC 5769 official vectors', () {
    test('sample request: parse, MESSAGE-INTEGRITY and FINGERPRINT verify', () {
      final msg = StunMessage.parse(rfc5769Request);
      expect(msg.type, 0x0001);
      expect(String.fromCharCodes(msg.attribute(stunAttrUsername)!.value),
          'evtj:h6vY');
      expect(
        msg.verifyMessageIntegrity(StunMessage.shortTermKey(rfc5769Password)),
        isTrue,
        reason: 'official vector MUST verify',
      );
      expect(msg.verifyFingerprint(), isTrue);
    });

    test('any tampered byte kills integrity and fingerprint', () {
      final tampered = Uint8List.fromList(rfc5769Request);
      tampered[30] ^= 0x01; // inside SOFTWARE
      final msg = StunMessage.parse(tampered);
      expect(
        msg.verifyMessageIntegrity(StunMessage.shortTermKey(rfc5769Password)),
        isFalse,
      );
      expect(msg.verifyFingerprint(), isFalse);
    });

    test('wrong password fails, long-term key derivation differs', () {
      final msg = StunMessage.parse(rfc5769Request);
      expect(
        msg.verifyMessageIntegrity(StunMessage.shortTermKey('wrong')),
        isFalse,
      );
      expect(
        StunMessage.longTermKey('user', 'realm', 'pass'),
        isNot(StunMessage.shortTermKey('pass')),
      );
    });

    test('builder round-trip with SHA256 integrity + fingerprint', () {
      final txn = Uint8List.fromList(List.generate(12, (i) => i + 1));
      final key = StunMessage.longTermKey('caller', 'relay', 'secret');
      final builder = StunMessageBuilder(type: 0x0001, transactionId: txn)
        ..addUsername('caller');
      final wire =
          builder.build(integrityKey: key, sha256Integrity: true, fingerprint: true);
      final parsed = StunMessage.parse(wire);
      expect(parsed.verifyMessageIntegritySha256(key), isTrue);
      expect(parsed.verifyFingerprint(), isTrue);
      expect(parsed.verifyMessageIntegritySha256(Uint8List(16)), isFalse);
    });

    test('measured: parse + SHA1 verify + fingerprint throughput', () {
      const n = 5000;
      final key = StunMessage.shortTermKey(rfc5769Password);
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        final m = StunMessage.parse(rfc5769Request);
        if (!m.verifyMessageIntegrity(key) || !m.verifyFingerprint()) {
          fail('vector must verify');
        }
      }
      sw.stop();
      final usPer = sw.elapsedMicroseconds / n;
      // ignore: avoid_print
      print('MEASURED stun parse+verify: ${usPer.toStringAsFixed(1)} us '
          'per message (${(1e6 / usPer / 1000).toStringAsFixed(0)}k msg/s)');
      expect(usPer, lessThan(1000));
    });
  });

  group('ChannelData framing + permissions (RFC 8656)', () {
    final peer = const HostPort(host: '203.0.113.9', port: 40000);

    test('wrap/unwrap round-trips and pads to 4 bytes', () {
      final binder = ChannelRelayBinder();
      final link = binder.bind(peer);
      expect(link.channelNumber, ChannelRelayBinder.firstChannel);
      final payload = Uint8List.fromList(List.generate(13, (i) => i));
      final frame = link.wrap(payload);
      expect(frame.length, 4 + 16, reason: '13 pads to 16 plus 4-byte header');
      expect(link.unwrap(frame), payload);
    });

    test('measured overhead: 4-byte header vs 36-byte Send indication', () {
      final binder = ChannelRelayBinder();
      final link = binder.bind(peer);
      final voice = Uint8List(160); // one 20 ms voice datagram
      final overhead = link.wrap(voice).length - voice.length;
      // ignore: avoid_print
      print('MEASURED ChannelData overhead: $overhead B vs '
          '${ChannelRelayLink.sendIndicationOverheadBytes} B indication '
          '(${(ChannelRelayLink.sendIndicationOverheadBytes - overhead)} B '
          'saved per datagram, 50/s => '
          '${(ChannelRelayLink.sendIndicationOverheadBytes - overhead) * 50} B/s)');
      expect(overhead, ChannelRelayLink.headerBytes);
    });

    test('no permission => loud failure, not a silent black hole', () {
      final binder = ChannelRelayBinder();
      final link = binder.bind(peer);
      withClock(Clock.fixed(clock.now().add(const Duration(seconds: 301))), () {
        expect(() => link.wrap(Uint8List(4)),
            throwsA(isA<PermissionNotInstalledException>()));
      });
    });

    test('binding expires at 600 s; refresh re-arms; dueForRefresh reports',
        () {
      final t0 = DateTime.utc(2026, 7, 26, 12);
      withClock(Clock.fixed(t0), () {
        final binder = ChannelRelayBinder();
        final link = binder.bind(peer);
        withClock(Clock.fixed(t0.add(const Duration(seconds: 550))), () {
          expect(binder.dueForRefresh(const Duration(seconds: 60)), [link]);
          binder.refresh(link);
          expect(binder.dueForRefresh(const Duration(seconds: 60)), isEmpty);
          expect(link.unwrap(link.wrap(Uint8List(8))), Uint8List(8));
        });
      });
    });

    test('distinct peers get distinct channels; wrong channel rejects', () {
      final binder = ChannelRelayBinder();
      final a = binder.bind(peer);
      final b = binder.bind(const HostPort(host: '203.0.113.10', port: 40001));
      expect(b.channelNumber, a.channelNumber + 1);
      expect(binder.bind(peer), same(a), reason: 'rebind returns same link');
      expect(() => b.unwrap(a.wrap(Uint8List(4))), throwsFormatException);
    });
  });

  group('MobilityRelayAllocator (RFC 8016 roaming)', () {
    final wifi = const HostPort(host: '10.0.0.5', port: 5000);
    final cell = const HostPort(host: '100.64.0.7', port: 6000);
    final server = const HostPort(host: 'turn.example', port: 3478);
    final relayed = const HostPort(host: '198.51.100.4', port: 50000);

    MobilityRelayAllocator build({
      Uint8List? ticket,
      bool refuseTicket = false,
      List<HostPort>? log,
    }) =>
        MobilityRelayAllocator(
          servers: [server],
          issuer: TurnCredentialsIssuer(sharedSecret: 's'),
          userId: 'u1',
          allocateWithTicket: (request) async {
            log?.add(request.tuple.localAddress);
            return (
              TurnAllocation(
                tuple: request.tuple,
                relayedAddress: relayed,
                serverReflexiveAddress: request.tuple.localAddress,
                expiresAt: clock.now().add(request.lifetime),
                credentials: request.credentials,
              ),
              ticket,
            );
          },
          refresh: (allocation, lifetime) async =>
              clock.now().add(lifetime),
          mobilityRefresh: (allocation, presented, newLocal) async {
            if (refuseTicket) throw const AllocationMismatchException();
            return (
              TurnAllocation(
                tuple: RelayFiveTuple(
                  localAddress: newLocal,
                  serverAddress: allocation.tuple.serverAddress,
                ),
                relayedAddress: allocation.relayedAddress,
                serverReflexiveAddress: newLocal,
                expiresAt: clock.now().add(const Duration(seconds: 600)),
                credentials: allocation.credentials,
              ),
              null,
            );
          },
        );

    test('roam with ticket keeps the relayed address, zero re-allocates',
        () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 7, 26)), () async {
        final allocator = build(ticket: Uint8List.fromList([1, 2, 3]));
        final first = await allocator.ensure(localAddress: wifi);
        expect(allocator.hasMobilityTicket, isTrue);
        final moved = await allocator.ensure(localAddress: cell);
        expect(moved.relayedAddress, first.relayedAddress,
            reason: 'peers keep sending to the same relayed address');
        expect(moved.tuple.localAddress, cell);
        expect(allocator.mobilityRoamCount, 1);
        expect(allocator.allocateCount, 1, reason: 'no second Allocate');
        expect(allocator.roamCount, 0);
        expect(allocator.currentAllocation, same(moved));
      });
    });

    test('server refusing the ticket (437) falls back to full re-allocate',
        () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 7, 26)), () async {
        final log = <HostPort>[];
        final allocator = build(
            ticket: Uint8List.fromList([9]), refuseTicket: true, log: log);
        await allocator.ensure(localAddress: wifi);
        final moved = await allocator.ensure(localAddress: cell);
        expect(moved.tuple.localAddress, cell);
        expect(allocator.mobilityRoamCount, 0);
        expect(allocator.allocateCount, 2);
        expect(log, [wifi, cell]);
        expect(allocator.hasMobilityTicket, isTrue,
            reason: 'the fallback Allocate issued a fresh ticket; the refused '
                'one was discarded before the re-allocate');
      });
    });

    test('no ticket at all behaves exactly like the base allocator', () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 7, 26)), () async {
        final allocator = build(ticket: null);
        await allocator.ensure(localAddress: wifi);
        await allocator.ensure(localAddress: cell);
        expect(allocator.mobilityRoamCount, 0);
        expect(allocator.allocateCount, 2);
      });
    });

    test('moved allocation refreshes at margin and releases cleanly',
        () async {
      final t0 = DateTime.utc(2026, 7, 26);
      final allocator = build(ticket: Uint8List.fromList([7]));
      await withClock(Clock.fixed(t0), () async {
        await allocator.ensure(localAddress: wifi);
        await allocator.ensure(localAddress: cell);
      });
      await withClock(Clock.fixed(t0.add(const Duration(seconds: 550))),
          () async {
        final refreshed = await allocator.ensure(localAddress: cell);
        expect(allocator.refreshCount, 1);
        expect(refreshed.tuple.localAddress, cell);
        await allocator.release();
        expect(allocator.currentAllocation, isNull);
        expect(allocator.hasMobilityTicket, isFalse);
      });
    });
  });
}
