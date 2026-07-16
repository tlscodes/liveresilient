import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

const _settleDelay = Duration(milliseconds: 100);

Future<void> main() async {
  late Directory certDir;
  late DevCertificateFiles certificate;

  setUpAll(() async {
    certDir = await Directory.systemTemp.createTemp('abuse_controls_test_');
    certificate = await ensureDevCertificate(directoryPath: certDir.path);
  });

  tearDownAll(() async {
    await certDir.delete(recursive: true);
  });

  SecurityContext buildServerSecurityContext() => SecurityContext()
    ..useCertificateChain(certificate.certificatePath)
    ..usePrivateKey(certificate.privateKeyPath);

  Future<WebSocket> connectClient(int port) {
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return WebSocket.connect('wss://localhost:$port/', customClient: client);
  }

  String envelope(String callId, {String body = 'hello'}) =>
      jsonEncode({'callId': callId, 'body': body});

  /// Attaches a collector to [socket]; the returned future completes with
  /// the close code once the socket is closed by the server.
  ({List<String> messages, Future<int?> closeCode}) observe(WebSocket socket) {
    final messages = <String>[];
    final closed = Completer<int?>();
    socket.listen(
      (event) => messages.add(event as String),
      onDone: () => closed.complete(socket.closeCode),
    );
    return (
      messages: messages,
      closeCode: closed.future.timeout(const Duration(seconds: 5)),
    );
  }

  /// Connects two peers into [callId]'s room and drains the seed exchange.
  Future<
    ({
      WebSocket a,
      WebSocket b,
      List<String> aMessages,
      List<String> bMessages,
      Future<int?> aClose,
      Future<int?> bClose,
    })
  >
  connectAndPair(int port, String callId) async {
    final a = await connectClient(port);
    final b = await connectClient(port);
    final aObs = observe(a);
    final bObs = observe(b);

    a.add(envelope(callId, body: '__seed__'));
    b.add(envelope(callId, body: '__seed__'));
    await Future<void>.delayed(_settleDelay);

    aObs.messages.clear();
    bObs.messages.clear();

    return (
      a: a,
      b: b,
      aMessages: aObs.messages,
      bMessages: bObs.messages,
      aClose: aObs.closeCode,
      bClose: bObs.closeCode,
    );
  }

  test('config rejects non-sensical limits', () {
    expect(() => AbuseControlConfig(messagesPerSecond: 0), throwsArgumentError);
    expect(() => AbuseControlConfig(messageBurst: 0), throwsArgumentError);
    expect(
      () => AbuseControlConfig(maxNewCallIdsPerWindow: 0),
      throwsArgumentError,
    );
    expect(
      () => AbuseControlConfig(sessionWindow: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => AbuseControlConfig(
        sessionWindow: const Duration(minutes: 10),
        rejoinWindow: const Duration(minutes: 1),
      ),
      throwsArgumentError,
    );
    expect(
      () => AbuseControlConfig(maxConcurrentRoomsGlobal: 0),
      throwsArgumentError,
    );
    expect(
      () => AbuseControlConfig(maxConcurrentRoomsPerSource: 0),
      throwsArgumentError,
    );
    expect(() => AbuseControlConfig(maxFrameBytes: 0), throwsArgumentError);
    expect(
      () => AbuseControlConfig(idleRoomTtl: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => AbuseControlConfig(sweepInterval: Duration.zero),
      throwsArgumentError,
    );
    // Defaults are valid.
    expect(AbuseControlConfig().messagesPerSecond, greaterThan(0));
  });

  test('flooding socket is closed with rate-limit code while a legit pair '
      'keeps relaying', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      abuseControls: AbuseControlConfig(messagesPerSecond: 1, messageBurst: 5),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'legit-call');

    final flooder = await connectClient(server.port);
    final flooderObs = observe(flooder);
    for (var i = 0; i < 50; i++) {
      flooder.add(envelope('flood-call', body: 'spam-$i'));
    }

    final code = await flooderObs.closeCode;
    expect(code, rateLimitCloseCode);
    expect(server.counters.rateLimitDisconnects, 1);

    // The legit pair (its own buckets) is unaffected.
    pair.a.add(envelope('legit-call', body: 'still-works'));
    await Future<void>.delayed(_settleDelay);
    expect(pair.bMessages, [envelope('legit-call', body: 'still-works')]);
    expect(server.counters.connectionsTotal, 3);

    await pair.a.close();
    await pair.b.close();
  });

  test('invite spam (many new callIds from one source) is blocked', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      abuseControls: AbuseControlConfig(maxNewCallIdsPerWindow: 3),
    );
    addTearDown(server.close);

    final within = <WebSocket>[];
    for (var i = 1; i <= 3; i++) {
      final socket = await connectClient(server.port);
      within.add(socket);
      socket.add(envelope('spam-$i'));
    }
    await Future<void>.delayed(_settleDelay);
    expect(server.activeRooms, 3);

    final fourth = await connectClient(server.port);
    final fourthObs = observe(fourth);
    fourth.add(envelope('spam-4'));
    expect(await fourthObs.closeCode, sessionLimitCloseCode);

    final fifth = await connectClient(server.port);
    final fifthObs = observe(fifth);
    fifth.add(envelope('spam-5'));
    expect(await fifthObs.closeCode, sessionLimitCloseCode);

    expect(server.counters.sessionLimitRejections, 2);
    expect(server.activeRooms, 3);

    for (final socket in within) {
      await socket.close();
    }
  });

  test(
    'legit reconnect to the same callId within the window is accepted and '
    'the new pair relays (state not corrupted by duplicate signaling)',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
        abuseControls: AbuseControlConfig(maxNewCallIdsPerWindow: 1),
      );
      addTearDown(server.close);

      // First pair consumes the single new-callId slot for this source.
      final first = await connectAndPair(server.port, 'call-reconnect');

      // Caller drops; the relay tears the room down and closes the peer.
      await first.a.close();
      expect(await first.bClose, peerDisconnectedCloseCode);
      await Future<void>.delayed(_settleDelay);
      expect(server.activeRooms, 0);

      // Reconnect to the SAME callId: must be admitted (rejoin is free) and
      // the rebuilt pair must relay both directions.
      final second = await connectAndPair(server.port, 'call-reconnect');
      second.a.add(envelope('call-reconnect', body: 'after-reconnect'));
      second.b.add(envelope('call-reconnect', body: 'reply'));
      await Future<void>.delayed(_settleDelay);
      expect(second.bMessages, [
        envelope('call-reconnect', body: 'after-reconnect'),
      ]);
      expect(second.aMessages, [envelope('call-reconnect', body: 'reply')]);
      expect(server.counters.sessionLimitRejections, 0);

      // A genuinely NEW callId from the same source is still limited,
      // proving the reconnect above went through the active limiter.
      final fresh = await connectClient(server.port);
      final freshObs = observe(fresh);
      fresh.add(envelope('call-brand-new'));
      expect(await freshObs.closeCode, sessionLimitCloseCode);
      expect(server.counters.sessionLimitRejections, 1);

      await second.a.close();
      await second.b.close();
    },
  );

  test(
    'frame above configured max size is rejected before buffering',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
        abuseControls: AbuseControlConfig(maxFrameBytes: 1024),
      );
      addTearDown(server.close);

      final pair = await connectAndPair(server.port, 'call-size');

      pair.a.add(envelope('call-size', body: 'x' * 2048));
      await Future<void>.delayed(_settleDelay);
      expect(pair.bMessages, isEmpty);
      expect(server.counters.oversizedFramesDropped, 1);

      // Connection stays alive per the relay's drop-not-close frame semantics.
      pair.a.add(envelope('call-size', body: 'small'));
      await Future<void>.delayed(_settleDelay);
      expect(pair.bMessages, [envelope('call-size', body: 'small')]);

      await pair.a.close();
      await pair.b.close();
    },
  );

  test('idle room is reaped by the TTL sweep with typed close code', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      abuseControls: AbuseControlConfig(
        idleRoomTtl: const Duration(milliseconds: 300),
        sweepInterval: const Duration(milliseconds: 100),
      ),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'call-idle');
    expect(server.activeRooms, 1);

    // No traffic for well past the TTL: the sweep reaps the room.
    expect(await pair.aClose, idleTimeoutCloseCode);
    expect(await pair.bClose, idleTimeoutCloseCode);
    expect(server.activeRooms, 0);
    expect(server.counters.idleRoomsReaped, 1);
  });

  test('global concurrent room cap rejects a new room with 4503', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      abuseControls: AbuseControlConfig(maxConcurrentRoomsGlobal: 1),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'call-cap');

    final extra = await connectClient(server.port);
    final extraObs = observe(extra);
    extra.add(envelope('call-over-cap'));
    expect(await extraObs.closeCode, roomCapacityCloseCode);
    expect(server.counters.roomCapacityRejections, 1);
    expect(server.activeRooms, 1);

    // The capped-out attempt did not disturb the existing room.
    pair.a.add(envelope('call-cap', body: 'unaffected'));
    await Future<void>.delayed(_settleDelay);
    expect(pair.bMessages, [envelope('call-cap', body: 'unaffected')]);

    await pair.a.close();
    await pair.b.close();
  });

  test('per-source concurrent room cap rejects, but joining the same room is '
      'always allowed', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
      abuseControls: AbuseControlConfig(maxConcurrentRoomsPerSource: 1),
    );
    addTearDown(server.close);

    // Both peers come from the same source (loopback) — the second peer
    // joining the SAME room must not be counted as a second room.
    final pair = await connectAndPair(server.port, 'call-ps');
    expect(server.activeRooms, 1);
    expect(server.counters.roomCapacityRejections, 0);

    final extra = await connectClient(server.port);
    final extraObs = observe(extra);
    extra.add(envelope('call-ps-2'));
    expect(await extraObs.closeCode, roomCapacityCloseCode);
    expect(server.counters.roomCapacityRejections, 1);

    await pair.a.close();
    await pair.b.close();
  });
}
