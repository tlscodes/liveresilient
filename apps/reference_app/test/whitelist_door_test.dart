/// The whitelist profile's door loop and its two negative controls, against
/// fakes: no sockets, no waiting. The fake clock advances only where the
/// unit asks it to, so the interval is observed rather than slept through.
///
/// The case that carries the profile's meaning: a reset and a timeout are
/// NOT the same answer. `block return-rst` produces a reset; a drop
/// produces a timeout. A control that timed out proves nothing about the
/// rule, so it is recorded as a failure of the control.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/whitelist_door.dart';

/// Advances only on [sleep] and on the explicit per-call costs the fakes
/// add, so every measured millisecond in a case is one the case wrote.
class _FakeClock implements DoorClock {
  DateTime _now = DateTime.utc(2026, 9, 5, 12);
  final List<Duration> slept = <Duration>[];

  @override
  DateTime nowUtc() => _now;

  @override
  Future<void> sleep(Duration duration) async {
    slept.add(duration);
    _now = _now.add(duration);
  }

  void advance(Duration duration) => _now = _now.add(duration);
}

/// Answers a scripted sequence; the last entry repeats. An entry of null
/// throws instead of answering.
class _FakeGetter implements DoorHttpGetter {
  _FakeGetter(this.script, {required this.clock, this.perCall = Duration.zero});

  final List<DoorHttpResponse?> script;
  final _FakeClock clock;
  final Duration perCall;
  final List<String> urls = <String>[];

  /// Called after every answer, so a case can stop the loop.
  void Function(int calls)? after;

  @override
  Future<DoorHttpResponse> get(String url) async {
    urls.add(url);
    clock.advance(perCall);
    final entry =
        script[urls.length - 1 < script.length
            ? urls.length - 1
            : script.length - 1];
    after?.call(urls.length);
    if (entry == null) throw StateError('connection refused');
    return entry;
  }
}

class _FakeTcp implements DoorTcpConnector {
  _FakeTcp(this.outcome, {required this.clock, this.cost = Duration.zero});

  final TcpProbeOutcome? outcome;
  final _FakeClock clock;
  final Duration cost;
  int calls = 0;
  String? host;
  int? port;

  @override
  Future<TcpProbeOutcome> connect({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    calls++;
    this.host = host;
    this.port = port;
    clock.advance(cost);
    final result = outcome;
    if (result == null) throw StateError('no route to host');
    return result;
  }
}

class _FakeUdp implements DoorUdpProber {
  _FakeUdp(this.outcome, {required this.clock, this.cost = Duration.zero});

  final UdpProbeOutcome? outcome;
  final _FakeClock clock;
  final Duration cost;
  int calls = 0;
  int? port;

  @override
  Future<UdpProbeOutcome> probe({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    calls++;
    this.port = port;
    clock.advance(cost);
    final result = outcome;
    if (result == null) throw StateError('socket unavailable');
    return result;
  }
}

const DoorHttpResponse _ok200 = DoorHttpResponse(status: 200, bytes: 118);
const DoorHttpResponse _ok200b = DoorHttpResponse(status: 200, bytes: 999);
const DoorHttpResponse _err503 = DoorHttpResponse(status: 503, bytes: 0);

void main() {
  const config = WhitelistDoorConfig(url: 'https://192.168.2.1:4443/');

  ({
    WhitelistDoor door,
    _FakeGetter http,
    _FakeClock clock,
    List<DoorOpen> opens,
  })
  build({
    required List<DoorHttpResponse?> script,
    Duration perCall = const Duration(milliseconds: 40),
    TcpProbeOutcome? tcp = TcpProbeOutcome.reset,
    UdpProbeOutcome? udp = UdpProbeOutcome.silent,
    WhitelistDoorConfig cfg = config,
    int stopAfter = 1,
  }) {
    final clock = _FakeClock();
    final http = _FakeGetter(script, clock: clock, perCall: perCall);
    final opens = <DoorOpen>[];
    final door = WhitelistDoor(
      config: cfg,
      http: http,
      tcp: _FakeTcp(tcp, clock: clock),
      udp: _FakeUdp(udp, clock: clock),
      clock: clock,
      onOpen: opens.add,
    );
    http.after = (calls) {
      if (calls >= stopAfter) door.stop();
    };
    return (door: door, http: http, clock: clock, opens: opens);
  }

  test('the first success stamps once and is never re-stamped', () async {
    final rig = build(script: [_ok200, _ok200b], stopAfter: 2);
    await rig.door.run();
    expect(rig.http.urls.length, 2);
    expect(rig.opens.length, 1);
    expect(rig.door.firstOpen!.status, 200);
    expect(rig.door.firstOpen!.bytes, 118);
    expect(rig.door.firstOpen!.tMs, 40);
    expect(rig.door.firstOpen!.at, DateTime.utc(2026, 9, 5, 12, 0, 0, 40));
  });

  test(
    'failures before the first success are counted and do not stamp',
    () async {
      final rig = build(script: [_err503, null, _ok200], stopAfter: 3);
      await rig.door.run();
      expect(rig.door.ok, 1);
      expect(rig.door.fail, 2);
      expect(rig.opens.length, 1);
      // Two failed samples at 40 ms each, plus two 1 s intervals, then the
      // third sample's own 40 ms.
      expect(rig.door.firstOpen!.tMs, 2120);
    },
  );

  test('ok and fail totals cover the whole run', () async {
    final rig = build(script: [_ok200, _err503, _ok200b, null], stopAfter: 4);
    await rig.door.run();
    expect(rig.door.ok, 2);
    expect(rig.door.fail, 2);
    expect(rig.door.samplesJson(), {'ok': 2, 'fail': 2});
  });

  test('the loop keeps running after the first success', () async {
    final rig = build(script: [_ok200], stopAfter: 5);
    await rig.door.run();
    expect(rig.http.urls.length, 5);
    expect(
      rig.http.urls.every((u) => u == 'https://192.168.2.1:4443/'),
      isTrue,
    );
    expect(rig.door.ok, 5);
    expect(rig.opens.length, 1, reason: 'onOpen fires exactly once');
    expect(rig.door.isRunning, isFalse);
  });

  test('the clock drives the interval; nothing waits on real time', () async {
    final rig = build(
      script: [_ok200],
      stopAfter: 3,
      cfg: const WhitelistDoorConfig(
        url: 'https://192.168.2.1:4443/',
        interval: Duration(seconds: 5),
      ),
    );
    await rig.door.run();
    // Three samples, two intervals between them: the last sample stops the
    // loop before sleeping again.
    expect(rig.clock.slept, [
      const Duration(seconds: 5),
      const Duration(seconds: 5),
    ]);
  });

  test(
    'a reset connect is recorded as a passing control with its ms',
    () async {
      final clock = _FakeClock();
      final tcp = _FakeTcp(
        TcpProbeOutcome.reset,
        clock: clock,
        cost: const Duration(milliseconds: 7),
      );
      final door = WhitelistDoor(
        config: config,
        http: _FakeGetter([_ok200], clock: clock),
        tcp: tcp,
        udp: _FakeUdp(UdpProbeOutcome.silent, clock: clock),
        clock: clock,
      );
      final result = await door.probeResetElsewhere();
      expect(result.outcome, TcpProbeOutcome.reset);
      expect(result.isPass, isTrue);
      expect(result.ms, 7);
      expect(result.toJson(), {'rst_ms': 7, 'outcome': 'reset', 'pass': true});
      expect(tcp.host, '192.168.2.9');
      expect(tcp.port, 443);
    },
  );

  test(
    'a connect that TIMES OUT instead of resetting FAILS the control',
    () async {
      final clock = _FakeClock();
      final door = WhitelistDoor(
        config: config,
        http: _FakeGetter([_ok200], clock: clock),
        tcp: _FakeTcp(
          TcpProbeOutcome.timedOut,
          clock: clock,
          cost: const Duration(seconds: 5),
        ),
        udp: _FakeUdp(UdpProbeOutcome.silent, clock: clock),
        clock: clock,
      );
      final result = await door.probeResetElsewhere();
      expect(result.outcome, TcpProbeOutcome.timedOut);
      expect(
        result.isPass,
        isFalse,
        reason: 'a drop is not a reset: the RST rule was not proven',
      );
      expect(result.ms, 5000);
    },
  );

  test('a connect that SUCCEEDS fails the control too', () async {
    final clock = _FakeClock();
    final door = WhitelistDoor(
      config: config,
      http: _FakeGetter([_ok200], clock: clock),
      tcp: _FakeTcp(TcpProbeOutcome.connected, clock: clock),
      udp: _FakeUdp(UdpProbeOutcome.silent, clock: clock),
      clock: clock,
    );
    final result = await door.probeResetElsewhere();
    expect(result.outcome, TcpProbeOutcome.connected);
    expect(result.isPass, isFalse);
  });

  test('a connector that throws is recorded as error, not as a pass', () async {
    final clock = _FakeClock();
    final door = WhitelistDoor(
      config: config,
      http: _FakeGetter([_ok200], clock: clock),
      tcp: _FakeTcp(null, clock: clock),
      udp: _FakeUdp(UdpProbeOutcome.silent, clock: clock),
      clock: clock,
    );
    final result = await door.probeResetElsewhere();
    expect(result.outcome, TcpProbeOutcome.error);
    expect(result.isPass, isFalse);
  });

  test('the UDP probe timing out is the PASS case', () async {
    final clock = _FakeClock();
    final udp = _FakeUdp(
      UdpProbeOutcome.silent,
      clock: clock,
      cost: const Duration(milliseconds: 3000),
    );
    final door = WhitelistDoor(
      config: config,
      http: _FakeGetter([_ok200], clock: clock),
      tcp: _FakeTcp(TcpProbeOutcome.reset, clock: clock),
      udp: udp,
      clock: clock,
    );
    final result = await door.probeQuicDead();
    expect(result.outcome, UdpProbeOutcome.silent);
    expect(result.isPass, isTrue);
    expect(result.toJson(), {
      'timeout_ms': 3000,
      'outcome': 'silent',
      'pass': true,
    });
    expect(udp.port, 443);
  });

  test('any reply to the UDP probe fails the control', () async {
    final clock = _FakeClock();
    final door = WhitelistDoor(
      config: config,
      http: _FakeGetter([_ok200], clock: clock),
      tcp: _FakeTcp(TcpProbeOutcome.reset, clock: clock),
      udp: _FakeUdp(
        UdpProbeOutcome.replied,
        clock: clock,
        cost: const Duration(milliseconds: 12),
      ),
      clock: clock,
    );
    final result = await door.probeQuicDead();
    expect(result.outcome, UdpProbeOutcome.replied);
    expect(result.isPass, isFalse);
    expect(result.ms, 12);
  });

  test('each control runs at most once and caches its result', () async {
    final clock = _FakeClock();
    final tcp = _FakeTcp(TcpProbeOutcome.reset, clock: clock);
    final udp = _FakeUdp(UdpProbeOutcome.silent, clock: clock);
    final door = WhitelistDoor(
      config: config,
      http: _FakeGetter([_ok200], clock: clock),
      tcp: tcp,
      udp: udp,
      clock: clock,
    );
    final first = await door.probeResetElsewhere();
    expect(identical(await door.probeResetElsewhere(), first), isTrue);
    final quic = await door.probeQuicDead();
    expect(identical(await door.probeQuicDead(), quic), isTrue);
    expect(tcp.calls, 1);
    expect(udp.calls, 1);
    expect(door.resetResult, same(first));
    expect(door.quicResult, same(quic));
  });

  test('the QUIC-shaped datagram is a 1200-byte version-1 Initial', () {
    final datagram = quicShapedInitialDatagram(Random(7));
    expect(datagram.length, 1200, reason: 'RFC 9000 14.1 minimum');
    expect(datagram[0], 0xc0);
    expect(datagram.sublist(1, 5), [0x00, 0x00, 0x00, 0x01]);
    expect(datagram[5], 8);
    expect(datagram[14], 8);
    expect(datagram.sublist(23).every((b) => b == 0), isTrue);
    expect(
      quicShapedInitialDatagram(Random(7)),
      datagram,
      reason: 'the connection ids come from the injected Random',
    );
  });

  group('config', () {
    test('defaults fill every key but url', () {
      final parsed = WhitelistDoorConfig.parse({
        'url': 'https://192.168.2.1:4443/',
      });
      expect(parsed.url, 'https://192.168.2.1:4443/');
      expect(parsed.interval, const Duration(seconds: 1));
      expect(parsed.blockedHost, '192.168.2.9');
      expect(parsed.rstPort, 443);
      expect(parsed.quicPort, 443);
      expect(parsed.quicTimeout, const Duration(milliseconds: 3000));
      expect(parsed.relayOnly, isFalse);
    });

    test('every key is read when present', () {
      final parsed = WhitelistDoorConfig.parse({
        'url': 'https://10.0.0.1:8443/page',
        'interval_s': 2,
        'blocked_host': '10.0.0.9',
        'rst_port': 8443,
        'quic_port': 4433,
        'quic_timeout_ms': 1500,
        'relay_only': true,
      });
      expect(parsed.interval, const Duration(seconds: 2));
      expect(parsed.blockedHost, '10.0.0.9');
      expect(parsed.rstPort, 8443);
      expect(parsed.quicPort, 4433);
      expect(parsed.quicTimeout, const Duration(milliseconds: 1500));
      expect(parsed.relayOnly, isTrue);
      expect(parsed.toJson()['interval_s'], 2);
      expect(parsed.toJson()['relay_only'], true);
    });

    test('out-of-range or wrongly typed values fall back to the defaults', () {
      final parsed = WhitelistDoorConfig.parse({
        'url': 'https://192.168.2.1:4443/',
        'interval_s': 0,
        'blocked_host': '',
        'rst_port': 70000,
        'quic_port': '443',
        'quic_timeout_ms': -1,
        'relay_only': 'yes',
      });
      expect(parsed.interval, const Duration(seconds: 1));
      expect(parsed.blockedHost, '192.168.2.9');
      expect(parsed.rstPort, 443);
      expect(parsed.quicPort, 443);
      expect(parsed.quicTimeout, const Duration(milliseconds: 3000));
      expect(parsed.relayOnly, isFalse, reason: 'only a real true enables it');
    });

    test('a missing or empty url is rejected loudly', () {
      expect(
        () => WhitelistDoorConfig.parse(const <String, Object?>{}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WhitelistDoorConfig.parse({'url': ''}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => WhitelistDoorConfig.parse({'url': 4443}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
