/// The relay as a domestic host: one address, one port, two services.
///
/// Covers the two changes that let a single bound port answer BOTH an
/// ordinary HTTPS request and the WebSocket rendezvous:
///   * a non-upgrade `GET /` returns a small static page, any other
///     non-upgrade request returns 404, and the upgrade path is unchanged;
///   * the rendezvous emits `room_member_joined` on a new seat and
///     `room_rendezvous_complete` the moment a room holds two identities,
///     both rendered with a UTC ISO-8601 instant by the single formatter
///     [formatSignalingLogLine].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/frame_collector.dart';

/// Captures relay log events and lets a test await one by name, so no
/// assertion is paced by a fixed sleep (see support/frame_collector.dart for
/// why this package avoids settle delays).
class _LogCollector {
  final List<({String event, String? callId})> entries =
      <({String event, String? callId})>[];
  final List<(String, Completer<void>)> _waiters =
      <(String, Completer<void>)>[];

  void add(String event, {String? callId, Object? error}) {
    entries.add((event: event, callId: callId));
    _waiters.removeWhere((waiter) {
      if (waiter.$1 == event) {
        waiter.$2.complete();
        return true;
      }
      return false;
    });
  }

  int countOf(String event) =>
      entries.where((entry) => entry.event == event).length;

  Iterable<({String event, String? callId})> allOf(String event) =>
      entries.where((entry) => entry.event == event);

  Future<void> waitFor(String event) {
    if (countOf(event) > 0) return Future<void>.value();
    final completer = Completer<void>();
    _waiters.add((event, completer));
    return completer.future.timeout(
      frameWaitTimeout,
      onTimeout: () => fail(
        'Timed out waiting for log event $event; '
        'received so far: ${entries.map((e) => e.event).toList()}',
      ),
    );
  }
}

Future<void> main() async {
  late Directory certDir;
  late DevCertificateFiles certificate;

  setUpAll(() async {
    certDir = await Directory.systemTemp.createTemp('domestic_host_test_');
    certificate = await ensureDevCertificate(directoryPath: certDir.path);
  });

  tearDownAll(() async {
    await certDir.delete(recursive: true);
  });

  SecurityContext buildServerSecurityContext() => SecurityContext()
    ..useCertificateChain(certificate.certificatePath)
    ..usePrivateKey(certificate.privateKeyPath);

  /// Binds on an ephemeral port (`port: 0`, the library default) with a
  /// capturing log sink.
  Future<(SignalingRelayServer, _LogCollector)> startServer() async {
    final logs = _LogCollector();
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      logSink: logs.add,
    );
    addTearDown(server.close);
    return (server, logs);
  }

  HttpClient devHttpClient() {
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    addTearDown(() => client.close(force: true));
    return client;
  }

  Future<WebSocket> connectClient(int port) {
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return WebSocket.connect('wss://localhost:$port/', customClient: client);
  }

  String envelope(String callId, {String from = 'a', String body = 'hello'}) =>
      jsonEncode({'callId': callId, 'senderKeyId': '$from-key', 'body': body});

  group('non-upgrade requests on the rendezvous port', () {
    test('GET / answers 200 with a small static text/html page', () async {
      final (server, _) = await startServer();

      final request = await devHttpClient().getUrl(
        Uri.parse('https://localhost:${server.port}/'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(body, domesticHostPageHtml);
      expect(
        body,
        contains('This is an ordinary web page served by this host.'),
      );
      // Small and self-contained: no external references of any kind.
      expect(body.length, lessThan(512));
      expect(body, isNot(contains('http://')));
      expect(body, isNot(contains('https://')));
      expect(body, isNot(contains('<script')));
      expect(body, isNot(contains('<link')));
      expect(body, isNot(contains('<img')));
    });

    test('another non-upgrade path answers 404', () async {
      final (server, _) = await startServer();
      final client = devHttpClient();

      final other = await (await client.getUrl(
        Uri.parse('https://localhost:${server.port}/status'),
      )).close();
      await other.drain<void>();
      expect(other.statusCode, HttpStatus.notFound);

      // A non-GET method on '/' is also not the ordinary page.
      final posted = await (await client.postUrl(
        Uri.parse('https://localhost:${server.port}/'),
      )).close();
      await posted.drain<void>();
      expect(posted.statusCode, HttpStatus.notFound);
    });

    test('the WebSocket upgrade path still upgrades and pairs', () async {
      final (server, logs) = await startServer();

      final socket = await connectClient(server.port);
      addTearDown(() => socket.close());
      expect(socket.readyState, WebSocket.open);

      socket.add(envelope('call-upgrade', from: 'a'));
      await waitForActiveRooms(server, 1);
      await logs.waitFor('room_member_joined');
      expect(logs.countOf('room_member_joined'), 1);
    });
  });

  group('rendezvous instrumentation', () {
    test('a first join logs room_member_joined with the callId', () async {
      final (server, logs) = await startServer();

      final a = await connectClient(server.port);
      addTearDown(() => a.close());
      a.add(envelope('call-first', from: 'a'));
      await logs.waitFor('room_member_joined');

      expect(logs.countOf('room_member_joined'), 1);
      expect(logs.allOf('room_member_joined').single.callId, 'call-first');
      expect(logs.countOf('room_rendezvous_complete'), 0);
    });

    test(
      'the second distinct member logs room_rendezvous_complete once, '
      'a third does not log it again, and a re-join does not double-count',
      () async {
        final (server, logs) = await startServer();
        const callId = 'call-rendezvous';

        final a = await connectClient(server.port);
        addTearDown(() => a.close());
        a.add(envelope(callId, from: 'a'));
        await logs.waitFor('room_member_joined');
        expect(logs.countOf('room_rendezvous_complete'), 0);

        final b = await connectClient(server.port);
        addTearDown(() => b.close());
        b.add(envelope(callId, from: 'b'));
        await logs.waitFor('room_rendezvous_complete');

        expect(logs.countOf('room_member_joined'), 2);
        expect(logs.countOf('room_rendezvous_complete'), 1);
        expect(logs.allOf('room_rendezvous_complete').single.callId, callId);

        // A THIRD identity is refused (the room seats two), so the moment is
        // not re-stamped.
        final c = await connectClient(server.port);
        addTearDown(() => c.close());
        c.add(envelope(callId, from: 'c'));
        await logs.waitFor('room_rejected_full');
        expect(logs.countOf('room_rendezvous_complete'), 1);
        expect(logs.countOf('room_member_joined'), 2);

        // A RE-JOIN by an identity that already holds a seat takes no new
        // seat: it is a replacement, not a join, and no member count changes.
        final aAgain = await connectClient(server.port);
        addTearDown(() => aAgain.close());
        aAgain.add(envelope(callId, from: 'a'));
        await logs.waitFor('room_member_replaced');
        expect(logs.countOf('room_member_joined'), 2);
        expect(logs.countOf('room_rendezvous_complete'), 1);
      },
    );
  });

  group('log line format', () {
    test('every line carries a UTC ISO-8601 instant and the callId', () {
      final line = formatSignalingLogLine(
        'room_rendezvous_complete',
        callId: 'call-1',
        at: DateTime.utc(2026, 9, 5, 12, 34, 56, 789),
      );
      expect(
        line,
        '[signaling_server] at=2026-09-05T12:34:56.789Z '
        'room_rendezvous_complete callId=call-1',
      );
    });

    test('a local instant is rendered in UTC', () {
      final local = DateTime(2026, 9, 5, 12, 34, 56);
      final line = formatSignalingLogLine('room_member_joined', at: local);
      final at = line.split(' ')[1].substring('at='.length);
      expect(at, endsWith('Z'));
      expect(DateTime.parse(at), local.toUtc());
      expect(line, endsWith('room_member_joined'));
    });

    test('an error is appended after the event and callId', () {
      final line = formatSignalingLogLine(
        'socket_close_failed',
        callId: 'call-2',
        error: 'boom',
        at: DateTime.utc(2026, 9, 5),
      );
      expect(
        line,
        '[signaling_server] at=2026-09-05T00:00:00.000Z '
        'socket_close_failed callId=call-2 error=boom',
      );
    });
  });
}
