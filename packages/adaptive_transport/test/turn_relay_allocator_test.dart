import 'dart:typed_data';

// The package exports its own circuit-breaker Clock; this test needs the
// clock-package one for withClock time travel.
import 'package:adaptive_transport/adaptive_transport.dart' hide Clock;
import 'package:clock/clock.dart';
import 'package:security/security.dart';
import 'package:test/test.dart';

final _txId = Uint8List.fromList([
  0xB7,
  0xE7,
  0xA7,
  0x01,
  0xBC,
  0x34,
  0xD6,
  0x86,
  0xFA,
  0x87,
  0xDF,
  0xAE,
]);

/// 192.0.2.1 — RFC 5737 documentation address.
final _v4 = Uint8List.fromList([192, 0, 2, 1]);

const _servers = [
  HostPort(host: '198.51.100.1', port: 3478),
  HostPort(host: '198.51.100.2', port: 3478),
];

const _cellular = HostPort(host: '10.20.30.40', port: 50000);
const _wifi = HostPort(host: '192.168.1.24', port: 50001);

void main() {
  group('StunXorMappedAddress (RFC 8489)', () {
    test('IPv4 round-trips through the cookie/transaction-id XOR', () {
      final address = StunXorMappedAddress(
        family: stunFamilyIpv4,
        address: _v4,
        port: 32853,
      );
      final encoded = address.encode(_txId);
      expect(encoded.length, 8);
      expect(encoded[0], 0x00); // Reserved byte.
      expect(encoded[1], stunFamilyIpv4);
      // The wire bytes must be XOR-ed, i.e. not the plain address.
      expect(Uint8List.sublistView(encoded, 4), isNot(equals(_v4)));

      final decoded = StunXorMappedAddress.decode(encoded, _txId);
      expect(decoded.family, stunFamilyIpv4);
      expect(decoded.address, _v4);
      expect(decoded.port, 32853);
      expect(decoded.addressText, '192.0.2.1');
      expect(decoded.hostPort, const HostPort(host: '192.0.2.1', port: 32853));
    });

    test('the port is XOR-ed with the top 16 bits of the magic cookie', () {
      final encoded = StunXorMappedAddress(
        family: stunFamilyIpv4,
        address: _v4,
        port: 0x1234,
      ).encode(_txId);
      final onWire = (encoded[2] << 8) | encoded[3];
      expect(onWire, 0x1234 ^ ((stunMagicCookie >> 16) & 0xFFFF));
    });

    test('IPv6 round-trips over all 16 address bytes', () {
      final v6 = Uint8List.fromList([
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x00,
        0x10,
      ]);
      final decoded = StunXorMappedAddress.decode(
        StunXorMappedAddress(
          family: stunFamilyIpv6,
          address: v6,
          port: 443,
        ).encode(_txId),
        _txId,
      );
      expect(decoded.address, v6);
      expect(decoded.port, 443);
      expect(decoded.addressText, '2001:db8:0:0:0:0:0:10');
    });

    test('the transaction id masks IPv6 only; IPv4 uses the cookie alone', () {
      final wrongTx = Uint8List.fromList(_txId)..[0] ^= 0xFF;

      // IPv4 is 4 bytes, so only the 4 cookie bytes mask it — a wrong
      // transaction id still decodes correctly (RFC 8489 section 14.2).
      final v4Encoded = StunXorMappedAddress(
        family: stunFamilyIpv4,
        address: _v4,
        port: 3478,
      ).encode(_txId);
      expect(StunXorMappedAddress.decode(v4Encoded, wrongTx).address, _v4);

      // IPv6 consumes cookie + transaction id, so a wrong id corrupts it.
      final v6 = Uint8List.fromList([
        0x20,
        0x01,
        0x0D,
        0xB8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
      ]);
      final v6Encoded = StunXorMappedAddress(
        family: stunFamilyIpv6,
        address: v6,
        port: 3478,
      ).encode(_txId);
      expect(StunXorMappedAddress.decode(v6Encoded, _txId).address, v6);
      expect(
        StunXorMappedAddress.decode(v6Encoded, wrongTx).address,
        isNot(equals(v6)),
      );
    });

    test('rejects malformed attributes and bad transaction ids', () {
      expect(
        () => StunXorMappedAddress.decode(Uint8List(3), _txId),
        throwsA(isA<FormatException>()),
      );
      // Family 0x03 is not registered.
      expect(
        () => StunXorMappedAddress.decode(
          Uint8List.fromList([0, 0x03, 0, 0, 1, 2, 3, 4]),
          _txId,
        ),
        throwsA(isA<FormatException>()),
      );
      // IPv4 family with an IPv6-sized body.
      expect(
        () => StunXorMappedAddress.decode(
          Uint8List(4 + 16)..[1] = stunFamilyIpv4,
          _txId,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => StunXorMappedAddress(
          family: stunFamilyIpv4,
          address: _v4,
          port: 3478,
        ).encode(Uint8List(11)),
        throwsArgumentError,
      );
      expect(
        () => StunXorMappedAddress(
          family: stunFamilyIpv4,
          address: Uint8List(16),
          port: 3478,
        ).encode(_txId),
        throwsArgumentError,
      );
    });
  });

  group('TurnRelayAllocator (RFC 8656)', () {
    final at = DateTime.utc(2026, 7, 26, 9);

    /// Builds an allocator over a scripted transport. [failFirstServer] makes
    /// the first server answer 486, [mismatchOnRefresh] makes every refresh
    /// answer 437.
    ({
      TurnRelayAllocator allocator,
      List<AllocateRequest> allocates,
      List<Duration> refreshLifetimes,
    })
    build({
      bool failFirstServer = false,
      bool mismatchOnRefresh = false,
      Duration lifetime = const Duration(seconds: 600),
      Duration refreshMargin = const Duration(seconds: 60),
    }) {
      final allocates = <AllocateRequest>[];
      final refreshLifetimes = <Duration>[];
      int relayPort = 49152;
      final allocator = TurnRelayAllocator(
        servers: _servers,
        issuer: TurnCredentialsIssuer(sharedSecret: 'turn-shared-secret'),
        userId: 'call-42',
        lifetime: lifetime,
        refreshMargin: refreshMargin,
        allocate: (request) async {
          allocates.add(request);
          if (failFirstServer &&
              request.tuple.serverAddress == _servers.first) {
            throw const AllocationQuotaReachedException();
          }
          return TurnAllocation(
            tuple: request.tuple,
            relayedAddress: HostPort(
              host: request.tuple.serverAddress.host,
              port: relayPort++,
            ),
            serverReflexiveAddress: HostPort(
              host: '203.0.113.7',
              port: request.tuple.localAddress.port,
            ),
            expiresAt: clock.now().add(request.lifetime),
            credentials: request.credentials,
          );
        },
        refresh: (allocation, refreshLifetime) async {
          refreshLifetimes.add(refreshLifetime);
          if (mismatchOnRefresh && refreshLifetime > Duration.zero) {
            throw const AllocationMismatchException();
          }
          return clock.now().add(refreshLifetime);
        },
      );
      return (
        allocator: allocator,
        allocates: allocates,
        refreshLifetimes: refreshLifetimes,
      );
    }

    test('allocates once and reuses the allocation while it is fresh', () async {
      final h = build();
      await withClock(Clock.fixed(at), () async {
        final first = await h.allocator.ensure(localAddress: _cellular);
        final second = await h.allocator.ensure(localAddress: _cellular);
        expect(second, same(first));
        expect(h.allocator.allocateCount, 1);
        expect(h.allocator.refreshCount, 0);
        expect(first.relayedAddress.port, 49152);
        expect(first.serverReflexiveAddress.host, '203.0.113.7');
        expect(first.tuple.transport, 'udp');
        // The credential carries the TURN URI for the server it was minted for.
        expect(first.credentials.uris, [
          'turn:198.51.100.1:3478?transport=udp',
        ]);
      });
    });

    test('refreshes inside the margin instead of re-allocating', () async {
      final h = build();
      final TurnAllocation first = await withClock(
        Clock.fixed(at),
        () => h.allocator.ensure(localAddress: _cellular),
      );
      // 550s in: 50s left, inside the 60s margin.
      await withClock(
        Clock.fixed(at.add(const Duration(seconds: 550))),
        () async {
          final refreshed = await h.allocator.ensure(localAddress: _cellular);
          expect(h.allocator.refreshCount, 1);
          expect(h.allocator.allocateCount, 1);
          expect(h.refreshLifetimes, [const Duration(seconds: 600)]);
          expect(refreshed.relayedAddress, first.relayedAddress);
          expect(
            refreshed.expiresAt,
            at.add(const Duration(seconds: 550 + 600)),
          );
        },
      );
    });

    test('a 437 mismatch on refresh triggers a fresh allocation', () async {
      final h = build(mismatchOnRefresh: true);
      final first = await withClock(
        Clock.fixed(at),
        () => h.allocator.ensure(localAddress: _cellular),
      );
      await withClock(
        Clock.fixed(at.add(const Duration(seconds: 550))),
        () async {
          final replaced = await h.allocator.ensure(localAddress: _cellular);
          expect(
            h.allocator.refreshCount,
            0,
            reason: 'the refresh was refused',
          );
          expect(h.allocator.allocateCount, 2);
          expect(replaced.relayedAddress, isNot(first.relayedAddress));
        },
      );
    });

    test('an expired allocation is replaced, never refreshed', () async {
      final h = build();
      await withClock(
        Clock.fixed(at),
        () => h.allocator.ensure(localAddress: _cellular),
      );
      await withClock(
        Clock.fixed(at.add(const Duration(seconds: 601))),
        () async {
          await h.allocator.ensure(localAddress: _cellular);
          expect(h.allocator.allocateCount, 2);
          expect(h.allocator.refreshCount, 0);
        },
      );
    });

    test('roaming to a new local address forces a new allocation on the same '
        '5-tuple rules', () async {
      final h = build();
      await withClock(Clock.fixed(at), () async {
        final onCellular = await h.allocator.ensure(localAddress: _cellular);
        final onWifi = await h.allocator.ensure(localAddress: _wifi);

        expect(h.allocator.roamCount, 1);
        expect(h.allocator.allocateCount, 2);
        expect(
          h.allocator.refreshCount,
          0,
          reason: 'a moved 5-tuple can never be refreshed back into use',
        );
        expect(onWifi.relayedAddress, isNot(onCellular.relayedAddress));
        expect(onWifi.tuple.localAddress, _wifi);
        expect(h.allocates.last.tuple.localAddress, _wifi);
        // The reflexive address moves with the client, which is how a caller
        // detects the NAT binding changed.
        expect(
          onWifi.serverReflexiveAddress,
          isNot(onCellular.serverReflexiveAddress),
        );
      });
    });

    test('a 486 quota error moves to the next server', () async {
      final h = build(failFirstServer: true);
      await withClock(Clock.fixed(at), () async {
        final allocation = await h.allocator.ensure(localAddress: _cellular);
        expect(allocation.tuple.serverAddress, _servers[1]);
        expect(h.allocates.length, 2);
        expect(h.allocator.allocateCount, 1);
        expect(h.allocator.currentServer, _servers[1]);
      });
    });

    test('throws once every server refuses', () async {
      int attempts = 0;
      final allocator = TurnRelayAllocator(
        servers: _servers,
        issuer: TurnCredentialsIssuer(sharedSecret: 's'),
        userId: 'call-1',
        allocate: (_) async {
          attempts++;
          throw const AllocationQuotaReachedException();
        },
        refresh: (_, __) async => clock.now(),
      );
      await expectLater(
        allocator.ensure(localAddress: _cellular),
        throwsA(isA<NoRelayAllocationException>()),
      );
      expect(attempts, _servers.length);
      expect(allocator.currentAllocation, isNull);
    });

    test('release deletes the allocation with a zero lifetime', () async {
      final h = build();
      await withClock(Clock.fixed(at), () async {
        await h.allocator.ensure(localAddress: _cellular);
        await h.allocator.release();
        expect(h.refreshLifetimes, [Duration.zero]);
        expect(h.allocator.releaseCount, 1);
        expect(h.allocator.currentAllocation, isNull);
        // Releasing again is a no-op, not an error.
        await h.allocator.release();
        expect(h.refreshLifetimes.length, 1);
      });
    });

    test('rejects an empty server list and a margin that swallows the '
        'lifetime', () {
      expect(
        () => TurnRelayAllocator(
          servers: const [],
          issuer: TurnCredentialsIssuer(sharedSecret: 's'),
          userId: 'u',
          allocate: (_) async => throw StateError('unused'),
          refresh: (_, __) async => clock.now(),
        ),
        throwsArgumentError,
      );
      expect(
        () => TurnRelayAllocator(
          servers: _servers,
          issuer: TurnCredentialsIssuer(sharedSecret: 's'),
          userId: 'u',
          lifetime: const Duration(seconds: 30),
          refreshMargin: const Duration(seconds: 30),
          allocate: (_) async => throw StateError('unused'),
          refresh: (_, __) async => clock.now(),
        ),
        throwsArgumentError,
      );
      expect(
        () => TurnRelayAllocator(
          servers: _servers,
          issuer: TurnCredentialsIssuer(sharedSecret: 's'),
          userId: '',
          allocate: (_) async => throw StateError('unused'),
          refresh: (_, __) async => clock.now(),
        ),
        throwsArgumentError,
      );
    });
  });
}
