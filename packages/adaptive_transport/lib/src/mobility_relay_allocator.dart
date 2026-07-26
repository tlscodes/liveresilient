import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:security/security.dart';

import 'host_port.dart';
import 'turn_relay_allocator.dart';

class _TicketBox {
  Uint8List? ticket;
}

/// [TurnRelayAllocator] plus TURN mobility (RFC 8016).
///
/// A mobility-capable server hands back a MOBILITY-TICKET at Allocate time.
/// When the client roams (cellular to Wi-Fi), presenting that ticket on a
/// Refresh FROM THE NEW ADDRESS keeps the same relayed address — peers keep
/// sending to the address they already know, and the media path survives the
/// network switch with one round trip instead of a full re-allocate plus
/// re-signaling.
///
/// Falls back to the base full re-allocate whenever there is no ticket, the
/// server refuses it (437), or the allocation already expired.
class MobilityRelayAllocator extends TurnRelayAllocator {
  factory MobilityRelayAllocator({
    required List<HostPort> servers,
    required TurnCredentialsIssuer issuer,
    required Future<(TurnAllocation, Uint8List?)> Function(
      AllocateRequest request,
    ) allocateWithTicket,
    required Future<DateTime> Function(
      TurnAllocation allocation,
      Duration lifetime,
    ) refresh,
    required Future<(TurnAllocation, Uint8List?)> Function(
      TurnAllocation allocation,
      Uint8List ticket,
      HostPort newLocalAddress,
    ) mobilityRefresh,
    required String userId,
    Duration lifetime = const Duration(seconds: 600),
    Duration refreshMargin = const Duration(seconds: 60),
    String transport = 'udp',
  }) {
    final box = _TicketBox();
    return MobilityRelayAllocator._(
      servers: servers,
      issuer: issuer,
      allocate: (request) async {
        final (allocation, ticket) = await allocateWithTicket(request);
        box.ticket = ticket;
        return allocation;
      },
      refresh: refresh,
      mobilityRefresh: mobilityRefresh,
      box: box,
      userId: userId,
      lifetime: lifetime,
      refreshMargin: refreshMargin,
      transport: transport,
    );
  }

  MobilityRelayAllocator._({
    required super.servers,
    required super.issuer,
    required super.allocate,
    required Future<DateTime> Function(TurnAllocation, Duration) refresh,
    required Future<(TurnAllocation, Uint8List?)> Function(
      TurnAllocation,
      Uint8List,
      HostPort,
    ) mobilityRefresh,
    required _TicketBox box,
    required super.userId,
    required Duration super.lifetime,
    required Duration super.refreshMargin,
    required String super.transport,
  })  : _refreshFn = refresh,
        _mobility = mobilityRefresh,
        _box = box,
        super(refresh: refresh);

  final Future<DateTime> Function(TurnAllocation, Duration) _refreshFn;
  final Future<(TurnAllocation, Uint8List?)> Function(
    TurnAllocation,
    Uint8List,
    HostPort,
  ) _mobility;
  final _TicketBox _box;

  /// The allocation as moved by mobility refreshes. While set, it supersedes
  /// the base class's record (which still names the pre-roam 5-tuple).
  TurnAllocation? _shadow;

  /// Roams kept alive by a ticket — same relayed address, one round trip.
  int mobilityRoamCount = 0;

  bool get hasMobilityTicket => _box.ticket != null;

  @override
  TurnAllocation? get currentAllocation => _shadow ?? super.currentAllocation;

  @override
  Future<TurnAllocation> ensure({required HostPort localAddress}) async {
    final now = clock.now();
    final shadow = _shadow;
    if (shadow != null) {
      if (shadow.tuple.localAddress != localAddress) {
        return _roam(shadow, localAddress, now);
      }
      if (shadow.isExpiredAt(now)) {
        _dropShadow();
      } else if (shadow.remainingAt(now) <= refreshMargin) {
        try {
          final expiresAt = await _refreshFn(shadow, lifetime);
          refreshCount++;
          final refreshed = shadow.withExpiry(expiresAt);
          _shadow = refreshed;
          return refreshed;
        } on AllocationMismatchException {
          _dropShadow();
        }
      } else {
        return shadow;
      }
      return super.ensure(localAddress: localAddress);
    }
    final existing = super.currentAllocation;
    if (existing != null && existing.tuple.localAddress != localAddress) {
      return _roam(existing, localAddress, now);
    }
    return super.ensure(localAddress: localAddress);
  }

  Future<TurnAllocation> _roam(
    TurnAllocation from,
    HostPort localAddress,
    DateTime now,
  ) async {
    final ticket = _box.ticket;
    if (ticket != null && !from.isExpiredAt(now)) {
      try {
        final (moved, newTicket) = await _mobility(from, ticket, localAddress);
        mobilityRoamCount++;
        _box.ticket = newTicket ?? ticket;
        _shadow = moved;
        return moved;
      } on AllocationMismatchException {
        _box.ticket = null; // Ticket refused: never present it again.
      }
    }
    _shadow = null;
    return super.ensure(localAddress: localAddress);
  }

  @override
  Future<void> release() async {
    final shadow = _shadow;
    if (shadow != null) {
      _dropShadow();
      try {
        await _refreshFn(shadow, Duration.zero);
        releaseCount++;
      } on AllocationMismatchException {
        releaseCount++;
      }
    }
    // Clears the base record too; its stale pre-roam tuple answers with a 437
    // the base class already tolerates.
    return super.release();
  }

  void _dropShadow() {
    _shadow = null;
    _box.ticket = null;
  }
}
