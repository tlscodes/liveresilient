import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

final Uri _endpoint = Uri.parse('https://dns.example/dns-query');

/// A DNS message the size of a header, carrying [txid] in the first two
/// bytes exactly where RFC 1035 puts it.
///
/// The transports under test never parse past those two bytes, so the rest
/// is filler that only proves the answer is handed back whole.
Uint8List _message(int txid, {int extra = 10}) {
  final bytes = Uint8List(2 + extra);
  bytes[0] = (txid >> 8) & 0xFF;
  bytes[1] = txid & 0xFF;
  for (var i = 2; i < bytes.length; i++) {
    bytes[i] = i & 0xFF;
  }
  return bytes;
}

/// Why the mode-000 case cannot run here, or null when it can.
///
/// `readAsStringSync` throws [FileSystemException] for exactly one input a
/// test can build: a file the running user may not read. Root may read it,
/// and `chmod` is POSIX, so both of those are honest skips rather than a
/// case quietly rewritten into one that always passes.
String? _unreadableFileSkip() {
  if (Platform.isWindows) return 'chmod is POSIX-only';
  final uid = Process.runSync('id', <String>['-u']).stdout.toString().trim();
  return uid == '0' ? 'root reads a mode-000 file' : null;
}

/// The headers a [_FakeRequest] records instead of writing them to a socket.
class _FakeHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  int contentLength = -1;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An [HttpClientResponse] built from a stream the test owns, so a body can
/// arrive in one piece, in chunks, as an error, or never.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.statusCode, required Stream<List<int>> body})
    : _body = body;

  @override
  final int statusCode;

  final Stream<List<int>> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what the RFC 8484 exchange wrote, and answers with whatever the
/// test handed it.
///
/// The `AtClose` fields are snapshots taken as the first thing [close] does,
/// because that is the only moment the ordering can still be observed: a
/// real `HttpClientRequest` throws on a write after `close()`, while a
/// double that answers unconditionally would let the wrong order pass.
class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._answer);

  final Future<HttpClientResponse> Function() _answer;
  final BytesBuilder _written = BytesBuilder();
  final _FakeHeaders recordedHeaders = _FakeHeaders();

  /// What had been written, and what the headers said, when [close] ran.
  Uint8List? writtenAtClose;
  int? contentLengthAtClose;
  Map<String, String>? headersAtClose;

  /// How many times the transport closed this request.
  int closeCount = 0;

  /// The bytes the transport pushed into the request body.
  Uint8List get written => Uint8List.fromList(_written.toBytes());

  @override
  HttpHeaders get headers => recordedHeaders;

  @override
  void add(List<int> data) => _written.add(data);

  @override
  Future<HttpClientResponse> close() {
    writtenAtClose = written;
    contentLengthAtClose = recordedHeaders.contentLength;
    headersAtClose = Map<String, String>.of(recordedHeaders.values);
    closeCount += 1;
    return _answer();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The seam [DohQueryTransport] takes: an [HttpClient] whose `postUrl` is
/// the test's, so the whole exchange runs with no socket anywhere.
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._open);

  final Future<HttpClientRequest> Function(Uri url) _open;

  /// Every endpoint a POST was aimed at, in order.
  final List<Uri> posted = <Uri>[];

  int closeCount = 0;
  bool closedWithForce = false;

  @override
  Future<HttpClientRequest> postUrl(Uri url) {
    posted.add(url);
    return _open(url);
  }

  @override
  void close({bool force = false}) {
    closeCount += 1;
    closedWithForce = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client that answers every POST with [status] and [chunks], appending
/// each request it was handed to [requests].
_FakeHttpClient _answering({
  required List<List<int>> chunks,
  int status = HttpStatus.ok,
  List<_FakeRequest>? requests,
}) => _FakeHttpClient((uri) async {
  final request = _FakeRequest(
    () async => _FakeResponse(
      statusCode: status,
      body: Stream<List<int>>.fromIterable(chunks),
    ),
  );
  requests?.add(request);
  return request;
});

/// A client whose POST never opens: a filtered path, not a refused one.
_FakeHttpClient _silentClient() =>
    _FakeHttpClient((uri) => Completer<HttpClientRequest>().future);

/// A client that opens at once and then never finishes the request, which
/// is the middle of the three timeout sites in `exchange`.
_FakeHttpClient _neverClosingClient() => _FakeHttpClient(
  (uri) async => _FakeRequest(() => Completer<HttpClientResponse>().future),
);

void main() {
  group('DohQueryTransport', () {
    test('label names the endpoint host', () {
      expect(DohQueryTransport(_endpoint).label, 'doh:dns.example');
      expect(
        DohQueryTransport(Uri.parse('https://1.1.1.1/dns-query')).label,
        'doh:1.1.1.1',
      );
    });

    test('carries the query out and the answer back', () async {
      final query = _message(0x1234);
      final answer = _message(0x1234, extra: 24);
      final requests = <_FakeRequest>[];
      final client = _answering(
        chunks: <List<int>>[answer],
        requests: requests,
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      final received = await transport.exchange(
        query,
        0x1234,
        const Duration(seconds: 4),
      );

      expect(received, answer);
      expect(client.posted, <Uri>[_endpoint]);
      expect(requests, hasLength(1));
      final recorded = requests.single;
      expect(recorded.closeCount, 1);
      // Asserted as of `close()`, so a body written after the close — which
      // a real request refuses — cannot pass this case.
      expect(recorded.writtenAtClose, query);
      expect(recorded.contentLengthAtClose, query.length);
      expect(
        recorded.headersAtClose?['content-type'],
        'application/dns-message',
      );
      expect(recorded.headersAtClose?['accept'], 'application/dns-message');
    });

    test('an answer split across chunks is joined before it is read', () async {
      final answer = _message(0x0abc, extra: 6);
      final client = _answering(
        chunks: <List<int>>[
          answer.sublist(0, 1),
          answer.sublist(1, 5),
          answer.sublist(5),
        ],
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      expect(
        await transport.exchange(
          _message(0x0abc),
          0x0abc,
          const Duration(seconds: 4),
        ),
        answer,
      );
    });

    test('an answer for a txid that was never sent is refused', () async {
      final client = _answering(chunks: <List<int>>[_message(0x1234)]);
      final transport = DohQueryTransport(_endpoint, client: client);

      await expectLater(
        transport.exchange(
          _message(0x5678),
          0x5678,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('4660'), contains('22136')),
          ),
        ),
      );
    });

    test('a failed exchange posts exactly once', () async {
      final requests = <_FakeRequest>[];
      final client = _answering(
        chunks: <List<int>>[_message(0x1234)],
        requests: requests,
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      await expectLater(
        transport.exchange(
          _message(0x5678),
          0x5678,
          const Duration(seconds: 4),
        ),
        throwsA(isA<HttpException>()),
      );

      // Retrying is the caller's decision — TxtQueryLane rotates transports
      // on a failure — so a transport that retried inside itself would spend
      // the lane's budget twice on the same dead path.
      expect(client.posted, <Uri>[_endpoint]);
      expect(requests, hasLength(1));
      expect(requests.single.closeCount, 1);
    });

    test('the txid is read big-endian, not byte-swapped', () async {
      final client = _answering(chunks: <List<int>>[_message(0x1234)]);
      final transport = DohQueryTransport(_endpoint, client: client);

      // A byte-swapped parse would read 0x3412 and return the answer. The
      // message is pinned so the case cannot be satisfied by the status or
      // short-body guard instead.
      await expectLater(
        transport.exchange(
          _message(0x3412),
          0x3412,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('txid 4660, wanted 13330'),
          ),
        ),
      );
    });

    test('the widest txid still matches', () async {
      final query = _message(0xFFFF, extra: 4);
      final answer = _message(0xFFFF, extra: 40);
      final client = _answering(chunks: <List<int>>[answer]);
      final transport = DohQueryTransport(_endpoint, client: client);

      final received = await transport.exchange(
        query,
        0xFFFF,
        const Duration(seconds: 4),
      );

      expect(received, answer);
      expect(received, isNot(query), reason: 'the answer is what comes back');
    });

    test('two bytes is the shortest answer that is accepted', () async {
      final client = _answering(
        chunks: <List<int>>[
          <int>[0x12, 0x34],
        ],
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      // The guard is `body.length < 2`; this pins the accepted side of that
      // boundary, so widening it to `<= 2` is a failure and not a no-op.
      expect(
        await transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        <int>[0x12, 0x34],
      );
    });

    test('a non-200 answer is a failure, not an answer', () async {
      final client = _answering(
        chunks: <List<int>>[_message(0x1234)],
        status: HttpStatus.badGateway,
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('502'),
          ),
        ),
      );
    });

    test('a failing status outranks a body too short to hold a txid', () async {
      final client = _answering(
        chunks: <List<int>>[
          <int>[0x12],
        ],
        status: HttpStatus.badGateway,
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      // Both guards fire on this response. The status is the one that
      // explains the failure to a caller, so it is the one reported.
      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('502'), isNot(contains('bytes'))),
          ),
        ),
      );
    });

    test('an answer too short to hold a txid is refused', () async {
      for (final short in <List<int>>[
        <int>[],
        <int>[0x12],
      ]) {
        final transport = DohQueryTransport(
          _endpoint,
          client: _answering(chunks: <List<int>>[short]),
        );
        await expectLater(
          transport.exchange(
            _message(0x1234),
            0x1234,
            const Duration(seconds: 4),
          ),
          throwsA(
            isA<HttpException>().having(
              (e) => e.message,
              'message',
              contains('answered ${short.length} bytes'),
            ),
          ),
        );
      }
    });

    test('a body that fails before its first byte surfaces that', () async {
      final client = _FakeHttpClient(
        (uri) async => _FakeRequest(
          () async => _FakeResponse(
            statusCode: HttpStatus.ok,
            body: Stream<List<int>>.error(
              const SocketException('connection reset'),
            ),
          ),
        ),
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('a body that fails mid-stream drops what it collected', () async {
      final answer = _message(0x1234, extra: 20);
      // A single-subscription controller buffers, so the four bytes are
      // delivered to the collector before the error is: this is a failure
      // with a partial buffer in hand, not one before the first byte.
      final body = StreamController<List<int>>();
      body.add(answer.sublist(0, 4));
      body.addError(const SocketException('reset mid-body'));
      final client = _FakeHttpClient(
        (uri) async => _FakeRequest(
          () async =>
              _FakeResponse(statusCode: HttpStatus.ok, body: body.stream),
        ),
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      // The partial bytes never reach the caller: `cancelOnError` ends the
      // subscription and the collected buffer goes with it.
      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'reset mid-body',
          ),
        ),
      );
    });

    test('a POST that is refused surfaces the socket failure', () async {
      final client = _FakeHttpClient(
        (uri) => Future<HttpClientRequest>.error(
          const SocketException('connection refused'),
        ),
      );
      final transport = DohQueryTransport(_endpoint, client: client);

      // Half of the documented contract: a path that failed shows up as a
      // SocketException, unwrapped, not as a timeout and not as an
      // HttpException.
      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'connection refused',
          ),
        ),
      );
    });

    test('dispose closes the injected client and refuses later work', () async {
      final client = _answering(chunks: <List<int>>[_message(0x1234)]);
      final transport = DohQueryTransport(_endpoint, client: client);

      await transport.dispose();

      expect(client.closeCount, 1);
      expect(client.closedWithForce, isTrue);
      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(isA<StateError>()),
      );
      expect(client.posted, isEmpty, reason: 'nothing may leave after dispose');
    });

    test('a POST that never opens times out at the caller budget', () {
      fakeAsync((async) {
        final transport = DohQueryTransport(_endpoint, client: _silentClient());
        Object? failure;
        unawaited(
          transport
              .exchange(_message(0x1234), 0x1234, const Duration(seconds: 2))
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );

        async.elapse(const Duration(milliseconds: 1999));
        expect(failure, isNull, reason: 'the budget has not run out yet');

        async.elapse(const Duration(milliseconds: 2));
        expect(failure, isA<TimeoutException>());
      });
    });

    test('a request that never closes times out at the caller budget', () {
      fakeAsync((async) {
        final client = _neverClosingClient();
        final transport = DohQueryTransport(_endpoint, client: client);
        Object? failure;
        unawaited(
          transport
              .exchange(_message(0x1234), 0x1234, const Duration(seconds: 2))
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );

        async.elapse(const Duration(milliseconds: 1999));
        expect(failure, isNull, reason: 'the budget has not run out yet');

        async.elapse(const Duration(milliseconds: 2));
        // The POST opened at once, so this budget can only have been spent
        // waiting on `request.close()`.
        expect(failure, isA<TimeoutException>());
        expect(client.posted, <Uri>[_endpoint]);
      });
    });

    test('a body that never ends times out and drops its subscription', () {
      fakeAsync((async) {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        final client = _FakeHttpClient(
          (uri) async => _FakeRequest(
            () async =>
                _FakeResponse(statusCode: HttpStatus.ok, body: body.stream),
          ),
        );
        final transport = DohQueryTransport(_endpoint, client: client);
        Object? failure;
        unawaited(
          transport
              .exchange(_message(0x1234), 0x1234, const Duration(seconds: 2))
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );

        async.elapse(const Duration(seconds: 3));

        expect(
          failure,
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('body timed out'),
          ),
        );
        expect(cancelled, isTrue, reason: 'a live body subscription leaked');
        // Closed inside the zone on purpose: a teardown would run outside
        // it, where nothing can drain the microtasks `close()` waits on.
        unawaited(body.close());
      });
    });

    // DEFECT, not fixed here: the caller's `timeout` is applied three times
    // over — once to `postUrl` (txt_query_transport.dart:160), once to
    // `request.close()` (:165) and once to the body (:166) — so one call to
    // `exchange` can take nearly 3x the budget its caller set, while
    // TxtQueryTransport.exchange (:20-24) promises a TimeoutException
    // "inside [timeout]". TxtQueryLane hands every attempt the same single
    // `_timeout` (txt_query_lane.dart:258), so a DoH transport in that
    // rotation can hold the lane roughly three times as long as the lane
    // budgeted for. Uncommenting this test fails today: the recorded
    // elapsed time is 2800ms against a 1000ms budget.
    //
    // test('the whole exchange fits inside the caller budget', () {
    //   fakeAsync((async) {
    //     const budget = Duration(seconds: 1);
    //     const slow = Duration(milliseconds: 900);
    //     final body = StreamController<List<int>>();
    //     final client = _FakeHttpClient(
    //       (uri) => Future<HttpClientRequest>.delayed(
    //         slow,
    //         () => _FakeRequest(
    //           () => Future<HttpClientResponse>.delayed(
    //             slow,
    //             () => _FakeResponse(
    //               statusCode: HttpStatus.ok,
    //               body: body.stream,
    //             ),
    //           ),
    //         ),
    //       ),
    //     );
    //     final transport = DohQueryTransport(_endpoint, client: client);
    //     Duration? finishedAt;
    //     unawaited(
    //       transport
    //           .exchange(_message(0x1234), 0x1234, budget)
    //           .then<void>(
    //             (_) => finishedAt = async.elapsed,
    //             onError: (Object _) => finishedAt = async.elapsed,
    //           ),
    //     );
    //     async.elapse(const Duration(seconds: 10));
    //     expect(finishedAt, isNotNull);
    //     expect(finishedAt! <= budget, isTrue, reason: 'budget overrun');
    //     unawaited(body.close());
    //   });
    // });

    // DEFECT, not fixed here: `exchange` collects the entire body
    // (txt_query_transport.dart:166) before it looks at `response.statusCode`
    // (:167). A failing status whose body never ends therefore costs the
    // whole caller budget and surfaces TimeoutException('doh:... body timed
    // out') instead of the HttpException the status check at :168 exists to
    // produce — and an endpoint that is refusing service is exactly the one
    // most likely to hang its body. Uncommenting this test fails today:
    // `failure` is still null at 1ms and is a TimeoutException at 2s.
    //
    // test('a failing status is reported before the body is spent', () {
    //   fakeAsync((async) {
    //     final body = StreamController<List<int>>();
    //     final client = _FakeHttpClient(
    //       (uri) async => _FakeRequest(
    //         () async => _FakeResponse(
    //           statusCode: HttpStatus.badGateway,
    //           body: body.stream,
    //         ),
    //       ),
    //     );
    //     final transport = DohQueryTransport(_endpoint, client: client);
    //     Object? failure;
    //     unawaited(
    //       transport
    //           .exchange(_message(0x1234), 0x1234, const Duration(seconds: 2))
    //           .then<void>((_) {}, onError: (Object error) => failure = error),
    //     );
    //
    //     async.elapse(const Duration(milliseconds: 1));
    //     expect(
    //       failure,
    //       isA<HttpException>().having(
    //         (e) => e.message,
    //         'message',
    //         contains('502'),
    //       ),
    //     );
    //     unawaited(body.close());
    //   });
    // });
  });

  // The rotation across transports is TxtQueryLane's job, not this file's:
  // `_rotateTransport` (txt_query_lane.dart:235) and the retry of chunk zero
  // are driven end to end in txt_query_lane_test.dart with injected fake
  // transports. A rotation helper defined in this file would only assert its
  // own for-loop, so what belongs here is the single-attempt contract each
  // transport owes that rotation — covered above by 'a failed exchange posts
  // exactly once'.

  group('Udp53QueryTransport', () {
    // Everything past the disposed guard binds a real socket, so the
    // datagram path — the source address and port filter at
    // txt_query_transport.dart:79-82, the short-datagram guard at :84, the
    // txid demux at :85-87, the short-send SocketException at :105-106 and
    // dispose completing pending callers at :117-121 — has no case here.
    // Reaching it needs a seam this class does not offer: a way to inject
    // the RawDatagramSocket, the way DohQueryTransport takes an HttpClient.

    test('label names the resolver authority', () {
      expect(
        Udp53QueryTransport(const HostPort(host: '1.1.1.1', port: 53)).label,
        'udp53:1.1.1.1:53',
      );
      expect(
        Udp53QueryTransport(const HostPort(host: '9.9.9.9', port: 5353)).label,
        'udp53:9.9.9.9:5353',
      );
      expect(
        Udp53QueryTransport(
          const HostPort(host: '2001:db8::53', port: 53),
        ).label,
        'udp53:[2001:db8::53]:53',
      );
    });

    test(
      'a disposed transport refuses to exchange, and binds nothing',
      () async {
        final transport = Udp53QueryTransport(
          const HostPort(host: '198.51.100.53', port: 53),
        );

        await transport.dispose();

        await expectLater(
          transport.exchange(
            _message(0x1234),
            0x1234,
            const Duration(seconds: 4),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('udp53:198.51.100.53:53'),
            ),
          ),
        );
      },
    );

    test('disposing twice leaves the transport disposed', () async {
      final transport = Udp53QueryTransport(
        const HostPort(host: '198.51.100.53', port: 53),
      );

      await transport.dispose();
      await transport.dispose();

      // The second dispose must not reset the flag the first one set, which
      // is the only way this case can tell a no-op from a revival.
      await expectLater(
        transport.exchange(
          _message(0x1234),
          0x1234,
          const Duration(seconds: 4),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('TxtQueryResolvers', () {
    test('the public resolvers are three port-53 literals in order', () {
      expect(TxtQueryResolvers.publicResolvers, <HostPort>[
        const HostPort(host: '1.1.1.1', port: 53),
        const HostPort(host: '8.8.8.8', port: 53),
        const HostPort(host: '9.9.9.9', port: 53),
      ]);
      for (final resolver in TxtQueryResolvers.publicResolvers) {
        expect(InternetAddress.tryParse(resolver.host), isNotNull);
        expect(resolver.port, 53);
      }
    });

    test('the DoH endpoints name two of the three public resolvers', () {
      // The doc comment calls these the endpoints "matching publicResolvers".
      // Pinning the hosts is what makes that claim checkable, and records
      // that 9.9.9.9 deliberately has no DoH entry.
      expect(
        TxtQueryResolvers.publicDohEndpoints.map((e) => e.host).toList(),
        <String>['cloudflare-dns.com', 'dns.google'],
      );
      for (final endpoint in TxtQueryResolvers.publicDohEndpoints) {
        expect(endpoint.scheme, 'https');
        expect(endpoint.path, '/dns-query');
      }
    });

    test('resolv.conf nameserver lines are kept in order', () {
      const body = '''
# generated by something
; a second comment style
domain example.org
search example.org corp.example.org
nameserver 192.0.2.53
nameserver 198.51.100.53
options ndots:2
''';

      expect(TxtQueryResolvers.parseResolvConf(body), <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
        const HostPort(host: '198.51.100.53', port: 53),
      ]);
    });

    test('a repeated nameserver is listed once', () {
      const body =
          'nameserver 192.0.2.53\n'
          'nameserver 198.51.100.53\n'
          'nameserver 192.0.2.53\n';

      expect(TxtQueryResolvers.parseResolvConf(body), <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
        const HostPort(host: '198.51.100.53', port: 53),
      ]);
    });

    test('lines that are not a usable nameserver are dropped', () {
      const body =
          'nameserver\n'
          'nameserver not-an-address\n'
          'nameserver 999.1.1.1\n'
          'nameserverish 192.0.2.53\n'
          '   \n'
          '\n'
          'nameserver 192.0.2.53 # trailing comment\n';

      expect(TxtQueryResolvers.parseResolvConf(body), <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
      ]);
    });

    test('tabs, CRLF and a capitalised directive still parse', () {
      const body =
          'NAMESERVER\t192.0.2.53\r\n'
          '\tnameserver   2001:db8::53\r\n';

      expect(TxtQueryResolvers.parseResolvConf(body), <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
        const HostPort(host: '2001:db8::53', port: 53),
      ]);
    });

    test('an empty resolv.conf yields nothing', () {
      expect(TxtQueryResolvers.parseResolvConf(''), isEmpty);
      expect(TxtQueryResolvers.parseResolvConf('\n\n'), isEmpty);
    });

    // DEFECT, not fixed here: `parseResolvConf` stores the text the file
    // used (txt_query_transport.dart:271) and dedupes on it (:272). Measured
    // on this SDK, `InternetAddress.address` hands back the exact string it
    // parsed for every accepted form — '2001:0DB8:0000:0000:0000:0000:0000:
    // 0053', '2001:DB8::53' and '192.000.002.053' all come back unchanged —
    // so `InternetAddress.tryParse` at :269 validates but never normalises.
    // One resolver written two legal ways therefore becomes two candidates,
    // each costing the lane a full timeout on a network where it is dead,
    // and `candidates()` cannot recognise such a form as a public resolver
    // it already holds. Uncommenting this test fails today: the result has
    // two entries, the first being the expanded literal.
    //
    // test('one IPv6 resolver written two ways is listed once', () {
    //   const body =
    //       'nameserver 2001:0DB8:0000:0000:0000:0000:0000:0053\n'
    //       'nameserver 2001:db8::53\n';
    //
    //   expect(TxtQueryResolvers.parseResolvConf(body), <HostPort>[
    //     const HostPort(host: '2001:db8::53', port: 53),
    //   ]);
    // });

    test('systemResolvers reads the file it is pointed at', () {
      final dir = Directory.systemTemp.createTempSync('txt_query_resolvers');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/resolv.conf')
        ..writeAsStringSync('nameserver 192.0.2.53\nnameserver 192.0.2.54\n');

      expect(TxtQueryResolvers.systemResolvers(path: file.path), <HostPort>[
        const HostPort(host: '192.0.2.53', port: 53),
        const HostPort(host: '192.0.2.54', port: 53),
      ]);
    });

    test('an absent resolv.conf is not an error', () {
      final dir = Directory.systemTemp.createTempSync('txt_query_resolvers');
      addTearDown(() => dir.deleteSync(recursive: true));

      // Two shapes of absence, both of which `existsSync` reports as false:
      // no such entry, and a path that is a directory.
      expect(
        TxtQueryResolvers.systemResolvers(path: '${dir.path}/absent.conf'),
        isEmpty,
      );
      expect(TxtQueryResolvers.systemResolvers(path: dir.path), isEmpty);
    });

    test(
      'a resolv.conf that cannot be read is not an error',
      () {
        final dir = Directory.systemTemp.createTempSync('txt_query_resolvers');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/resolv.conf')
          ..writeAsStringSync('nameserver 192.0.2.53\n');
        expect(
          Process.runSync('chmod', <String>['000', file.path]).exitCode,
          0,
        );
        addTearDown(() => Process.runSync('chmod', <String>['600', file.path]));

        // The file exists, so this is the one input that reaches
        // `readAsStringSync` and makes it throw FileSystemException — the
        // branch the absent cases above cannot enter.
        expect(TxtQueryResolvers.systemResolvers(path: file.path), isEmpty);
      },
      skip: _unreadableFileSkip(),
    );

    test('candidates put the system resolvers ahead of the public ones', () {
      expect(
        TxtQueryResolvers.candidates(
          system: <HostPort>[const HostPort(host: '192.0.2.53', port: 53)],
        ),
        <HostPort>[
          const HostPort(host: '192.0.2.53', port: 53),
          const HostPort(host: '1.1.1.1', port: 53),
          const HostPort(host: '8.8.8.8', port: 53),
          const HostPort(host: '9.9.9.9', port: 53),
        ],
      );
    });

    test('a public resolver the system already named is not repeated', () {
      expect(
        TxtQueryResolvers.candidates(
          system: <HostPort>[const HostPort(host: '8.8.8.8', port: 53)],
        ),
        <HostPort>[
          const HostPort(host: '8.8.8.8', port: 53),
          const HostPort(host: '1.1.1.1', port: 53),
          const HostPort(host: '9.9.9.9', port: 53),
        ],
      );
    });

    test('candidates hands back a fresh list, never the shared constant', () {
      final first = TxtQueryResolvers.candidates(system: <HostPort>[]);
      final second = TxtQueryResolvers.candidates(system: <HostPort>[]);

      expect(first, TxtQueryResolvers.publicResolvers);
      expect(identical(first, second), isFalse);
      expect(
        identical(first, TxtQueryResolvers.publicResolvers),
        isFalse,
        reason: 'a caller must not be able to mutate the shared list',
      );
      first.add(const HostPort(host: '192.0.2.53', port: 53));
      expect(TxtQueryResolvers.publicResolvers, hasLength(3));
    });

    // Not covered on purpose: `candidates()` with no `system:` argument
    // falls through to `systemResolvers()` on the default '/etc/resolv.conf'
    // (txt_query_transport.dart:279), so a case for it would assert on
    // whatever the machine running the suite happens to have configured.
    // Covering it honestly needs a seam — `candidates({List<HostPort>?
    // system, String resolvConfPath = '/etc/resolv.conf'})` — which is a
    // source change, so it is reported rather than worked around here.
  });
}
