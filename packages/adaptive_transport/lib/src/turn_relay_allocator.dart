/// Dynamic STUN/TURN relay allocation (RFC 8489 / RFC 8656).
///
/// Two jobs live here:
///
/// 1. [StunXorMappedAddress] — the RFC 8489 section 14.2 XOR-MAPPED-ADDRESS
///    attribute, encoded and decoded for real. It is how a client learns its
///    server-reflexive address, and a change in that address is the signal that
///    the NAT binding moved (cellular to Wi-Fi roaming, or a NAT rebind).
///
/// 2. [TurnRelayAllocator] — the RFC 8656 allocation lifecycle: allocate,
///    refresh before expiry, re-allocate when the 5-tuple changes, and delete
///    with a zero lifetime. Network I/O is injected, so the lifecycle rules are
///    testable without a live TURN server.
library;

import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:security/security.dart';

import 'host_port.dart';

/// STUN fixed magic cookie (RFC 8489 section 5).
const int stunMagicCookie = 0x2112A442;

/// Address families used by STUN address attributes (RFC 8489 section 14.1).
const int stunFamilyIpv4 = 0x01;
const int stunFamilyIpv6 = 0x02;

/// The XOR-MAPPED-ADDRESS attribute value (RFC 8489 section 14.2).
///
/// The port is XOR-ed with the top 16 bits of the magic cookie and the address
/// with the cookie followed by the 96-bit transaction id. The XOR exists so
/// middleboxes that rewrite addresses inside packet payloads do not silently
/// corrupt the very address the client is trying to discover.
class StunXorMappedAddress {
  const StunXorMappedAddress({required this.family, required this.address, required this.port});

  final int family;

  /// Address bytes in network order: 4 for IPv4, 16 for IPv6.
  final Uint8List address;

  final int port;

  static const int _cookieHigh = (stunMagicCookie >> 16) & 0xFFFF;

  /// Encodes the attribute value. [transactionId] must be the 12-byte STUN
  /// transaction id of the enclosing message (RFC 8489 section 5).
  Uint8List encode(Uint8List transactionId) {
    _validate(transactionId);
    final out = Uint8List(4 + address.length);
    out[0] = 0x00; // Reserved, must be 0.
    out[1] = family;
    final xorPort = port ^ _cookieHigh;
    out[2] = (xorPort >> 8) & 0xFF;
    out[3] = xorPort & 0xFF;
    final mask = _mask(transactionId, address.length);
    for (int i = 0; i < address.length; i++) {
      out[4 + i] = address[i] ^ mask[i];
    }
    return out;
  }

  static StunXorMappedAddress decode(
    Uint8List attributeValue,
    Uint8List transactionId,
  ) {
    if (attributeValue.length < 4) {
      throw FormatException(
        'XOR-MAPPED-ADDRESS shorter than 4 bytes: ${attributeValue.length}',
      );
    }
    final family = attributeValue[1];
    final expectedLength = family == stunFamilyIpv4
        ? 4
        : family == stunFamilyIpv6
            ? 16
            : throw FormatException('Unknown STUN address family: $family');
    if (attributeValue.length != 4 + expectedLength) {
      throw FormatException(
        'Family $family needs ${4 + expectedLength} bytes, '
        'got ${attributeValue.length}',
      );
    }
    final port =
        ((attributeValue[2] << 8) | attributeValue[3]) ^ _cookieHigh;
    final mask = _mask(transactionId, expectedLength);
    final address = Uint8List(expectedLength);
    for (int i = 0; i < expectedLength; i++) {
      address[i] = attributeValue[4 + i] ^ mask[i];
    }
    return StunXorMappedAddress(family: family, address: address, port: port);
  }

  /// Dotted-quad for IPv4, colon-hex for IPv6.
  String get addressText {
    if (family == stunFamilyIpv4) return address.join('.');
    final groups = <String>[];
    for (int i = 0; i < address.length; i += 2) {
      groups.add(
        ((address[i] << 8) | address[i + 1]).toRadixString(16),
      );
    }
    return groups.join(':');
  }

  HostPort get hostPort => HostPort(host: addressText, port: port);

  void _validate(Uint8List transactionId) {
    if (transactionId.length != 12) {
      throw ArgumentError.value(
        transactionId.length,
        'transactionId',
        'STUN transaction id is exactly 12 bytes',
      );
    }
    final int expected = family == stunFamilyIpv4
        ? 4
        : family == stunFamilyIpv6
            ? 16
            : throw ArgumentError.value(family, 'family', 'unknown family');
    if (address.length != expected) {
      throw ArgumentError.value(
        address.length,
        'address',
        'family $family requires $expected address bytes',
      );
    }
    if (port < 0 || port > 0xFFFF) {
      throw ArgumentError.value(port, 'port', 'must fit in 16 bits');
    }
  }

  /// Cookie followed by the transaction id, truncated to the address length.
  static Uint8List _mask(Uint8List transactionId, int length) {
    final mask = Uint8List(16);
    mask[0] = (stunMagicCookie >> 24) & 0xFF;
    mask[1] = (stunMagicCookie >> 16) & 0xFF;
    mask[2] = (stunMagicCookie >> 8) & 0xFF;
    mask[3] = stunMagicCookie & 0xFF;
    mask.setRange(4, 16, transactionId);
    return Uint8List.sublistView(mask, 0, length);
  }
}

/// The client-side half of a TURN allocation's 5-tuple (RFC 8656 section 2.2).
///
/// An allocation belongs to exactly one 5-tuple. When the client's address
/// changes — the roaming case — the old allocation is unusable and a fresh
/// Allocate is the only correct move, not a refresh.
class RelayFiveTuple {
  const RelayFiveTuple({
    required this.localAddress,
    required this.serverAddress,
    this.transport = 'udp',
  });

  final HostPort localAddress;
  final HostPort serverAddress;
  final String transport;

  @override
  bool operator ==(Object other) =>
      other is RelayFiveTuple &&
      other.localAddress == localAddress &&
      other.serverAddress == serverAddress &&
      other.transport == transport;

  @override
  int get hashCode => Object.hash(localAddress, serverAddress, transport);

  @override
  String toString() => '$localAddress -> $serverAddress/$transport';
}

/// A live TURN allocation.
class TurnAllocation {
  const TurnAllocation({
    required this.tuple,
    required this.relayedAddress,
    required this.serverReflexiveAddress,
    required this.expiresAt,
    required this.credentials,
  });

  final RelayFiveTuple tuple;

  /// RELAYED-TRANSPORT-ADDRESS: where peers send traffic for this client.
  final HostPort relayedAddress;

  /// XOR-MAPPED-ADDRESS as seen by the server: the client's NAT binding.
  final HostPort serverReflexiveAddress;

  final DateTime expiresAt;
  final TurnCredentials credentials;

  Duration remainingAt(DateTime now) => expiresAt.difference(now);

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  TurnAllocation withExpiry(DateTime expiresAt) => TurnAllocation(
        tuple: tuple,
        relayedAddress: relayedAddress,
        serverReflexiveAddress: serverReflexiveAddress,
        expiresAt: expiresAt,
        credentials: credentials,
      );
}

/// What the allocator asks the injected transport to do.
class AllocateRequest {
  const AllocateRequest({
    required this.tuple,
    required this.credentials,
    required this.lifetime,
  });

  final RelayFiveTuple tuple;
  final TurnCredentials credentials;
  final Duration lifetime;
}

/// RFC 8656 section 7.2 error 437: the server has no allocation for this
/// 5-tuple, so the client must allocate again rather than keep refreshing.
class AllocationMismatchException implements Exception {
  const AllocationMismatchException();
  @override
  String toString() => 'AllocationMismatchException(437)';
}

/// RFC 8656 section 7.2 error 486: this server is full. Another server may
/// still have room, so the allocator moves on instead of retrying here.
class AllocationQuotaReachedException implements Exception {
  const AllocationQuotaReachedException();
  @override
  String toString() => 'AllocationQuotaReachedException(486)';
}

/// Raised when no configured TURN server would grant an allocation.
class NoRelayAllocationException implements Exception {
  NoRelayAllocationException(this.serversTried, this.lastError);

  final int serversTried;
  final Object? lastError;

  @override
  String toString() => 'NoRelayAllocationException: tried $serversTried '
      'server(s), last error: $lastError';
}

/// Keeps exactly one usable TURN allocation alive across expiry and roaming.
///
/// The rules it enforces, all from RFC 8656:
/// - an allocation is bound to its 5-tuple, so a changed local address forces a
///   new Allocate rather than a Refresh (section 2.2);
/// - refresh happens [refreshMargin] before expiry, not after it (section 3.2);
/// - a 437 Allocation Mismatch on refresh means re-allocate (section 7.2);
/// - a 486 Allocation Quota Reached means try the next server (section 7.2);
/// - release is a Refresh with lifetime 0 (section 7).
class TurnRelayAllocator {
  TurnRelayAllocator({
    required List<HostPort> servers,
    required TurnCredentialsIssuer issuer,
    required Future<TurnAllocation> Function(AllocateRequest request) allocate,
    required Future<DateTime> Function(
      TurnAllocation allocation,
      Duration lifetime,
    ) refresh,
    required this.userId,
    this.lifetime = const Duration(seconds: 600),
    this.refreshMargin = const Duration(seconds: 60),
    this.transport = 'udp',
  })  : _servers = List<HostPort>.unmodifiable(servers),
        _issuer = issuer,
        _allocate = allocate,
        _refresh = refresh {
    if (_servers.isEmpty) {
      throw ArgumentError.value(servers, 'servers', 'must not be empty');
    }
    if (lifetime <= refreshMargin) {
      throw ArgumentError(
        'lifetime ($lifetime) must be longer than refreshMargin '
        '($refreshMargin), otherwise every allocation is born due for refresh',
      );
    }
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'must not be empty');
    }
  }

  final List<HostPort> _servers;
  final TurnCredentialsIssuer _issuer;
  final Future<TurnAllocation> Function(AllocateRequest) _allocate;
  final Future<DateTime> Function(TurnAllocation, Duration) _refresh;

  /// Default RFC 8656 section 3.2 allocation lifetime is 600 seconds.
  final Duration lifetime;

  /// How long before expiry a refresh is sent.
  final Duration refreshMargin;

  final String userId;
  final String transport;

  int _serverCursor = 0;
  TurnAllocation? _current;

  int allocateCount = 0;
  int refreshCount = 0;
  int releaseCount = 0;

  /// Number of times a local-address change forced a new allocation.
  int roamCount = 0;

  TurnAllocation? get currentAllocation => _current;

  /// The server the next Allocate will be sent to.
  HostPort get currentServer => _servers[_serverCursor];

  /// Returns a usable allocation for [localAddress], creating, refreshing or
  /// replacing the current one as the RFC requires.
  Future<TurnAllocation> ensure({required HostPort localAddress}) async {
    final now = clock.now();
    final existing = _current;

    if (existing != null) {
      if (existing.tuple.localAddress != localAddress) {
        // Roaming: the 5-tuple moved, so this allocation can never be
        // refreshed back into usefulness. Drop it and allocate afresh.
        roamCount++;
        _current = null;
      } else if (existing.isExpiredAt(now)) {
        _current = null;
      } else if (existing.remainingAt(now) <= refreshMargin) {
        try {
          final expiresAt = await _refresh(existing, lifetime);
          refreshCount++;
          final refreshed = existing.withExpiry(expiresAt);
          _current = refreshed;
          return refreshed;
        } on AllocationMismatchException {
          _current = null; // 437: fall through to a fresh Allocate.
        }
      } else {
        return existing;
      }
    }

    return _allocateAcrossServers(localAddress);
  }

  Future<TurnAllocation> _allocateAcrossServers(HostPort localAddress) async {
    Object? lastError;
    for (int i = 0; i < _servers.length; i++) {
      final server = _servers[_serverCursor];
      final request = AllocateRequest(
        tuple: RelayFiveTuple(
          localAddress: localAddress,
          serverAddress: server,
          transport: transport,
        ),
        credentials: _issuer.issue(
          userId,
          uris: ['turn:${server.authority}?transport=$transport'],
        ),
        lifetime: lifetime,
      );
      try {
        final allocation = await _allocate(request);
        allocateCount++;
        _current = allocation;
        return allocation;
      } on AllocationQuotaReachedException catch (error) {
        lastError = error;
        _nextServer();
      } catch (error) {
        lastError = error;
        _nextServer();
      }
    }
    throw NoRelayAllocationException(_servers.length, lastError);
  }

  /// Deletes the current allocation with a zero-lifetime Refresh (RFC 8656
  /// section 7). Safe to call with nothing allocated.
  Future<void> release() async {
    final existing = _current;
    if (existing == null) return;
    _current = null;
    try {
      await _refresh(existing, Duration.zero);
      releaseCount++;
    } on AllocationMismatchException {
      // The server already forgot this allocation; nothing left to delete.
      releaseCount++;
    }
  }

  void _nextServer() {
    _serverCursor = (_serverCursor + 1) % _servers.length;
  }
}
