import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:signaling_server/src/datagram_relay.dart';
import 'package:test/test.dart';

/// tag-v2 unit tests — phase 5 peak 5 prerequisite (plan appendix A).
/// Proves: hello assigns a stable 2-byte tag; tagged datagrams forward to the
/// other seat verbatim; and every v1 length keeps its exact old behavior.
/// RawDatagramSocket streams are single-subscription; each socket gets ONE
/// listener that feeds a queue, and tests await datagrams from the queue.
final class _Inbox {
  _Inbox(this.socket) {
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        final bytes = Uint8List.fromList(d.data);
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(bytes);
        } else {
          _buffer.add(bytes);
        }
      }
    });
  }

  final RawDatagramSocket socket;
  final List<Uint8List> _buffer = [];
  final List<Completer<Uint8List>> _waiters = [];

  Future<Uint8List> next() {
    if (_buffer.isNotEmpty) {
      return Future.value(_buffer.removeAt(0));
    }
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }
}

void main() {
  late DatagramRelay relay;
  late _Inbox a;
  late _Inbox b;
  final key = List<int>.generate(16, (i) => 0x41 + i); // 16B room key

  setUp(() async {
    relay = await DatagramRelay.bind(0, address: InternetAddress.loopbackIPv4);
    a = _Inbox(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    b = _Inbox(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
  });

  tearDown(() async {
    a.socket.close();
    b.socket.close();
    await relay.close();
  });

  void sendToRelay(_Inbox s, List<int> bytes) {
    s.socket.send(bytes, InternetAddress.loopbackIPv4, relay.port);
  }

  Future<Uint8List> nextDatagram(_Inbox s) => s.next();

  Future<int> hello(_Inbox s) async {
    sendToRelay(s, [...key, 0xC2, 0x02]);
    final r = await s.next();
    expect(r.length, 4);
    expect(r[0], 0xC2);
    expect(r[1], 0x02);
    return (r[2] << 8) | r[3];
  }

  test('v2 hello assigns a tag and repeating it returns the same tag',
      () async {
    final t1 = await hello(a);
    final t2 = await hello(a);
    expect(t1, isNot(0));
    expect(t2, t1);
  });

  test('tagged datagram forwards verbatim to the other seat', () async {
    final tagA = await hello(a);
    await hello(b);
    final got = nextDatagram(b);
    final payload = [tagA >> 8, tagA & 0xFF, 1, 2, 3, 4, 5];
    sendToRelay(a, payload);
    expect(await got, payload);
  });

  test('two seats get distinct tags and both directions forward', () async {
    final tagA = await hello(a);
    final tagB = await hello(b);
    expect(tagA, isNot(tagB));
    final gotB = nextDatagram(b);
    sendToRelay(a, [tagA >> 8, tagA & 0xFF, 9]);
    expect((await gotB).sublist(2), [9]);
    final gotA = nextDatagram(a);
    sendToRelay(b, [tagB >> 8, tagB & 0xFF, 7]);
    expect((await gotA).sublist(2), [7]);
  });

  test('v1 behavior unchanged: short packet still echoes, even one that '
      'looks like an unassigned tag', () async {
    final echo = nextDatagram(a);
    sendToRelay(a, [0x12, 0x34, 0x56]); // no such tag -> v1 liveness echo
    expect(await echo, [0x12, 0x34, 0x56]);
  });

  test('v1 behavior unchanged: 16B registration + long data forward', () async {
    sendToRelay(a, key); // v1 registration
    sendToRelay(b, key);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final got = nextDatagram(b);
    final data = [...key, 0xDE, 0xAD, 0xBE, 0xEF];
    sendToRelay(a, data);
    expect(await got, data);
  });

  test('v1 17-byte data packet (1B payload) still forwards, never mistaken '
      'for a hello', () async {
    sendToRelay(a, key);
    sendToRelay(b, key);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final got = nextDatagram(b);
    sendToRelay(a, [...key, 0x99]);
    expect(await got, [...key, 0x99]);
  });
}
