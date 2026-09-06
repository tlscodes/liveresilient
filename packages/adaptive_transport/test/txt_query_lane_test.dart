import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

const String _domain = 'valve.example';

/// What this double answers a chunk with while a session is still
/// incomplete, and what it answers a payload too large to echo back.
///
/// It is the responder double's own convention, not a value the lane or
/// [TxtQueryWire] defines, so no assertion below compares against it — the
/// lane's contract is only that the answer's bytes are surfaced unframed.
const int _ack = 0x06;

/// An authoritative responder for [_domain] that never touches a socket.
///
/// Every exchange is parsed, accumulated and answered in memory on the
/// microtask queue, so a test here finishes as fast as the CPU can base32
/// decode and never depends on a port, a name server, or a timer. The
/// [Duration] the lane passes in is recorded rather than honoured: nothing
/// waits on it, but it is the lane's only per-query budget, so a test can
/// still pin the value that was plumbed through. Each failure the lane has
/// to survive is a plain field rather than a network condition a test would
/// otherwise have to arrange.
class _FakeResolver implements TxtQueryTransport {
  _FakeResolver(this.label, {this.failAt});

  @override
  final String label;

  /// Which exchanges fail, by their 0-based order on this resolver.
  ///
  /// Null answers everything; `(_) => true` is a resolver this network
  /// cannot reach at all; `(i) => i == 0` is one that drops the first query
  /// and recovers.
  bool Function(int index)? failAt;

  /// What a failing exchange throws. A timeout is the usual shape: a
  /// filtered UDP/53 does not refuse a query, it simply says nothing.
  Object failure = TimeoutException('no answer from the resolver');

  /// Answer with this rcode and no TXT record at all.
  int? rcode;

  /// Answer under a transaction id that is not the one that was asked for.
  bool corruptTxid = false;

  /// Answer with these bytes verbatim instead of a framed record — a
  /// resolver serving its own TXT record rather than the valve's.
  List<int>? plainTxt;

  /// Query names this resolver was asked, in order.
  final List<String> asked = <String>[];

  /// Transaction ids the queries carried, in order.
  final List<int> txids = <int>[];

  /// The per-query budget each exchange was handed, in order.
  final List<Duration> timeouts = <Duration>[];

  /// Payloads that arrived complete, in the order they completed.
  final List<Uint8List> delivered = <Uint8List>[];

  int disposeCalls = 0;

  final Map<String, List<ParsedTxtQuery>> _sessions =
      <String, List<ParsedTxtQuery>>{};

  @override
  Future<Uint8List> exchange(
    Uint8List query,
    int txid,
    Duration timeout,
  ) async {
    final question = TxtQueryWire.parseDnsQueryPacket(query);
    final index = asked.length;
    asked.add(question.name);
    txids.add(question.txid);
    timeouts.add(timeout);
    if (failAt?.call(index) ?? false) throw failure;

    final chunk = TxtQueryWire.parseQueryName(question.name, _domain);
    final session = _sessions.putIfAbsent(
      chunk.sessionId,
      () => <ParsedTxtQuery>[],
    );
    session.add(chunk);
    var carried = Uint8List.fromList(const <int>[_ack]);
    try {
      final payload = TxtQueryWire.reassemble(session);
      delivered.add(payload);
      _sessions.remove(chunk.sessionId);
      // A TXT answer has a budget, so a large upload is acknowledged
      // rather than echoed. That is the responder's rule, not the lane's.
      if (payload.isNotEmpty &&
          payload.length <= TxtQueryWire.downstreamBudget) {
        carried = payload;
      }
    } on TxtQueryWireException {
      // Chunks are still missing: acknowledge this one and wait.
    }

    final plain = plainTxt;
    return TxtQueryWire.buildDnsAnswerPacket(
      corruptTxid ? question.txid ^ 0xFFFF : question.txid,
      question.name,
      rcode != null ? null : (plain ?? TxtQueryWire.frameDown(carried)),
      rcode: rcode ?? TxtQueryWire.rcodeNoError,
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}

/// A lane over fakes with every knob named explicitly, so a case reads
/// against the values it cares about rather than against a default.
///
/// [failWindow] is an hour unless a case is about the window itself, so no
/// ordinary assertion here moves with how long the suite takes to run. The
/// lane's own defaults are covered separately, by building a
/// [TxtQueryLane] with no optional arguments at all.
TxtQueryLane _laneOver(
  List<TxtQueryTransport> transports, {
  String domain = _domain,
  int failThreshold = 5,
  Duration failWindow = const Duration(hours: 1),
  String name = 'dns-valve',
}) => TxtQueryLane(
  domain: domain,
  transports: transports,
  timeout: const Duration(seconds: 30),
  failThreshold: failThreshold,
  failWindow: failWindow,
  name: name,
);

/// A payload whose bytes are position-dependent, so a chunk that lands in
/// the wrong order is visible in the reassembled result.
List<int> _payload(int length) =>
    List<int>.generate(length, (i) => (i * 7 + 11) & 0xFF);

/// The sequence numbers [names] carry, in the order they were asked.
List<int> _seqs(List<String> names) => <int>[
  for (final name in names) TxtQueryWire.parseQueryName(name, _domain).seq,
];

/// The session ids [names] carry, lowercased by the DNS name they travelled
/// in, which is why nothing here compares them to a lane field directly.
List<String> _sessionIds(List<String> names) => <String>[
  for (final name in names)
    TxtQueryWire.parseQueryName(name, _domain).sessionId,
];

void main() {
  group('what the registry sees', () {
    test('reports the lane name the fabric ranks it by', () {
      final named = _laneOver(<TxtQueryTransport>[
        _FakeResolver('a'),
      ], name: 'dns-valve-eu');

      expect(named.name, 'dns-valve-eu');
    });

    test(
      'an app that names no options gets the lane\'s own defaults',
      () async {
        final resolver = _FakeResolver('a');
        // The only lane in this file built with no optional arguments: every
        // other case goes through _laneOver, which supplies its own values,
        // so without this one the constructor's defaults are unexercised.
        final lane = TxtQueryLane(
          domain: _domain,
          transports: <TxtQueryTransport>[resolver],
        );
        addTearDown(lane.dispose);

        await lane.send(_payload(10));

        expect(lane.name, 'dns-valve');
        expect(lane.failThreshold, 5);
        expect(lane.failWindow, const Duration(seconds: 60));
        expect(resolver.timeouts, hasLength(1));
        expect(resolver.timeouts, everyElement(const Duration(seconds: 4)));
      },
    );

    test('is a TransportChannel with a low-bandwidth fallback health', () {
      final lane = _laneOver(<TxtQueryTransport>[_FakeResolver('a')]);

      expect(lane, isA<TransportChannel>());
      // The ladder ranks this lane last on purpose: one round trip per 39
      // bytes is a real path, but never a preferred one.
      expect(lane.health.reliabilityPrior, 0.4);
      expect(lane.health.bandwidth, 0.05);
      expect(lane.health.pathDegraded, isFalse);
      expect(lane.health.score(), greaterThan(0.0));
    });

    test('starts on the first candidate in the list it was given', () {
      final first = _FakeResolver('udp53:first');
      final second = _FakeResolver('udp53:second');

      final lane = _laneOver(<TxtQueryTransport>[first, second]);

      expect(lane.currentTransport, same(first));
      expect(lane.currentTransport.label, 'udp53:first');
    });

    test('starts with nothing sent and nothing claimed', () {
      final lane = _laneOver(<TxtQueryTransport>[_FakeResolver('a')]);

      expect(lane.attempts, 0);
      expect(lane.replies, 0);
      expect(lane.lastReply, isNull);
      expect(lane.lastSessionId, isNull);
      expect(lane.isDown, isFalse);
    });
  });

  group('configuration', () {
    test('a valve without a zone cannot produce a lane', () {
      expect(const TxtQueryValve(domain: '').isUsable, isFalse);
      expect(const TxtQueryValve(domain: '   ').isUsable, isFalse);
      expect(const TxtQueryValve(domain: _domain).isUsable, isTrue);
    });

    test('the lane refuses a zone that is blank', () {
      // The domain is the whole address of this lane: without it there is
      // nothing to aim a query at, so it fails at construction rather than
      // producing a lane that can only ever fail.
      expect(
        () => _laneOver(<TxtQueryTransport>[_FakeResolver('a')], domain: ''),
        throwsArgumentError,
      );
      expect(
        () => _laneOver(<TxtQueryTransport>[_FakeResolver('a')], domain: '  '),
        throwsArgumentError,
      );
    });

    test('the lane refuses to exist with nowhere to send', () {
      expect(() => _laneOver(<TxtQueryTransport>[]), throwsArgumentError);
    });

    test('the lane refuses a failure threshold below one', () {
      expect(
        () => _laneOver(<TxtQueryTransport>[
          _FakeResolver('a'),
        ], failThreshold: 0),
        throwsArgumentError,
      );
    });

    test('forValve keeps UDP ahead of DNS over HTTPS', () {
      // Explicit candidates only: what this device's resolv.conf happens to
      // say is the app-level test's business, not this one's.
      final lane = TxtQueryLane.forValve(
        TxtQueryValve(
          domain: _domain,
          resolvers: const <HostPort>[
            HostPort(host: '192.0.2.10', port: 53),
            HostPort(host: '192.0.2.11', port: 5353),
          ],
          dohEndpoints: <Uri>[Uri.parse('https://dns.example/dns-query')],
        ),
      );
      addTearDown(lane.dispose);

      // Port 53 first because a captive network usually still forwards it,
      // then RFC 8484 for a network that filters port 53 outright.
      expect(lane.currentTransport.label, 'udp53:192.0.2.10:53');
      expect(lane.domain, _domain);
      expect(lane.isDown, isFalse);
    });

    test(
      'forValve on an unusable valve refuses instead of building a lane',
      () {
        expect(
          () => TxtQueryLane.forValve(
            const TxtQueryValve(
              domain: '   ',
              resolvers: <HostPort>[HostPort(host: '192.0.2.10', port: 53)],
            ),
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('payload size', () {
    test(
      'carries a payload of exactly the limit, one chunk at a time',
      () async {
        final resolver = _FakeResolver('a');
        final lane = _laneOver(<TxtQueryTransport>[resolver]);
        addTearDown(lane.dispose);
        final payload = _payload(TxtQueryLane.maxPayloadBytes);

        final result = await lane.send(payload);

        expect(result.status, SendStatus.ok);
        expect(result.delivered, isTrue);
        expect(resolver.delivered.single, payload);
        // ceil((4096 + 2) / 39) = 106 round trips, which is why this lane
        // sits last in the ladder.
        expect(lane.attempts, 106);
        expect(lane.replies, 106);
        expect(_seqs(resolver.asked), List<int>.generate(106, (i) => i));
        // Too large to echo inside a TXT answer, so the responder answered
        // with its own short record. What the lane owes is that the last
        // answer's bytes are surfaced unframed, whatever they say — the
        // record's content is the responder's business, not the lane's.
        expect(lane.lastReply, hasLength(1));
      },
    );

    test('a payload past the limit is refused before the wire', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(
        _payload(TxtQueryLane.maxPayloadBytes + 1),
      );

      // Transient, not unavailable: the selector should hand the frame to a
      // lane that can carry it, not write this path off.
      expect(result.status, SendStatus.transient);
      expect(result.delivered, isFalse);
      expect(result.error, isA<ArgumentError>());
      expect(resolver.asked, isEmpty);
      expect(lane.attempts, 0);
      // The refusal says nothing about the path, so health is untouched.
      expect(lane.health.availability, 1.0);
      expect(lane.health.pathDegraded, isFalse);
      expect(lane.health.rttMs, 9999);
    });

    test('a payload costs ceil((n + 2) / 39) queries', () async {
      const costs = <int, int>{0: 1, 1: 1, 37: 1, 38: 2, 100: 3, 500: 13};

      for (final entry in costs.entries) {
        final resolver = _FakeResolver('a');
        final lane = _laneOver(<TxtQueryTransport>[resolver]);
        addTearDown(lane.dispose);

        final result = await lane.send(_payload(entry.key));

        expect(result.status, SendStatus.ok, reason: 'payload ${entry.key}');
        expect(lane.attempts, entry.value, reason: 'payload ${entry.key}');
        expect(resolver.delivered.single, _payload(entry.key));
      }
    });

    test('an element outside a byte is truncated, not refused', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(const <int>[0x101, -1, 0xFF, 256]);

      // send() takes a List<int> and the framing copies it into a
      // Uint8List, so anything outside 0..255 silently loses its high
      // bits. Measured and pinned here because a caller cannot see it
      // happen: the send reports ok and the wrong bytes arrive.
      expect(result.status, SendStatus.ok);
      expect(resolver.delivered.single, <int>[0x01, 0xFF, 0xFF, 0x00]);
    });

    test('a probe is one query and carries no payload', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      expect(await lane.probe(), isTrue);
      expect(lane.attempts, 1);
      expect(resolver.delivered.single, isEmpty);
    });
  });

  group('one payload, one session', () {
    test(
      'every query of a payload carries the session the lane reports',
      () async {
        final resolver = _FakeResolver('a');
        final lane = _laneOver(<TxtQueryTransport>[resolver]);
        addTearDown(lane.dispose);

        await lane.send(_payload(100));

        final reported = lane.lastSessionId;
        // The id is random, so only its shape and its reach are assertable:
        // six characters of the wire's base32 alphabet, on every query of
        // this payload and no other value.
        expect(reported, matches(RegExp(r'^[A-Z2-7]{6}$')));
        expect(resolver.asked, hasLength(3));
        expect(
          _sessionIds(resolver.asked),
          everyElement(reported!.toLowerCase()),
        );
      },
    );

    test('the chunks go out in sequence order from zero', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      await lane.send(_payload(200));

      expect(_seqs(resolver.asked), <int>[0, 1, 2, 3, 4, 5]);
    });

    test('every query is handed the lane\'s per-query budget', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      await lane.send(_payload(100));

      // This Duration is the only deadline a query gets — the lane has no
      // retry of its own — so a build that passed the wrong field, or
      // Duration.zero, is invisible without asserting the value here.
      expect(resolver.timeouts, hasLength(3));
      expect(resolver.timeouts, everyElement(const Duration(seconds: 30)));
    });

    test('the transaction id is drawn fresh for every query', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      await lane.send(_payload(1200));

      // 31 queries in one session, so a lane that drew one id per payload
      // — or reused a constant — fails here. The values come from the
      // platform CSPRNG per RFC 5452, so the assertion is on spread, not
      // on any value: 31 identical draws has probability (1/65536)^30.
      // Demanding full distinctness would be the flaky version of this.
      expect(resolver.txids, hasLength(31));
      expect(resolver.txids.toSet().length, greaterThan(1));
    });

    test(
      'the framed answer is what the lane reports as the last reply',
      () async {
        final resolver = _FakeResolver('a');
        final lane = _laneOver(<TxtQueryTransport>[resolver]);
        addTearDown(lane.dispose);
        final payload = _payload(60);

        final result = await lane.send(payload);

        expect(result.status, SendStatus.ok);
        // The responder echoed the payload it reassembled; the lane strips
        // the downstream frame and hands the bytes up.
        expect(lane.lastReply, payload);
      },
    );

    test('an answer that is not framed is still an answer', () async {
      final resolver = _FakeResolver('a')
        ..plainTxt = const <int>[0x76, 0x3D, 0x73, 0x70, 0x66, 0x31];
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(10));

      // A resolver serving an ordinary TXT record has still answered: the
      // lane hands the bytes up rather than calling the path broken.
      expect(result.status, SendStatus.ok);
      expect(lane.lastReply, <int>[0x76, 0x3D, 0x73, 0x70, 0x66, 0x31]);
      expect(lane.replies, 1);
    });

    test('a delivered payload leaves the path healthy and timed', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(10));

      expect(result.rttMs, isNotNull);
      expect(lane.health.availability, 1.0);
      expect(lane.health.pathDegraded, isFalse);
      // The prior is the pessimistic default; one delivery moves it, which
      // is what proves the sample reached observe().
      expect(lane.health.rttMs, lessThan(9999));
      expect(lane.health.score(), greaterThan(0.0));
    });
  });

  group('when the path fails', () {
    test('a first-chunk failure rotates and re-sends the same chunk', () async {
      final filtered = _FakeResolver('udp53:filtered', failAt: (i) => i == 0);
      final open = _FakeResolver('udp53:open');
      final lane = _laneOver(<TxtQueryTransport>[filtered, open]);
      addTearDown(lane.dispose);
      final payload = _payload(100);

      final result = await lane.send(payload);

      // The first chunk is the probe: one failure costs a rotation, not the
      // payload. Chunk zero is safe to re-send because the responder keys
      // chunks by sequence number.
      expect(result.status, SendStatus.ok);
      expect(filtered.asked, hasLength(1));
      expect(open.asked, hasLength(3));
      expect(open.asked.first, filtered.asked.single);
      expect(open.delivered.single, payload);
      expect(lane.currentTransport, same(open));
      expect(lane.attempts, 4);
      // Only the final result is observed, so a recovered rotation leaves
      // no mark on the lane's health.
      expect(lane.health.availability, 1.0);
    });

    test('every candidate is tried once before the send is given up', () async {
      final a = _FakeResolver('a', failAt: (_) => true);
      final b = _FakeResolver('b', failAt: (_) => true);
      final c = _FakeResolver('c', failAt: (_) => true);
      final lane = _laneOver(<TxtQueryTransport>[a, b, c]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(100));

      expect(result.status, SendStatus.transient);
      expect(result.error, same(c.failure));
      expect(a.asked, hasLength(1));
      expect(b.asked, hasLength(1));
      expect(c.asked, hasLength(1));
      expect(lane.attempts, 3);
      // Three failures, threshold five: still a live lane, just a failed
      // send, and the next one starts on the candidate after the last.
      expect(lane.isDown, isFalse);
      expect(lane.currentTransport, same(a));
      expect(lane.health.availability, closeTo(0.7, 1e-9));
      expect(lane.health.pathDegraded, isFalse);
    });

    test('a failure after the first chunk is not retried elsewhere', () async {
      final dies = _FakeResolver('dies', failAt: (i) => i >= 1);
      final spare = _FakeResolver('spare');
      final lane = _laneOver(<TxtQueryTransport>[dies, spare]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(100));

      // Past chunk zero the session has state on the far side, so the lane
      // gives the send up rather than restarting it on another resolver.
      expect(result.status, SendStatus.transient);
      expect(result.error, same(dies.failure));
      expect(dies.asked, hasLength(2));
      expect(spare.asked, isEmpty);
      expect(lane.attempts, 2);
      // One of the two queries was answered: that is what separates this
      // from a session where nothing arrived at all.
      expect(lane.replies, 1);
      // It still rotates, so the next payload starts on the spare.
      expect(lane.currentTransport, same(spare));
    });

    test('an answer under the wrong transaction id is not an answer', () async {
      final resolver = _FakeResolver('a')..corruptTxid = true;
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(10));

      expect(result.status, SendStatus.transient);
      expect(result.error, isA<TxtQueryWireException>());
      expect(lane.attempts, 1);
      expect(lane.replies, 0);
      expect(lane.lastReply, isNull);
    });

    test(
      'an error rcode carries nothing and counts as a path failure',
      () async {
        final resolver = _FakeResolver('a')..rcode = TxtQueryWire.rcodeNxDomain;
        final lane = _laneOver(<TxtQueryTransport>[resolver]);
        addTearDown(lane.dispose);

        final result = await lane.send(_payload(10));

        expect(result.status, SendStatus.transient);
        expect(result.error, isA<TxtQueryWireException>());
        expect(lane.attempts, 1);
        expect(lane.replies, 0);
        expect(lane.lastReply, isNull);
      },
    );

    test('a NOERROR answer with no TXT record is also a failure', () async {
      // NODATA, or a CNAME-only answer the parser walks past: the resolver
      // is healthy and the record simply is not there. This is the other
      // clause of the lane's guard, and an error rcode never reaches it.
      final resolver = _FakeResolver('a')..rcode = TxtQueryWire.rcodeNoError;
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);

      final result = await lane.send(_payload(10));

      expect(result.status, SendStatus.transient);
      expect(result.error, isA<TxtQueryWireException>());
      // Pinned rather than endorsed: the message an operator reads for a
      // missing record says "rcode=0", which is DNS for "no error".
      expect(result.error.toString(), contains('rcode=0'));
      expect(lane.attempts, 1);
      expect(lane.replies, 0);
      expect(lane.lastReply, isNull);
    });

    test(
      'the threshold declares the valve DOWN and zeroes its score',
      () async {
        final resolver = _FakeResolver('a', failAt: (_) => true);
        final lane = _laneOver(<TxtQueryTransport>[resolver], failThreshold: 2);
        addTearDown(lane.dispose);

        final first = await lane.send(_payload(10));
        final second = await lane.send(_payload(10));

        expect(first.status, SendStatus.transient);
        expect(lane.isDown, isTrue);
        expect(second.status, SendStatus.unavailable);
        expect(second.error, isA<StateError>());
        expect((second.error! as StateError).message, contains('DOWN'));
        // unavailable is what marks the path degraded, which is what drops
        // the lane to the bottom of the ranking.
        expect(lane.health.pathDegraded, isTrue);
        expect(lane.health.score(), 0.0);
      },
    );

    test('five failures is the threshold an app gets by default', () async {
      final resolver = _FakeResolver('a', failAt: (_) => true);
      final lane = TxtQueryLane(
        domain: _domain,
        transports: <TxtQueryTransport>[resolver],
      );
      addTearDown(lane.dispose);
      final down = <bool>[];

      for (var i = 0; i < 5; i++) {
        await lane.send(_payload(10));
        down.add(lane.isDown);
      }

      // The default window is a minute and these five sends are microtask
      // work against a fake, so nothing here is pruned by elapsed time.
      expect(down, <bool>[false, false, false, false, true]);
    });

    test(
      'the failure window slides: a pruned failure does not count',
      () async {
        final resolver = _FakeResolver('a', failAt: (_) => true);
        final lane = _laneOver(
          <TxtQueryTransport>[resolver],
          failThreshold: 2,
          failWindow: Duration.zero,
        );
        addTearDown(lane.dispose);

        for (var i = 0; i < 5; i++) {
          expect((await lane.send(_payload(500))).status, SendStatus.transient);
        }

        // A zero-length window holds only the failure being recorded, so five
        // consecutive failures never reach a threshold of two. Written this
        // way because the difference between a sliding window and a lifetime
        // counter is invisible while every case uses an hour-long window: as
        // a counter, the second send here would already be DOWN. Each send
        // encodes a 500-byte payload into 13 query names before it fails, so
        // the clock has moved well past the previous failure by the time the
        // next one is recorded.
        expect(lane.isDown, isFalse);
        expect(lane.attempts, 5);
      },
    );

    test('DOWN is terminal: a DOWN lane never queries again', () async {
      final resolver = _FakeResolver('a', failAt: (_) => true);
      final lane = _laneOver(<TxtQueryTransport>[resolver], failThreshold: 1);
      addTearDown(lane.dispose);

      await lane.send(_payload(10));
      expect(lane.isDown, isTrue);
      final queriesWhenDown = resolver.asked.length;

      final after = await lane.send(_payload(10));

      expect(after.status, SendStatus.unavailable);
      expect(await lane.probe(), isFalse);
      expect(resolver.asked, hasLength(queriesWhenDown));
      expect(lane.attempts, queriesWhenDown);
    });

    test('a delivered payload clears the failures behind it', () async {
      // Exchange 1 is the only one that answers, so the window holds one
      // failure, then is cleared, then holds one again.
      final resolver = _FakeResolver('a', failAt: (i) => i != 1);
      final lane = _laneOver(<TxtQueryTransport>[resolver], failThreshold: 2);
      addTearDown(lane.dispose);

      expect((await lane.send(_payload(10))).status, SendStatus.transient);
      expect((await lane.send(_payload(10))).status, SendStatus.ok);
      final third = await lane.send(_payload(10));

      // Without the clear this third failure would be the second in the
      // window and the valve would already be DOWN.
      expect(third.status, SendStatus.transient);
      expect(lane.isDown, isFalse);

      final fourth = await lane.send(_payload(10));

      expect(fourth.status, SendStatus.unavailable);
      expect(lane.isDown, isTrue);
    });

    test('a failed send moves the session id but not the last reply', () async {
      final resolver = _FakeResolver('a', failAt: (i) => i >= 1);
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);
      final first = _payload(10);

      expect((await lane.send(first)).status, SendStatus.ok);
      final deliveredSession = lane.lastSessionId;
      final second = await lane.send(_payload(12));

      // Measured, and a hazard rather than a promise: the session id is
      // set before the first query of a payload and the reply only on
      // success, so after a failed send the two fields describe different
      // payloads, and a caller that reads lastReply gets the previous
      // payload's bytes with nothing marking them stale.
      expect(second.status, SendStatus.transient);
      expect(lane.lastSessionId, isNot(deliveredSession));
      expect(lane.lastSessionId, matches(RegExp(r'^[A-Z2-7]{6}$')));
      expect(lane.lastReply, first);
    });
  });

  group('lifecycle', () {
    test('send after dispose is refused without touching the path', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);

      await lane.dispose();
      final result = await lane.send(_payload(10));

      expect(result.status, SendStatus.unavailable);
      expect(result.error, isA<StateError>());
      expect((result.error! as StateError).message, contains('disposed'));
      expect(resolver.asked, isEmpty);
      // A disposed lane says nothing about the network, so health is left
      // exactly as it was.
      expect(lane.health.availability, 1.0);
      expect(lane.health.pathDegraded, isFalse);
    });

    test('dispose releases every transport exactly once', () async {
      final a = _FakeResolver('a');
      final b = _FakeResolver('b');
      final c = _FakeResolver('c');
      final lane = _laneOver(<TxtQueryTransport>[a, b, c]);

      await lane.dispose();

      expect(a.disposeCalls, 1);
      expect(b.disposeCalls, 1);
      expect(c.disposeCalls, 1);
    });

    test('a second dispose fans out to the transports again', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);

      await lane.dispose();
      await lane.dispose();

      // Measured and unstated: dispose() is idempotent for the lane, which
      // stays refusing sends, but not for what it holds. Harmless against
      // the real transports, which close an already-closed socket or
      // client, but a caller cannot read that off the contract.
      expect(resolver.disposeCalls, 2);
      expect((await lane.send(_payload(10))).status, SendStatus.unavailable);
    });

    test('one payload at a time: two sends do not interleave', () async {
      final resolver = _FakeResolver('a');
      final lane = _laneOver(<TxtQueryTransport>[resolver]);
      addTearDown(lane.dispose);
      final first = _payload(100);
      final second = _payload(101);

      final results = await Future.wait(<Future<SendResult>>[
        lane.send(first),
        lane.send(second),
      ]);

      expect(results.map((r) => r.status), everyElement(SendStatus.ok));
      // A session's chunks are ordered and the responder keys them by
      // sequence, so interleaving would show up here as 0, 0, 1, 1, 2, 2.
      expect(_seqs(resolver.asked), <int>[0, 1, 2, 0, 1, 2]);
      final sessions = _sessionIds(resolver.asked);
      expect(sessions.sublist(0, 3), everyElement(sessions.first));
      expect(sessions.sublist(3), everyElement(sessions[3]));
      expect(resolver.delivered, <List<int>>[first, second]);
    });
  });

  // DEFECT, not fixed here: TxtQueryLane checks that its zone is non-empty
  // but never that the zone can produce a legal query name, so a
  // misconfigured zone makes send() THROW instead of returning a
  // SendResult, and makes probe() throw instead of returning a bool. Both
  // escape their declared return types, and TransportChannel.send promises
  // a status to a fabric that does not catch.
  //
  // The call sits outside the try: txt_query_lane.dart:215 in _carry, and
  // txt_query_lane.dart:294 (probe) reaches the same line through send().
  // Measured against this file's fakes, with the lane constructed and the
  // resolver never reached:
  //
  //   domain 'valve..example'      send() THREW  bad label ""
  //                                probe() THREW bad label ""
  //                                resolver.asked.length == 0
  //   domain 'a' * 64 + '.example' send() and probe() both THREW
  //                                bad label "aaaa..."
  //   domain of 185 characters     send(_payload(39)) THREW FQDN 273 > 253
  //                                probe() survived, because an empty
  //                                payload's chunk label is short enough
  //                                to build a name under the limit
  //
  // So the trigger is a configuration typo that is fatal from the first
  // send, not only a long zone that fails once payloads grow: only the
  // third shape above hides until real traffic starts. The case below uses
  // the doubled dot for that reason. It asserts that both entry points
  // return rather than throw, and deliberately does not pin transient
  // against unavailable — which of those a config error deserves is the
  // fix's decision, and the source states neither today.
  //
  // test('a zone that cannot make a query name is refused, not thrown', () async {
  //   final resolver = _FakeResolver('a');
  //   final lane = _laneOver(
  //     <TxtQueryTransport>[resolver],
  //     domain: 'valve..example',
  //   );
  //   addTearDown(lane.dispose);
  //
  //   final result = await lane.send(_payload(39));
  //
  //   expect(result.delivered, isFalse);
  //   expect(await lane.probe(), isFalse);
  //   expect(resolver.asked, isEmpty);
  // });
}
