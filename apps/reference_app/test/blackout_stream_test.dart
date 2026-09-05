/// The blackout v3 stream lane against a fake hub: the hello, the header
/// and raw-byte framing, resume from the hub's offset, the inflight cap,
/// pipelining, done ordering, stall, error and close handling, and the v3
/// plan parsing.
///
/// Every case runs under fakeAsync. The fake link is two stream
/// controllers: phone→hub (sync, parsed by [_HubSide] on the spot) and
/// hub→phone (the lane's inbound). The lane never awaits the inbound
/// subscription's cancel future, so destroy() does not escape the fake
/// zone and no case needs a real event loop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:device_link/device_link.dart'
    show DtnBundle, LinkMessagePriority;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/blackout_forwarder.dart';
import '../integration_test/blackout_stream.dart';

/// Parses what the phone writes: one hello line, then per record a header
/// line followed by exactly `len` raw bytes.
class _HubSide {
  final List<int> _buf = <int>[];
  Map<String, Object?>? hello;
  final List<Map<String, Object?>> headers = <Map<String, Object?>>[];
  final Map<String, List<int>> bodies = <String, List<int>>{};
  int rawBytes = 0;
  String? _openId;
  int _remaining = 0;

  void feed(List<int> chunk) {
    _buf.addAll(chunk);
    while (_buf.isNotEmpty) {
      if (_remaining > 0) {
        final n = min(_remaining, _buf.length);
        bodies[_openId!]!.addAll(_buf.sublist(0, n));
        _buf.removeRange(0, n);
        _remaining -= n;
        rawBytes += n;
        continue;
      }
      final nl = _buf.indexOf(0x0a);
      if (nl < 0) return;
      final line =
          jsonDecode(utf8.decode(_buf.sublist(0, nl))) as Map<String, Object?>;
      _buf.removeRange(0, nl + 1);
      if (hello == null) {
        hello = line;
      } else {
        headers.add(line);
        _openId = line['id'] as String;
        _remaining = line['len'] as int;
        bodies.putIfAbsent(_openId!, () => <int>[]);
      }
    }
  }
}

class _FakeLink implements StreamLink {
  _FakeLink() {
    _toHub.stream.listen(hub.feed);
  }

  final _HubSide hub = _HubSide();
  final StreamController<List<int>> _toHub = StreamController<List<int>>(
    sync: true,
  );
  final StreamController<List<int>> _fromHub = StreamController<List<int>>();
  bool destroyed = false;
  int destroyCalls = 0;

  @override
  void write(List<int> bytes) {
    if (destroyed) throw StateError('write after destroy');
    _toHub.add(bytes);
  }

  @override
  Stream<List<int>> get inbound => _fromHub.stream;

  @override
  Future<void> destroy() {
    destroyed = true;
    destroyCalls++;
    if (!_fromHub.isClosed) _fromHub.close();
    return Future<void>.value();
  }

  /// A hub line; after destroy() it goes nowhere, as on a closed socket.
  void send(Map<String, Object?> line) {
    if (_fromHub.isClosed) return;
    _fromHub.add(utf8.encode('${jsonEncode(line)}\n'));
  }

  /// Splits one line across two chunks to check the phone's line buffer.
  void sendSplit(Map<String, Object?> line) {
    final bytes = utf8.encode('${jsonEncode(line)}\n');
    _fromHub.add(bytes.sublist(0, 5));
    _fromHub.add(bytes.sublist(5));
  }

  void closeFromHub() => _fromHub.close();
}

Map<String, Object?> _stateLine({
  Map<String, Object?> state = const {},
  int pieceBytes = 8192,
  int inflightBytes = 32768,
  int stallS = 15,
}) => {
  'state': state,
  'piece_bytes': pieceBytes,
  'ack_bytes': 8192,
  'ack_interval_s': 2,
  'inflight_bytes': inflightBytes,
  'stall_s': stallS,
};

final List<int> _sig = List<int>.generate(64, (i) => (i * 7) & 0xff);

List<int> _payload(int bytes, int seed) {
  final random = Random(seed);
  return List<int>.generate(bytes, (_) => random.nextInt(256));
}

DtnBundle _bundle(String id, List<int> payload, {int createdMs = 1000}) =>
    DtnBundle(
      id: id,
      payload: buildBlackoutEnvelope(
        run: 'r1',
        id: id,
        createdMs: createdMs,
        payload: payload,
        signature: _sig,
        pubkeyB64: 'PK',
      ),
      priority: LinkMessagePriority.bulk,
      createdAtMs: createdMs,
      lifetimeMs: 3600 * 1000,
    );

class _Session {
  _Session(this.link, this.lane);

  final _FakeLink link;
  final BlackoutStreamLane lane;
  final List<String> dones = <String>[];
  StreamOutcome? outcome;

  _HubSide get hub => link.hub;
}

_Session _start(FakeAsync fa, List<DtnBundle> pending) {
  final link = _FakeLink();
  final lane = BlackoutStreamLane(port: 8766);
  final session = _Session(link, lane);
  lane
      .run(
        run: 'r1',
        pubkeyB64: 'PK',
        pending: pending,
        link: link,
        onDone: (id, sigOk, pubkeyMatch) =>
            session.dones.add('$id:$sigOk:$pubkeyMatch'),
      )
      .then((outcome) => session.outcome = outcome);
  fa.flushMicrotasks();
  return session;
}

void main() {
  final payloadA = _payload(200, 1);
  final payloadB = _payload(300, 2);
  final payloadBig = _payload(100000, 3);

  test('1 fromEnvelope round-trips buildBlackoutEnvelope', () {
    final envelope = buildBlackoutEnvelope(
      run: 'r1',
      id: 'abc',
      createdMs: 7,
      payload: payloadA,
      signature: _sig,
      pubkeyB64: 'PK',
    );
    final record = StreamRecord.fromEnvelope(envelope);
    expect(record.id, 'abc');
    expect(record.createdMs, 7);
    expect(record.sig, _sig);
    expect(record.payload, payloadA);
    expect(record.total, 200);
    expect(
      () => StreamRecord.fromEnvelope(utf8.encode('{"id":"x"}')),
      throwsFormatException,
    );
    expect(() => StreamRecord.fromEnvelope([1, 2, 3]), throwsFormatException);
  });

  test('2 the hello names v, run, pubkey and the ids in delivery order', () {
    fakeAsync((fa) {
      final s = _start(fa, [
        _bundle('a', payloadA),
        _bundle('b', payloadB),
        _bundle('c', payloadA),
      ]);
      final hello = s.hub.hello!;
      expect(hello.keys.toSet(), {'v', 'run', 'pubkey', 'ids'});
      expect(hello['v'], 3);
      expect(hello['run'], 'r1');
      expect(hello['pubkey'], 'PK');
      expect(hello['ids'], ['a', 'b', 'c']);
      expect(s.hub.headers, isEmpty);
      expect(s.lane.recordsOffered, 3);
      expect(s.lane.params, isNull);
    });
  });

  test('3 have 0: the header keys, then exactly total raw bytes', () {
    fakeAsync((fa) {
      final s = _start(fa, [_bundle('a', payloadA, createdMs: 4242)]);
      s.link.sendSplit(_stateLine());
      fa.flushMicrotasks();
      expect(s.hub.headers.length, 1);
      final header = s.hub.headers.single;
      expect(header.keys.toSet(), {
        'id',
        'off',
        'len',
        'total',
        'created_ms',
        'sig',
      });
      expect(header['id'], 'a');
      expect(header['off'], 0);
      expect(header['len'], 200);
      expect(header['total'], 200);
      expect(header['created_ms'], 4242);
      expect(header['sig'], base64Encode(_sig));
      expect(s.hub.bodies['a'], payloadA);
      expect(s.hub.rawBytes, 200);
      expect(s.lane.bytesWritten, 200);
      expect(s.lane.params!.toJson(), {
        'port': 8766,
        'piece_bytes': 8192,
        'ack_bytes': 8192,
        'ack_interval_s': 2,
        'inflight_bytes': 32768,
        'stall_s': 15,
      });
    });
  });

  test(
    '4 state have 40000 resumes from byte 40000; complete needs no header',
    () {
      fakeAsync((fa) {
        final s = _start(fa, [
          _bundle('big', payloadBig),
          _bundle('a', payloadA),
        ]);
        s.link.send(
          _stateLine(
            state: {
              'big': {'have': 40000, 'complete': false},
              'a': {'have': 200, 'complete': true},
            },
            inflightBytes: 200000,
          ),
        );
        fa.flushMicrotasks();
        expect(s.dones, ['a:true:true']);
        expect(s.lane.doneCount, 1);
        expect(s.hub.headers.map((h) => h['id']), ['big']);
        final header = s.hub.headers.single;
        expect(header['off'], 40000);
        expect(header['len'], 60000);
        expect(header['total'], 100000);
        expect(s.hub.bodies['big'], payloadBig.sublist(40000));
        expect(s.lane.bytesWritten, 60000);
        expect(s.outcome, isNull);
        s.link.send({
          'done': 'big',
          'sig_ok': true,
          'pubkey_match': true,
          'bytes': 100000,
        });
        fa.flushMicrotasks();
        expect(s.dones, ['a:true:true', 'big:true:true']);
        expect(s.outcome, StreamOutcome.allDone);
        expect(s.lane.bytesAcked, 60000);
        expect(s.link.destroyCalls, 1);
      });
    },
  );

  test(
    '5 acks withheld: written stops at inflight_bytes; an ack frees more',
    () {
      fakeAsync((fa) {
        final s = _start(fa, [_bundle('big', payloadBig)]);
        s.link.send(_stateLine());
        fa.flushMicrotasks();
        expect(s.hub.rawBytes, 32768);
        expect(s.lane.bytesWritten, 32768);
        expect(s.lane.bytesAcked, 0);
        s.link.send({'ack': 'big', 'have': 8192});
        fa.flushMicrotasks();
        expect(s.hub.rawBytes, 32768 + 8192);
        expect(s.lane.bytesAcked, 8192);
        expect(s.hub.bodies['big'], payloadBig.sublist(0, 32768 + 8192));
        // An ack claiming more than was sent credits only what was sent, so
        // the cap opens by one window, not by the hub's number.
        s.link.send({'ack': 'big', 'have': 99999});
        fa.flushMicrotasks();
        expect(s.lane.bytesAcked, 32768 + 8192);
        expect(s.lane.bytesWritten, 32768 + 8192 + 32768);
        expect(s.hub.rawBytes, s.lane.bytesWritten);
      });
    },
  );

  test("6 B's header precedes A's done", () {
    fakeAsync((fa) {
      final s = _start(fa, [_bundle('a', payloadA), _bundle('b', payloadB)]);
      s.link.send(_stateLine());
      fa.flushMicrotasks();
      expect(s.hub.headers.map((h) => h['id']), ['a', 'b']);
      expect(s.hub.bodies['a'], payloadA);
      expect(s.hub.bodies['b'], payloadB);
      expect(s.dones, isEmpty);
      expect(s.outcome, isNull);
    });
  });

  test(
    '7 onDone follows the arrival order of done lines, sig_ok false too',
    () {
      fakeAsync((fa) {
        final s = _start(fa, [_bundle('a', payloadA), _bundle('b', payloadB)]);
        s.link.send(_stateLine());
        fa.flushMicrotasks();
        s.link.send({
          'done': 'b',
          'sig_ok': false,
          'pubkey_match': true,
          'bytes': 300,
        });
        fa.flushMicrotasks();
        expect(s.dones, ['b:false:true']);
        expect(s.outcome, isNull);
        s.link.send({
          'done': 'a',
          'sig_ok': true,
          'pubkey_match': false,
          'bytes': 200,
        });
        fa.flushMicrotasks();
        expect(s.dones, ['b:false:true', 'a:true:false']);
        expect(s.lane.doneCount, 2);
        expect(s.lane.bytesAcked, 500);
        expect(s.outcome, StreamOutcome.allDone);
        expect(s.link.destroyed, isTrue);
      });
    },
  );

  test('8 no hub line for stall_s: destroyed, stalled, no onDone', () {
    fakeAsync((fa) {
      final s = _start(fa, [_bundle('a', payloadA)]);
      s.link.send(_stateLine(stallS: 15));
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 14));
      expect(s.outcome, isNull);
      // Any hub line resets the timer, even one the lane ignores.
      s.link.send({'note': 'still here'});
      fa.flushMicrotasks();
      fa.elapse(const Duration(seconds: 14));
      expect(s.outcome, isNull);
      fa.elapse(const Duration(seconds: 1));
      expect(s.outcome, StreamOutcome.stalled);
      expect(s.link.destroyCalls, 1);
      expect(s.dones, isEmpty);
    });
  });

  test('9 an error line ends the session without onDone for that id', () {
    fakeAsync((fa) {
      final s = _start(fa, [_bundle('a', payloadA), _bundle('b', payloadB)]);
      s.link.send(_stateLine());
      fa.flushMicrotasks();
      s.link.send({
        'done': 'a',
        'sig_ok': true,
        'pubkey_match': true,
        'bytes': 200,
      });
      s.link.send({'error': 'bad_offset', 'id': 'b', 'have': 100});
      fa.flushMicrotasks();
      expect(s.outcome!.kind, StreamOutcomeKind.error);
      expect(s.outcome!.code, 'bad_offset');
      expect(s.outcome!.id, 'b');
      expect(s.outcome.toString(), 'error(bad_offset, b)');
      expect(s.dones, ['a:true:true']);
      expect(s.link.destroyCalls, 1);
      // Nothing is written after the session ended: a late ack is dropped.
      final written = s.hub.rawBytes;
      s.link.send({'ack': 'b', 'have': 300});
      fa.flushMicrotasks();
      expect(s.hub.rawBytes, written);
    });
  });

  test('10 the hub closing the connection yields hubClosed', () {
    fakeAsync((fa) {
      final s = _start(fa, [_bundle('a', payloadA)]);
      s.link.send(_stateLine());
      fa.flushMicrotasks();
      s.link.closeFromHub();
      fa.flushMicrotasks();
      expect(s.outcome, StreamOutcome.hubClosed);
      expect(s.link.destroyCalls, 1);
      expect(s.dones, isEmpty);
    });
  });

  test(
    '11 stall_s 1 from the state stalls at 1 s; no state stalls at 20 s',
    () {
      fakeAsync((fa) {
        final s = _start(fa, [_bundle('a', payloadA)]);
        s.link.send(_stateLine(stallS: 1));
        fa.flushMicrotasks();
        fa.elapse(const Duration(milliseconds: 999));
        expect(s.outcome, isNull);
        fa.elapse(const Duration(milliseconds: 1));
        expect(s.outcome, StreamOutcome.stalled);
      });
      fakeAsync((fa) {
        final s = _start(fa, [_bundle('a', payloadA)]);
        fa.elapse(Duration(seconds: helloTimeoutS - 1));
        expect(s.outcome, isNull);
        fa.elapse(const Duration(seconds: 1));
        expect(s.outcome, StreamOutcome.stalled);
      });
      fakeAsync((fa) {
        final s = _start(fa, [_bundle('a', payloadA)]);
        s.link.send({'state': <String, Object?>{}, 'piece_bytes': 8192});
        fa.flushMicrotasks();
        expect(s.outcome!.kind, StreamOutcomeKind.error);
        expect(s.outcome!.code, 'bad_state');
      });
    },
  );

  test('12 BlackoutPlan.parse: v3 with and without stream, v2 unchanged', () {
    final plan = [
      {'kind': 'text', 'bytes': 200, 'n': 2},
      {'kind': 'photo', 'bytes': 45000, 'n': 1},
    ];
    final stream = {
      'port': 8766,
      'piece_bytes': 8192,
      'ack_bytes': 8192,
      'ack_interval_s': 2,
      'inflight_bytes': 32768,
      'stall_s': 15,
    };
    final v3 = BlackoutPlan.parse({'v': 3, 'plan': plan, 'stream': stream})!;
    expect(v3.v, 3);
    expect(v3.items.length, 3);
    expect(v3.stream, stream);
    expect(BlackoutStreamParams.portOf(v3.stream), 8766);

    final v3NoStream = BlackoutPlan.parse({'v': 3, 'plan': plan})!;
    expect(v3NoStream.v, 3);
    expect(v3NoStream.items, isEmpty);
    expect(v3NoStream.stream, isNull);
    expect(BlackoutStreamParams.portOf(v3NoStream.stream), isNull);

    final v2 = BlackoutPlan.parse({'v': 2, 'plan': plan, 'stream': stream})!;
    expect(v2.v, 2);
    expect(v2.items.length, 3);
    expect(v2.chunkBytes, 8192);
    expect(BlackoutPlan.parse({'v': 4, 'plan': plan}), isNull);
  });
}
