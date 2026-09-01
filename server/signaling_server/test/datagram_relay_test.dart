/// Unit gates for the fountain lane's datagram relay (RIG_GUIDE §0.3 step 4a).
/// In-process, port 0, real sockets on loopback — no process management.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

Uint8List key16(int fill) => Uint8List(16)..fillRange(0, 16, fill);

Uint8List frame(Uint8List key, List<int> payload) =>
    Uint8List.fromList([...key, ...payload]);

Future<RawDatagramSocket> client() =>
    RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

/// Collects inbound datagrams of [socket] for assertions.
List<Uint8List> collect(RawDatagramSocket socket) {
  final seen = <Uint8List>[];
  socket.writeEventsEnabled = false;
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      seen.add(Uint8List.fromList(d.data));
    }
  });
  return seen;
}

Future<void> settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late DatagramRelay relay;
  late InternetAddress host;

  setUp(() async {
    relay = await DatagramRelay.bind(0, address: InternetAddress.loopbackIPv4);
    host = InternetAddress.loopbackIPv4;
  });

  tearDown(() => relay.close());

  test('liveness echo: a sub-key-length datagram bounces back verbatim '
      '(the harness rig-health probe)', () async {
    final probe = await client();
    final seen = collect(probe);
    probe.send([0x42], host, relay.port);
    await settle();
    expect(seen, [
      [0x42],
    ]);
    probe.close();
  });

  test('two registered seats forward data frames to each other, never '
      'echo to the sender', () async {
    final a = await client();
    final b = await client();
    final seenA = collect(a);
    final seenB = collect(b);
    final key = key16(7);
    a.send(key, host, relay.port); // registration only
    b.send(key, host, relay.port);
    await settle();
    a.send(frame(key, [1, 2, 3]), host, relay.port);
    b.send(frame(key, [9]), host, relay.port);
    await settle();
    expect(seenB, [
      frame(key, [1, 2, 3]),
    ]);
    expect(seenA, [
      frame(key, [9]),
    ]);
    a.close();
    b.close();
  });

  test('a data frame registers its own source (learn on every datagram, '
      'not only bare keys)', () async {
    final a = await client();
    final b = await client();
    final seenA = collect(a);
    final key = key16(3);
    // b never sends a bare registration — its first frame is data.
    b.send(frame(key, [5, 5]), host, relay.port); // no seats yet: dropped
    a.send(key, host, relay.port);
    await settle();
    b.send(frame(key, [6]), host, relay.port); // b re-learns, a is other
    await settle();
    expect(seenA, [
      frame(key, [6]),
    ]);
    a.close();
    b.close();
  });

  test('rooms are independent per key and frames keep the key prefix '
      'verbatim on forward', () async {
    final a1 = await client();
    final b1 = await client();
    final a2 = await client();
    final b2 = await client();
    final seenB1 = collect(b1);
    final seenB2 = collect(b2);
    final k1 = key16(1);
    final k2 = key16(2);
    b1.send(k1, host, relay.port);
    b2.send(k2, host, relay.port);
    a1.send(frame(k1, [11]), host, relay.port);
    a2.send(frame(k2, [22]), host, relay.port);
    await settle();
    expect(seenB1, [
      frame(k1, [11]),
    ]);
    expect(seenB2, [
      frame(k2, [22]),
    ]);
    for (final s in [a1, b1, a2, b2]) {
      s.close();
    }
  });

  test('a third distinct source replaces the least-recently-seen seat '
      '(zombie eviction, live seat survives)', () async {
    final zombie = await client();
    final live = await client();
    final fresh = await client();
    final seenLive = collect(live);
    final seenFresh = collect(fresh);
    final key = key16(9);
    zombie.send(key, host, relay.port);
    await settle(30);
    live.send(key, host, relay.port); // live is now the newest seat
    await settle(30);
    // Fresh claims a seat; the zombie (older lastSeen) must be evicted.
    fresh.send(frame(key, [77]), host, relay.port);
    await settle();
    expect(seenLive, [
      frame(key, [77]),
    ]);
    fresh.send(frame(key, [78]), host, relay.port);
    live.send(frame(key, [79]), host, relay.port);
    await settle();
    expect(seenLive, [
      frame(key, [77]),
      frame(key, [78]),
    ]);
    expect(seenFresh, [
      frame(key, [79]),
    ]);
    zombie.close();
    live.close();
    fresh.close();
  });
}
