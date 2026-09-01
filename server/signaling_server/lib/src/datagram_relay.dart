/// Dumb datagram relay for the fountain video lane — RIG_GUIDE §0.3 step 1.
///
/// WHY (measured 2026-08-10, two official loss60 shots): SCTP clocks the
/// whole association down to ~2 packets/s under 60% bidirectional loss even
/// with maxRetransmits:0 — the transport's own recovery machinery, not the
/// sender, was the ceiling. The rateless lane therefore needs a path with
/// no loss-reactive control underneath. This relay is that path's rig-side
/// half: a UDP mirror of the TURN role for media, so every packet crosses
/// the shaped bridge twice (phone -> Mac -> phone), the same physics as
/// force-relay media. Shaping needs no new rules: the rig's default
/// per-peer branch impairs all UDP except mDNS in both directions
/// (net_shape.sh:363-364), and h2_run's UDP evidence filter counts this
/// port automatically.
///
/// PROTOCOL (deliberately dumb — the lane above is the only intelligence):
/// - Every datagram of >= 16 bytes: the first 16 bytes are an opaque room
///   key; the source addr:port is learned/refreshed as a seat of that room
///   on EVERY such datagram (not only registrations — a data frame from a
///   just-evicted or never-registered seat must still heal the room).
/// - Exactly 16 bytes = registration/keepalive only: learn, forward nothing.
/// - Longer = forward verbatim to the room's OTHER seat when one is known.
///   No acks, no buffering, no retransmission, no ordering — loss here is
///   exactly the loss the lane is designed for.
/// - 1..15 bytes = liveness echo: sent straight back to the sender. The
///   harness probes this before trusting the rig (the port-collision class:
///   a foreign socket bound on our port would swallow traffic silently —
///   coturn itself binds listening-port+1 as its alt-port, which is why the
///   default here is 3737, far from 3478/3479 and coturn's relay range).
/// - A third distinct source replaces the least-recently-SEEN seat (the
///   signaling relay's seat lesson: a live seat refreshes itself constantly,
///   so the stale one is the zombie).
/// - Rooms idle for 10 minutes are dropped (memory guard; a room is two
///   addresses, so eviction can never strand decode state).
/// TAG-V2 (phase 5 peak 5, appendix A — second version of the SAME format):
/// the 16B room key in every datagram dominates the PTT wire budget, so a
/// v2-aware seat registers once and then sends a 2-byte tag instead:
/// - v2 hello: 16B key + trailer [0xC2, 0x02] (18 bytes total). Reply to the
///   sender only: [0xC2, 0x02, tagHi, tagLo]. The seat is learned exactly like
///   a v1 registration.
/// - tagged data (v2 seats only): [tagHi, tagLo] + payload, any length >= 3.
///   Forwarded VERBATIM to the room's other seat (the receiver strips 2B).
/// - Backward compatibility: a seat that never sent a v2 hello keeps exact v1
///   semantics for every length. Reserved collision, documented: an 18-byte
///   v1 data packet whose payload is exactly [0xC2, 0x02] would be read as a
///   hello — the fountain lane never emits 2-byte payloads, and v2 clients
///   must not send liveness probes that start with their own tag.
library;

import 'dart:async';
import 'dart:io';

const int _keyBytes = 16;
const Duration _roomIdle = Duration(minutes: 10);
const int _v2Magic0 = 0xC2;
const int _v2Magic1 = 0x02;
const int _tagBytes = 2;

final class _Seat {
  _Seat(this.address, this.port) : lastSeen = DateTime.now();
  final InternetAddress address;
  final int port;
  DateTime lastSeen;

  /// Non-null once this seat completed a v2 hello; the u16 tag it sends
  /// before every payload instead of the 16B room key.
  int? tag;

  bool matches(Datagram d) => d.port == port && d.address == address;
}

final class _Room {
  _Seat? a;
  _Seat? b;
  DateTime lastSeen = DateTime.now();

  /// Learns/refreshes the seat for this source and returns it.
  _Seat touch(Datagram d) {
    lastSeen = DateTime.now();
    final seatA = a;
    final seatB = b;
    if (seatA != null && seatA.matches(d)) {
      return seatA..lastSeen = lastSeen;
    }
    if (seatB != null && seatB.matches(d)) {
      return seatB..lastSeen = lastSeen;
    }
    final fresh = _Seat(d.address, d.port);
    if (seatA == null) {
      a = fresh;
    } else if (seatB == null) {
      b = fresh;
    } else if (seatA.lastSeen.isBefore(seatB.lastSeen)) {
      a = fresh;
    } else {
      b = fresh;
    }
    return fresh;
  }

  _Seat? other(_Seat seat) => identical(seat, a) ? b : a;
}

/// Bindable, closable relay core — the bin entrypoint is a thin wrapper so
/// tests exercise this class in-process on port 0.
final class DatagramRelay {
  DatagramRelay._(this._socket) {
    _gc = Timer.periodic(const Duration(minutes: 1), (_) {
      final cutoff = DateTime.now().subtract(_roomIdle);
      _rooms.removeWhere((_, room) => room.lastSeen.isBefore(cutoff));
    });
    _socket.writeEventsEnabled = false;
    _sub = _socket.listen(_onEvent);
  }

  /// reuseAddress deliberately OFF: a stale relay (or a foreign daemon)
  /// already bound here must fail THIS bind loudly, not split the traffic.
  static Future<DatagramRelay> bind(
    int port, {
    InternetAddress? address,
  }) async {
    final socket = await RawDatagramSocket.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      reuseAddress: false,
    );
    return DatagramRelay._(socket);
  }

  final RawDatagramSocket _socket;
  final Map<String, _Room> _rooms = {};

  /// tag -> (room, seat) for the v2 fast path; tags are unique relay-wide so
  /// a tagged datagram resolves without knowing its room key.
  final Map<int, (_Room, _Seat)> _tags = {};
  int _nextTag = 0;
  late final StreamSubscription<RawSocketEvent> _sub;
  late final Timer _gc;

  int get port => _socket.port;

  int _allocateTag() {
    // u16 space, skip 0; wraps and skips live tags.
    do {
      _nextTag = (_nextTag + 1) & 0xFFFF;
    } while (_nextTag == 0 || _tags.containsKey(_nextTag));
    return _nextTag;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    // Drain fully: one read event may cover several queued datagrams.
    for (var d = _socket.receive(); d != null; d = _socket.receive()) {
      final data = d.data;
      if (data.isEmpty) continue;

      // v2 tagged data: a known tag arriving from its registered seat.
      if (data.length > _tagBytes) {
        final entry = _tags[(data[0] << 8) | data[1]];
        if (entry != null && entry.$2.matches(d)) {
          final (room, seat) = entry;
          room.lastSeen = seat.lastSeen = DateTime.now();
          final peer = room.other(seat);
          if (peer != null) _socket.send(data, peer.address, peer.port);
          continue;
        }
      }

      if (data.length < _keyBytes) {
        _socket.send(data, d.address, d.port); // liveness echo
        continue;
      }

      // v2 hello: 16B key + magic trailer -> learn seat, assign + reply tag.
      if (data.length == _keyBytes + 2 &&
          data[_keyBytes] == _v2Magic0 &&
          data[_keyBytes + 1] == _v2Magic1) {
        final key = String.fromCharCodes(data, 0, _keyBytes);
        final room = _rooms.putIfAbsent(key, _Room.new);
        final seat = room.touch(d);
        final tag = seat.tag ??= _allocateTag();
        _tags[tag] = (room, seat);
        _socket.send(
          [_v2Magic0, _v2Magic1, tag >> 8, tag & 0xFF],
          d.address,
          d.port,
        );
        continue;
      }

      final key = String.fromCharCodes(data, 0, _keyBytes);
      final room = _rooms.putIfAbsent(key, _Room.new);
      final seat = room.touch(d);
      if (data.length == _keyBytes) continue; // registration/keepalive
      final peer = room.other(seat);
      if (peer == null) continue; // no second seat yet — the lane retries
      _socket.send(data, peer.address, peer.port);
    }
  }

  Future<void> close() async {
    _gc.cancel();
    await _sub.cancel();
    _socket.close();
  }
}
