// The daily allowance of relay requests and the transport that counts
// against it, times every request and cuts it off at a hard limit. Servers
// on loopback stand in for the relay. Lab only.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/relay_requests.dart';

void main() {
  group("the day's allowance", () {
    test('counts every request, stops looking at its share and everything '
        'at the cap', () {
      final budget = RequestBudget(
        dailyCap: 10,
        lookShare: 0.5,
        clock: () => DateTime.utc(2026, 10, 6, 12),
      );
      expect(budget.lookCap, 5);
      for (var i = 0; i < 5; i++) {
        expect(budget.take(write: false), isTrue);
        budget.done(const Duration(milliseconds: 20));
      }
      expect(budget.take(write: false), isFalse, reason: 'its share is used');
      expect(budget.now.looksSpent, isTrue);
      expect(budget.now.spent, isFalse);
      for (var i = 0; i < 5; i++) {
        expect(budget.take(write: true), isTrue, reason: 'kept for writing');
        budget.done(Duration.zero);
      }
      expect(budget.take(write: true), isFalse);
      final count = budget.now;
      expect(count.usedToday, 10);
      expect(count.sinceStart, 10);
      expect(count.refusedToday, 2);
      expect(count.spent, isTrue);
      expect(count.openNow, 0);
      expect(count.longestOpen, const Duration(milliseconds: 20));
    });

    test('the next day (UTC) starts afresh', () {
      var now = DateTime.utc(2026, 10, 6, 23, 59, 59);
      final budget = RequestBudget(dailyCap: 2, clock: () => now);
      expect(budget.nextDay, DateTime.utc(2026, 10, 7));
      expect(budget.take(write: true), isTrue);
      expect(budget.take(write: true), isTrue);
      expect(budget.take(write: true), isFalse);
      now = DateTime.utc(2026, 10, 7, 0, 0, 1);
      expect(budget.now.usedToday, 0);
      expect(budget.now.refusedToday, 0);
      expect(budget.now.sinceStart, 2, reason: 'since start crosses midnight');
      expect(budget.take(write: true), isTrue);
    });

    test('the count outlives a relaunch, in one small file replaced whole', () {
      final dir = Directory.systemTemp.createTempSync('relay_requests_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      var now = DateTime.utc(2026, 10, 6, 12);
      RequestBudget launch() =>
          RequestBudget(clock: () => now, ledger: FileRequestLedger(() => dir));
      final file = File('${dir.path}/${FileRequestLedger.fileName}');

      final first = launch();
      expect(first.take(write: false), isTrue);
      expect(first.take(write: true), isTrue);
      expect(first.take(write: false), isTrue);
      expect((jsonDecode(file.readAsStringSync()) as Map)['used'], 3);
      expect(dir.listSync(), hasLength(1), reason: 'nothing half written');

      final second = launch();
      expect(second.now.usedToday, 3);
      expect(second.now.sinceStart, 0);

      // A file from another day is not today's count.
      now = DateTime.utc(2026, 10, 7, 12);
      expect(launch().now.usedToday, 0);

      // And a file that cannot be read is no count — not a crash.
      file.writeAsStringSync('{half');
      now = DateTime.utc(2026, 10, 6, 12);
      expect(launch().now.usedToday, 0);
    });
  });

  group('the counted transport', () {
    late HttpServer server;
    late Future<void> Function(HttpRequest request) answer;
    final seen = <String>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        try {
          await answer(request);
        } catch (_) {
          // The client hung up first: that is what some of these test.
        }
      });
    });

    tearDown(() => server.close(force: true));

    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    Future<void> notFound(HttpRequest request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }

    test('an answer is passed on, counted and timed', () async {
      answer = (request) async {
        if (request.uri.path != '/there') return notFound(request);
        await request.drain<void>();
        request.response.add([1, 2, 3]);
        await request.response.close();
      };
      final budget = RequestBudget();
      final ended = <({bool write, bool cut})>[];
      final transport = MeteredRelayTransport(
        budget: budget,
        onRequest: (open, {required write, required cut}) =>
            ended.add((write: write, cut: cut)),
      );
      addTearDown(transport.close);

      expect((await transport.get(at('/nothing'))).statusCode, 404);
      final there = await transport.get(at('/there'));
      expect(there.statusCode, 200);
      expect(there.body, [1, 2, 3]);
      final put = await transport.put(at('/there'), Uint8List.fromList([9]));
      expect(put.statusCode, 200);

      final count = budget.now;
      expect(count.usedToday, 3);
      expect(count.openNow, 0);
      expect(count.longestOpen, greaterThan(Duration.zero));
      expect(count.longestOpen, lessThan(const Duration(seconds: 2)));
      expect(ended.map((e) => e.write), [false, false, true]);
      expect(ended.every((e) => !e.cut), isTrue);
    });

    test('a request the allowance has no room for is never sent', () async {
      answer = notFound;
      final budget = RequestBudget(dailyCap: 1, lookShare: 1);
      final transport = MeteredRelayTransport(budget: budget);
      addTearDown(transport.close);
      await transport.get(at('/a'));
      await expectLater(
        transport.get(at('/b')),
        throwsA(isA<RequestBudgetSpent>()),
      );
      await expectLater(
        transport.put(at('/c'), Uint8List(1)),
        throwsA(isA<RequestBudgetSpent>()),
      );
      expect(seen, ['GET /a']);
      expect(budget.now.refusedToday, 2);
    });

    test('a relay that takes the request and does not answer is cut off at '
        'the limit: nothing is held open', () async {
      final silent = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(silent.close);
      final hungUp = Completer<void>();
      void gone() {
        if (!hungUp.isCompleted) hungUp.complete();
      }

      silent.listen((socket) {
        socket.listen(
          (_) {},
          onDone: () {
            gone();
            socket.destroy();
          },
          onError: (Object _) => gone(),
        );
      });
      final budget = RequestBudget();
      var cuts = 0;
      final transport = MeteredRelayTransport(
        budget: budget,
        probeLimit: const Duration(milliseconds: 300),
        onRequest: (open, {required write, required cut}) {
          if (cut) cuts++;
        },
      );
      addTearDown(transport.close);

      final waited = Stopwatch()..start();
      await expectLater(
        transport.get(Uri.parse('http://127.0.0.1:${silent.port}/a/feed/0')),
        throwsA(isA<TimeoutException>()),
      );
      expect(waited.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(cuts, 1);
      final count = budget.now;
      expect(count.openNow, 0);
      expect(count.usedToday, 1, reason: 'a request that was cut still counts');
      expect(
        count.longestOpen,
        greaterThanOrEqualTo(const Duration(milliseconds: 290)),
      );
      expect(count.longestOpen, lessThan(const Duration(milliseconds: 1500)));
      // And the connection is gone on the relay's side too.
      await hungUp.future.timeout(const Duration(seconds: 2));
    });

    test('a small request may not wait; a piece of media may, in proportion '
        'to its size', () async {
      answer = (request) async {
        await request.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      };
      final transport = MeteredRelayTransport(
        budget: RequestBudget(),
        probeLimit: const Duration(milliseconds: 200),
        slowestBytesPerSecond: 10000,
      );
      addTearDown(transport.close);
      await expectLater(
        transport.put(at('/o/small'), Uint8List(512)),
        throwsA(isA<TimeoutException>()),
      );
      // 40 000 bytes at 10 000 a second: 200 ms and about 3.6 s more.
      final piece = await transport.put(at('/o/piece'), Uint8List(40000));
      expect(piece.statusCode, HttpStatus.created);
    });

    test('a body over the ceiling is a refusal, not an exception', () async {
      answer = (request) async {
        await request.drain<void>();
        request.response.add(Uint8List(5000));
        await request.response.close();
      };
      final transport = MeteredRelayTransport(
        budget: RequestBudget(),
        maxResponseBytes: 1000,
      );
      addTearDown(transport.close);
      expect(
        (await transport.get(at('/o/huge'))).statusCode,
        HttpStatus.requestEntityTooLarge,
      );
    });

    test('a relay that cannot be reached fails as any transport does, and '
        'the try is counted', () async {
      final closed = await ServerSocket.bind('127.0.0.1', 0);
      final port = closed.port;
      await closed.close();
      final budget = RequestBudget();
      final transport = MeteredRelayTransport(budget: budget);
      addTearDown(transport.close);
      await expectLater(
        transport.get(Uri.parse('http://127.0.0.1:$port/a/feed/0')),
        throwsA(isA<SocketException>()),
      );
      expect(budget.now.usedToday, 1);
      expect(budget.now.openNow, 0);
    });
  });
}
