import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

const String _domain = 'valve.example';

/// An authoritative responder for [_domain], in this process.
///
/// It speaks the same wire format as `tools/t2/txt_query_server.py`: it
/// parses each query name, keeps the session's chunks, and answers with a
/// TXT record. The lane therefore exercises real DNS messages over a real
/// socket here, which the old sidecar-shaped fake could not do — that one
/// only proved a status byte came back.
class _FakeValve {
  _FakeValve._(this._socket);

  static Future<_FakeValve> start() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final valve = _FakeValve._(socket);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram != null) valve._answer(datagram);
    });
    return valve;
  }

  final RawDatagramSocket _socket;
  final Map<String, List<ParsedTxtQuery>> _sessions =
      <String, List<ParsedTxtQuery>>{};

  /// Payloads that arrived complete, in order.
  final List<Uint8List> delivered = <Uint8List>[];

  /// Queries seen, including the ones deliberately dropped.
  int queries = 0;

  /// Drop this many queries before answering anything again.
  int dropFirst = 0;

  /// Answer this many queries and drop every one after them.
  ///
  /// The counter, not a timer, is what makes "go quiet part way through a
  /// payload" reproducible. A `Future.delayed` that flips a flag mid-send
  /// depends on the send being slower than the delay, which is a property of
  /// the machine and not of the lane: the same case passed six times on a
  /// developer's Mac and failed on the Linux runner, where the whole payload
  /// finished before the timer fired.
  int? answerThenDrop;

  /// Answer with this rcode instead of carrying the payload.
  int? rcode;

  /// Answer with a transaction id that is not the one asked for.
  bool corruptTxid = false;

  HostPort get endpoint =>
      HostPort(host: _socket.address.address, port: _socket.port);

  void close() => _socket.close();

  void _answer(Datagram datagram) {
    queries += 1;
    if (dropFirst > 0) {
      dropFirst -= 1;
      return;
    }
    final ceiling = answerThenDrop;
    if (ceiling != null && queries > ceiling) return;
    final query = TxtQueryWire.parseDnsQueryPacket(datagram.data);
    final parsed = TxtQueryWire.parseQueryName(query.name, _domain);
    final session = _sessions.putIfAbsent(
      parsed.sessionId,
      () => <ParsedTxtQuery>[],
    );
    session.add(parsed);
    var carried = Uint8List.fromList(const <int>[0x06]); // an ack
    try {
      final payload = TxtQueryWire.reassemble(session);
      delivered.add(payload);
      _sessions.remove(parsed.sessionId);
      if (payload.isNotEmpty) carried = payload;
    } on TxtQueryWireException {
      // Chunks still missing: acknowledge this one and wait for the rest.
    }
    final answer = TxtQueryWire.buildDnsAnswerPacket(
      corruptTxid ? (query.txid ^ 0xFFFF) : query.txid,
      query.name,
      rcode == null ? TxtQueryWire.frameDown(carried) : null,
      rcode: rcode ?? TxtQueryWire.rcodeNoError,
    );
    _socket.send(answer, datagram.address, datagram.port);
  }
}

/// A resolver that is reachable but never answers — a filtered port 53,
/// which is the normal failure on a restricted mobile network.
Future<RawDatagramSocket> _silentResolver() =>
    RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

TxtQueryLane _laneTo(
  List<HostPort> resolvers, {
  Duration timeout = const Duration(milliseconds: 250),
  int failThreshold = 5,
}) => TxtQueryLane(
  domain: _domain,
  transports: <TxtQueryTransport>[
    for (final resolver in resolvers) Udp53QueryTransport(resolver),
  ],
  timeout: timeout,
  failThreshold: failThreshold,
);

void main() {
  late _FakeValve valve;

  setUp(() async {
    valve = await _FakeValve.start();
  });

  tearDown(() {
    valve.close();
  });

  test('carries a payload the responder reassembles whole', () async {
    final lane = _laneTo(<HostPort>[valve.endpoint]);
    addTearDown(lane.dispose);
    final payload = List<int>.generate(200, (i) => (i * 7) & 0xFF);

    final result = await lane.send(payload);

    expect(result.status, SendStatus.ok);
    expect(result.delivered, isTrue);
    expect(valve.delivered.single, payload);
    // 202 framed bytes over 39-byte chunks is six queries, all answered.
    expect(lane.attempts, 6);
    expect(lane.replies, 6);
    expect(lane.lastReply, payload);
    expect(lane.lastSessionId, isNotNull);
    expect(lane.health.pathDegraded, isFalse);
  });

  test('a probe is one query and carries no payload', () async {
    final lane = _laneTo(<HostPort>[valve.endpoint]);
    addTearDown(lane.dispose);

    expect(await lane.probe(), isTrue);
    expect(lane.attempts, 1);
    expect(valve.delivered.single, isEmpty);
  });

  test('two payloads keep their own sessions', () async {
    final lane = _laneTo(<HostPort>[valve.endpoint]);
    addTearDown(lane.dispose);

    await lane.send(List<int>.filled(50, 1));
    final first = lane.lastSessionId;
    await lane.send(List<int>.filled(50, 2));

    expect(lane.lastSessionId, isNot(first));
    expect(valve.delivered, hasLength(2));
    expect(valve.delivered[0], List<int>.filled(50, 1));
    expect(valve.delivered[1], List<int>.filled(50, 2));
  });

  test('a silent resolver is transient, not a dead path', () async {
    final silent = await _silentResolver();
    addTearDown(silent.close);
    final lane = _laneTo(<HostPort>[
      HostPort(host: silent.address.address, port: silent.port),
    ], timeout: const Duration(milliseconds: 60));
    addTearDown(lane.dispose);

    final result = await lane.send(const <int>[1, 2, 3]);

    expect(result.status, SendStatus.transient);
    expect(lane.isDown, isFalse);
    expect(lane.health.score(), greaterThan(0));
  });

  test(
    'enough failures declare the valve DOWN, so the ranker leaves the lane',
    () async {
      final silent = await _silentResolver();
      addTearDown(silent.close);
      final lane = _laneTo(
        <HostPort>[HostPort(host: silent.address.address, port: silent.port)],
        timeout: const Duration(milliseconds: 40),
        failThreshold: 2,
      );
      addTearDown(lane.dispose);

      final first = await lane.send(const <int>[1]);
      final second = await lane.send(const <int>[2]);

      expect(first.status, SendStatus.transient);
      expect(second.status, SendStatus.unavailable);
      expect(lane.isDown, isTrue);
      expect(lane.health.pathDegraded, isTrue);
      expect(lane.health.score(), 0.0);
    },
  );

  test('DOWN is terminal: a DOWN lane never queries again', () async {
    final lane = _laneTo(
      <HostPort>[valve.endpoint],
      timeout: const Duration(milliseconds: 60),
      failThreshold: 1,
    );
    addTearDown(lane.dispose);
    valve.rcode = TxtQueryWire.rcodeNxDomain;

    expect((await lane.send(const <int>[1])).status, SendStatus.unavailable);
    final spent = lane.attempts;
    expect((await lane.send(const <int>[2])).status, SendStatus.unavailable);

    expect(lane.attempts, spent, reason: 'a DOWN valve stops asking');
  });

  test('a filtered resolver rotates to the next candidate mid-send', () async {
    final silent = await _silentResolver();
    addTearDown(silent.close);
    final lane = _laneTo(<HostPort>[
      HostPort(host: silent.address.address, port: silent.port),
      valve.endpoint,
    ], timeout: const Duration(milliseconds: 60));
    addTearDown(lane.dispose);

    final result = await lane.send(const <int>[9, 9, 9]);

    expect(result.status, SendStatus.ok);
    expect(valve.delivered.single, const <int>[9, 9, 9]);
    expect(lane.currentTransport.label, contains('${valve.endpoint.port}'));
  });

  test(
    'a rotation mid-payload gives up rather than splitting a session',
    () async {
      final silent = await _silentResolver();
      addTearDown(silent.close);
      final lane = _laneTo(<HostPort>[
        valve.endpoint,
        HostPort(host: silent.address.address, port: silent.port),
      ], timeout: const Duration(milliseconds: 60));
      addTearDown(lane.dispose);
      // Answer the first chunk, then go quiet for the rest of the payload.
      // Counted, not timed: see the note on [_FakeValve.answerThenDrop].
      valve.answerThenDrop = 1;

      final result = await lane.send(List<int>.filled(200, 3));

      expect(result.status, SendStatus.transient);
      expect(valve.delivered, isEmpty);
    },
  );

  test('an answer with the wrong transaction id is not an answer', () async {
    valve.corruptTxid = true;
    final lane = _laneTo(<HostPort>[
      valve.endpoint,
    ], timeout: const Duration(milliseconds: 60));
    addTearDown(lane.dispose);

    final result = await lane.send(const <int>[4]);

    expect(result.status, SendStatus.transient);
    expect(valve.queries, greaterThan(0), reason: 'the query did go out');
  });

  test('a reply from anyone but the resolver is not a reply', () async {
    final impostor = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(impostor.close);
    final silent = await _silentResolver();
    addTearDown(silent.close);
    final lane = _laneTo(<HostPort>[
      HostPort(host: silent.address.address, port: silent.port),
    ], timeout: const Duration(milliseconds: 120));
    addTearDown(lane.dispose);
    silent.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = silent.receive();
      if (datagram == null) return;
      final query = TxtQueryWire.parseDnsQueryPacket(datagram.data);
      // The right answer, from the wrong socket.
      impostor.send(
        TxtQueryWire.buildDnsAnswerPacket(
          query.txid,
          query.name,
          TxtQueryWire.frameDown(const <int>[0x06]),
        ),
        datagram.address,
        datagram.port,
      );
    });

    final result = await lane.send(const <int>[5]);

    expect(result.status, SendStatus.transient);
  });

  test('a payload past the limit is refused before the wire', () async {
    final lane = _laneTo(<HostPort>[valve.endpoint]);
    addTearDown(lane.dispose);
    final before = lane.health.availability;

    final result = await lane.send(
      List<int>.filled(TxtQueryLane.maxPayloadBytes + 1, 7),
    );

    expect(result.status, SendStatus.transient);
    expect(result.error, isA<ArgumentError>());
    expect(valve.queries, 0);
    expect(lane.health.availability, before, reason: 'the path said nothing');
  });

  test('send after dispose is unavailable, not a crash', () async {
    final lane = _laneTo(<HostPort>[valve.endpoint]);
    await lane.dispose();

    final result = await lane.send(const <int>[1]);

    expect(result.status, SendStatus.unavailable);
    expect(result.error, isA<StateError>());
  });

  test('the lane refuses a configuration it cannot use', () {
    expect(
      () => TxtQueryLane(
        domain: '  ',
        transports: <TxtQueryTransport>[Udp53QueryTransport(valve.endpoint)],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => TxtQueryLane(domain: _domain, transports: const []),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('DNS over HTTPS', () {
    test('carries the same payload over RFC 8484', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final delivered = <Uint8List>[];
      final sessions = <String, List<ParsedTxtQuery>>{};
      unawaited(
        server.forEach((request) async {
          final body = <int>[];
          await request.forEach(body.addAll);
          expect(
            request.headers.contentType?.mimeType,
            'application/dns-message',
          );
          final query = TxtQueryWire.parseDnsQueryPacket(
            Uint8List.fromList(body),
          );
          final parsed = TxtQueryWire.parseQueryName(query.name, _domain);
          final session = sessions.putIfAbsent(
            parsed.sessionId,
            () => <ParsedTxtQuery>[],
          );
          session.add(parsed);
          var carried = Uint8List.fromList(const <int>[0x06]);
          try {
            final payload = TxtQueryWire.reassemble(session);
            delivered.add(payload);
            carried = payload;
          } on TxtQueryWireException {
            // Waiting for the rest of the session.
          }
          request.response.headers.contentType = ContentType.parse(
            'application/dns-message',
          );
          request.response.add(
            TxtQueryWire.buildDnsAnswerPacket(
              query.txid,
              query.name,
              TxtQueryWire.frameDown(carried),
            ),
          );
          await request.response.close();
        }),
      );
      final lane = TxtQueryLane(
        domain: _domain,
        transports: <TxtQueryTransport>[
          DohQueryTransport(
            Uri.parse('http://127.0.0.1:${server.port}/dns-query'),
          ),
        ],
        timeout: const Duration(seconds: 2),
      );
      addTearDown(lane.dispose);

      final payload = List<int>.generate(90, (i) => i);
      final result = await lane.send(payload);

      expect(result.status, SendStatus.ok);
      expect(delivered.single, payload);
      expect(lane.lastReply, payload);
    });

    test('an HTTP error is a failure, not a delivery', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        }),
      );
      final lane = TxtQueryLane(
        domain: _domain,
        transports: <TxtQueryTransport>[
          DohQueryTransport(
            Uri.parse('http://127.0.0.1:${server.port}/dns-query'),
          ),
        ],
        timeout: const Duration(seconds: 2),
      );
      addTearDown(lane.dispose);

      expect((await lane.send(const <int>[1])).status, SendStatus.transient);
    });
  });

  group('resolver discovery', () {
    test('reads the nameserver lines of a resolv.conf', () {
      final resolvers = TxtQueryResolvers.parseResolvConf(
        '# comment\n'
        'search lan\n'
        'nameserver 192.0.2.53\n'
        'nameserver   2001:db8::53\n'
        'nameserver 192.0.2.53\n'
        'nameserver not-an-address\n'
        'options edns0\n',
      );

      expect(resolvers, <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
        const HostPort(host: '2001:db8::53', port: 53),
      ]);
    });

    test('a device with no resolv.conf still has candidates', () {
      // The phone case: nothing discoverable, so the public resolvers are
      // the whole list rather than an empty one.
      final candidates = TxtQueryResolvers.candidates(
        system: const <HostPort>[],
      );

      expect(candidates, TxtQueryResolvers.publicResolvers);
    });

    test('the system resolvers come first and are not duplicated', () {
      final candidates = TxtQueryResolvers.candidates(
        system: const <HostPort>[
          HostPort(host: '192.0.2.53', port: 53),
          HostPort(host: '1.1.1.1', port: 53),
        ],
      );

      expect(candidates.first, const HostPort(host: '192.0.2.53', port: 53));
      expect(
        candidates.where((r) => r.host == '1.1.1.1').length,
        1,
        reason: 'a system resolver that is also public is listed once',
      );
    });

    test('a missing resolv.conf is not an error', () {
      expect(
        TxtQueryResolvers.systemResolvers(
          path: '${Directory.systemTemp.path}/no_such_resolv.conf',
        ),
        isEmpty,
      );
    });

    test('the valve says when it cannot produce a lane', () {
      expect(const TxtQueryValve(domain: 'valve.example').isUsable, isTrue);
      expect(const TxtQueryValve(domain: '   ').isUsable, isFalse);
    });

    test('forValve builds one transport per candidate', () async {
      final lane = TxtQueryLane.forValve(
        const TxtQueryValve(
          domain: _domain,
          resolvers: <HostPort>[HostPort(host: '192.0.2.53', port: 53)],
          dohEndpoints: <Uri>[],
        ),
      );
      addTearDown(lane.dispose);

      expect(lane.currentTransport.label, 'udp53:192.0.2.53:53');
    });
  });
}
