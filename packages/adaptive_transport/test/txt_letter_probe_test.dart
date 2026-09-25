import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

const _domain = 'valve.example';

/// The responder side of the probe, as tools/t2/txt_query_server.py does it:
/// nonces are logged per group in ARRIVAL order and every probe is answered
/// with the first one logged. Letters (non-probe payloads) are recorded.
class _Server {
  final Map<String, List<String>> log = <String, List<String>>{};
  final List<String> order = <String>[];
  final List<Uint8List> letters = <Uint8List>[];
  final Map<String, List<ParsedTxtQuery>> _sessions = {};

  Uint8List handle(ParsedDnsQuery q) {
    final chunk = TxtQueryWire.parseQueryName(q.name, _domain);
    final s = _sessions.putIfAbsent(chunk.sessionId, () => []);
    s.add(chunk);
    var down = Uint8List.fromList(const [0x06]);
    try {
      final payload = TxtQueryWire.reassemble(s);
      _sessions.remove(chunk.sessionId);
      if (payload.length == 20 &&
          String.fromCharCodes(payload.sublist(0, 4)) == 'PRB1') {
        final group = _hex(payload.sublist(4, 12));
        final nonce = _hex(payload.sublist(12, 20));
        final seen = log.putIfAbsent(group, () => []);
        if (!seen.contains(nonce)) seen.add(nonce);
        order.add(nonce);
        down = Uint8List.fromList([
          ...payload.sublist(0, 12),
          ..._unhex(seen.first),
          seen.indexOf(nonce) + 1,
        ]);
      } else {
        letters.add(payload);
      }
    } on TxtQueryWireException {
      // more chunks to come
    }
    return TxtQueryWire.buildDnsAnswerPacket(
      q.txid,
      q.name,
      TxtQueryWire.frameDown(down),
    );
  }
}

/// A resolver with its own delay TO the server and BACK to the phone.
class _Resolver implements TxtQueryTransport {
  _Resolver(
    this.label,
    this.server, {
    this.up = 0,
    this.back = 0,
    this.dead = false,
  });
  @override
  final String label;
  final _Server server;
  final int up;
  final int back;
  bool dead;
  final List<String> asked = [];

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    final q = TxtQueryWire.parseDnsQueryPacket(query);
    asked.add(q.name);
    if (dead) {
      throw TimeoutException('no answer from $label');
    }
    await Future<void>.delayed(Duration(milliseconds: up));
    final answer = server.handle(q);
    await Future<void>.delayed(Duration(milliseconds: back));
    return answer;
  }

  @override
  Future<void> dispose() async {}
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> _unhex(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

void main() {
  test(
    'winner is the nonce the SERVER logged first, not the first answer home',
    () async {
      final server = _Server();
      // a reaches the server first but its answer comes home last.
      final a = _Resolver('system', server, up: 5, back: 120);
      final b = _Resolver('8.8.8.8', server, up: 40, back: 1);
      final c = _Resolver('1.1.1.1', server, up: 80, back: 1);
      final probe = TxtLetterProbe(domain: _domain, transports: [a, b, c]);

      final out = await probe.run();

      expect(out.winnerIndex, 0);
      expect(server.log.values.single.first, out.answers[0].nonce);
      expect(out.answers.map((x) => x.rank), [1, 2, 3]);
      // Every answer names the same winner.
      expect(out.answers.map((x) => x.winnerNonce).toSet().length, 1);
      // Three distinct nonces, one group.
      expect(out.answers.map((x) => x.nonce).toSet().length, 3);
      expect(server.log.length, 1);
      // The phone's event line names the server's group and every nonce.
      final line = out.describe();
      expect(line, startsWith('group=${server.log.keys.single} winner=0 '));
      for (final a in out.answers) {
        expect(line, contains('${a.label}:${a.nonce}:${a.rank}'));
      }
    },
  );

  test('describe() marks an unanswered resolver', () {
    const out = TxtProbeOutcome(
      groupId: '0011223344556677',
      answers: [
        TxtProbeAnswer(
          index: 0,
          label: 'sys',
          nonce: 'aa',
          winnerNonce: 'aa',
          rank: 1,
        ),
        TxtProbeAnswer(index: 1, label: '8.8.8.8', nonce: 'bb'),
      ],
      winnerIndex: 0,
    );
    expect(
      out.describe(),
      'group=0011223344556677 winner=0 sys:aa:1 8.8.8.8:bb:-',
    );
  });

  test('the letter leaves through the winner first', () async {
    final server = _Server();
    final a = _Resolver('system', server, up: 60);
    final b = _Resolver('8.8.8.8', server, up: 1);
    final c = _Resolver('1.1.1.1', server, up: 30);
    final courier = TxtLetterCourier(
      probe: TxtLetterProbe(domain: _domain, transports: [a, b, c]),
    );
    final letter = List<int>.generate(300, (i) => i % 251);

    final d = await courier.send(letter);

    expect(d.route, LetterRoute.sent);
    expect(d.via, '8.8.8.8');
    expect(server.letters.single, letter);
    // b carried the probe AND every chunk of the letter; a and c only probed.
    expect(b.asked.length, greaterThan(1));
    expect(a.asked.length, 1);
    expect(c.asked.length, 1);
  });

  test(
    'no probe reaches the server: the letter is queued, then flushed',
    () async {
      final server = _Server();
      final rs = [
        _Resolver('system', server, dead: true),
        _Resolver('8.8.8.8', server, dead: true),
        _Resolver('1.1.1.1', server, dead: true),
      ];
      final courier = TxtLetterCourier(
        probe: TxtLetterProbe(domain: _domain, transports: rs),
      );

      final d = await courier.send([1, 2, 3]);
      expect(d.route, LetterRoute.queued);
      expect(d.probe!.reachedServer, isFalse);
      expect(courier.queue.length, 1);
      expect(server.letters, isEmpty);

      rs[2].dead = false;
      expect(await courier.flush(), 1);
      expect(courier.queue, isEmpty);
      expect(server.letters.single, [1, 2, 3]);
    },
  );

  test('a letter above 4096 bytes is refused before any query', () async {
    final server = _Server();
    final a = _Resolver('system', server);
    final courier = TxtLetterCourier(
      probe: TxtLetterProbe(domain: _domain, transports: [a]),
    );

    final d = await courier.send(List<int>.filled(4097, 7));

    expect(d.route, LetterRoute.tooLarge);
    expect(a.asked, isEmpty);
    expect(courier.queue, isEmpty);
    expect(
      (await courier.send(List<int>.filled(4096, 7))).route,
      LetterRoute.sent,
    );
  });

  test(
    'forLane races system resolver, 8.8.8.8 and 1.1.1.1 of the lane itself',
    () {
      final lane = TxtQueryLane.forValve(
        TxtQueryValve(
          domain: _domain,
          resolvers: TxtQueryResolvers.candidates(
            system: const [HostPort(host: '10.1.2.3', port: 53)],
          ),
        ),
      );
      final probe = TxtLetterProbe.forLane(lane);
      expect(probe.transports.map((t) => t.label), [
        'udp53:10.1.2.3:53',
        'udp53:8.8.8.8:53',
        'udp53:1.1.1.1:53',
      ]);
      // Shared objects: the winner can be handed back to the lane.
      expect(lane.preferTransport(probe.transports[2]), isTrue);
      expect(lane.currentTransport.label, 'udp53:1.1.1.1:53');
      expect(lane.preferTransport(_Resolver('x', _Server())), isFalse);
    },
  );

  group('withFallbackIfDoorAbsent', () {
    test('adds the seven secondary IPs when no door resolver is racing, '
        'each once', () {
      final transports = [_Resolver('system', _Server())];

      final widened = withFallbackIfDoorAbsent(transports);

      expect(widened, hasLength(8));
      expect(widened.first.label, 'system');
      final added = widened.skip(1).map((t) => t.label).toList();
      expect(added, [
        'udp53:8.8.4.4:53',
        'udp53:1.0.0.1:53',
        'udp53:149.112.112.112:53',
        'udp53:208.67.222.222:53',
        'udp53:208.67.220.220:53',
        'udp53:94.140.14.14:53',
        'udp53:76.76.2.0:53',
      ]);
      expect(added.toSet(), hasLength(added.length)); // no duplicate label
    });

    test('leaves the race untouched when a door resolver is already in it', () {
      final lane = TxtQueryLane.forValve(
        TxtQueryValve(
          domain: _domain,
          resolvers: TxtQueryResolvers.candidates(
            system: const [HostPort(host: '10.1.2.3', port: 53)],
          ),
        ),
      );
      final probe = TxtLetterProbe.forLane(lane); // already has 8.8.8.8

      final widened = withFallbackIfDoorAbsent(probe.transports);

      expect(widened, same(probe.transports)); // unchanged, no copy either
    });

    test('adds no address outside the fixed published fallback list', () {
      final widened = withFallbackIfDoorAbsent([
        _Resolver('system', _Server()),
      ]);
      final labels = widened.map((t) => t.label).toSet();
      expect(labels, {
        'system',
        'udp53:8.8.4.4:53',
        'udp53:1.0.0.1:53',
        'udp53:149.112.112.112:53',
        'udp53:208.67.222.222:53',
        'udp53:208.67.220.220:53',
        'udp53:94.140.14.14:53',
        'udp53:76.76.2.0:53',
      });
    });

    test('forLane races UDP/53 only — the probe carries no DoH transport, '
        'so no DoH name is added here', () {
      final lane = TxtQueryLane.forValve(TxtQueryValve(domain: _domain));
      final probe = TxtLetterProbe.forLane(lane);

      expect(
        probe.transports.map((t) => t.label).where((l) => l.startsWith('doh:')),
        isEmpty,
      );
    });
  });

  test(
    'a forged reply naming a nonce this run never sent cannot win',
    () async {
      final server = _Server();
      // The real resolver actually reaches the server; the forger never
      // does — it only sees the query go by (as an in-path censor could)
      // and answers on its own, claiming to be first with a nonce it
      // invented. It cannot know the real nonces: they are random and
      // never sent to it.
      final real = _Resolver('8.8.8.8', server, up: 5);
      final forger = _Forger();
      final probe = TxtLetterProbe(domain: _domain, transports: [forger, real]);

      final out = await probe.run();

      // The forger answered — its reply parses — but names a nonce
      // outside this run's own set, so it never becomes the winner.
      expect(out.answers[0].winnerNonce, isNotNull);
      expect(out.winnerIndex, isNot(0));
      // The honest resolver, which actually reached the server, wins.
      expect(out.winnerIndex, 1);
      expect(out.reachedServer, isTrue);
    },
  );

  test('a reply for another group is not a winner', () async {
    final server = _Server();
    final a = _Resolver('stale', server);
    final probe = TxtLetterProbe(domain: _domain, transports: [a]);
    // Poison: answer every query with a PRB1 reply for a different group.
    final poisoned = _Poison(a);
    final out = await TxtLetterProbe(
      domain: _domain,
      transports: [poisoned],
    ).run();
    expect(out.reachedServer, isFalse);
    expect(out.answers.single.error, isA<TxtQueryWireException>());
    expect((await probe.run()).reachedServer, isTrue);
  });
}

class _Poison implements TxtQueryTransport {
  _Poison(this.inner);
  final _Resolver inner;
  @override
  String get label => 'poison';
  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    final q = TxtQueryWire.parseDnsQueryPacket(query);
    final down = [
      0x50,
      0x52,
      0x42,
      0x31,
      ...List.filled(8, 9),
      ...List.filled(8, 1),
      1,
    ];
    return TxtQueryWire.buildDnsAnswerPacket(
      q.txid,
      q.name,
      TxtQueryWire.frameDown(down),
    );
  }

  @override
  Future<void> dispose() async {}
}

/// An in-path forger: it sees the query go by (the group is right there in
/// the name) and answers on its own — it never reaches the real server —
/// claiming to be first with a nonce of its own invention. It cannot name
/// a nonce this run actually sent: those are random and never told to it.
class _Forger implements TxtQueryTransport {
  @override
  String get label => 'forger';

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    final q = TxtQueryWire.parseDnsQueryPacket(query);
    final chunk = TxtQueryWire.parseQueryName(q.name, _domain);
    final payload = TxtQueryWire.reassemble([chunk]);
    final group = payload.sublist(4, 12);
    final down = [
      0x50, 0x52, 0x42, 0x31, // "PRB1"
      ...group,
      ...List.filled(8, 0x42), // a nonce this run never generated
      1,
    ];
    return TxtQueryWire.buildDnsAnswerPacket(
      q.txid,
      q.name,
      TxtQueryWire.frameDown(down),
    );
  }

  @override
  Future<void> dispose() async {}
}
