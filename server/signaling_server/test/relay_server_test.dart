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
    certDir = await Directory.systemTemp.createTemp('signaling_server_test_');
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

  /// Connects two peers, attaches collectors on both BEFORE any traffic (so
  /// the room-join buffer flush is captured deterministically), then joins
  /// both peers into [callId]'s room and drains the flush.
  Future<
    ({
      WebSocket a,
      WebSocket b,
      List<String> aMessages,
      List<String> bMessages,
      StreamSubscription<dynamic> aSub,
      StreamSubscription<dynamic> bSub,
    })
  >
  connectAndPair(int port, String callId) async {
    final a = await connectClient(port);
    final b = await connectClient(port);
    final aMessages = <String>[];
    final bMessages = <String>[];
    final aSub = a.listen((event) => aMessages.add(event as String));
    final bSub = b.listen((event) => bMessages.add(event as String));

    a.add(envelope(callId, body: '__seed__'));
    b.add(envelope(callId, body: '__seed__'));
    await Future<void>.delayed(_settleDelay);

    // The buffered seed frame from `a` flushes to `b` on join; b's own seed
    // frame then relays live to `a`. Drain both before real assertions.
    aMessages.clear();
    bMessages.clear();

    return (
      a: a,
      b: b,
      aMessages: aMessages,
      bMessages: bMessages,
      aSub: aSub,
      bSub: bSub,
    );
  }

  test(
    'two peers on the same callId exchange frames both directions',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
      );
      addTearDown(server.close);

      final pair = await connectAndPair(server.port, 'call-1');

      pair.a.add(envelope('call-1', body: 'from-a-1'));
      pair.b.add(envelope('call-1', body: 'from-b-1'));
      await Future<void>.delayed(_settleDelay);

      expect(pair.bMessages, [envelope('call-1', body: 'from-a-1')]);
      expect(pair.aMessages, [envelope('call-1', body: 'from-b-1')]);

      await pair.a.close();
      await pair.b.close();
    },
  );

  test('early frame is buffered until peer joins then delivered', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final a = await connectClient(server.port);
    a.add(envelope('call-buffer', body: 'queued-1'));
    a.add(envelope('call-buffer', body: 'queued-2'));
    await Future<void>.delayed(_settleDelay);

    final b = await connectClient(server.port);
    final received = <String>[];
    b.listen((event) => received.add(event as String));
    b.add(envelope('call-buffer', body: 'joins'));

    await Future<void>.delayed(_settleDelay);
    expect(received, [
      envelope('call-buffer', body: 'queued-1'),
      envelope('call-buffer', body: 'queued-2'),
    ]);

    await a.close();
    await b.close();
  });

  test('a third joiner on a full room is rejected with 4409', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'call-full');

    final c = await connectClient(server.port);
    final closeCode = Completer<int?>();
    c.listen((_) {}, onDone: () => closeCode.complete(c.closeCode));
    c.add(envelope('call-full', body: 'reject-me'));

    final code = await closeCode.future.timeout(const Duration(seconds: 5));
    expect(code, 4409);
    expect(server.activeRooms, 1);

    await pair.a.close();
    await pair.b.close();
  });

  test(
    'oversized frame is dropped, peer receives nothing, connection stays alive',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
      );
      addTearDown(server.close);

      final pair = await connectAndPair(server.port, 'call-oversize');

      final hugeBody = 'x' * (maxRelayFrameBytes + 1024);
      pair.a.add(envelope('call-oversize', body: hugeBody));
      await Future<void>.delayed(_settleDelay);
      expect(pair.bMessages, isEmpty);

      // Connection stays alive: a normal frame right after still relays.
      pair.a.add(envelope('call-oversize', body: 'still-alive'));
      await Future<void>.delayed(_settleDelay);
      expect(pair.bMessages, [envelope('call-oversize', body: 'still-alive')]);

      expect(pair.a.readyState, WebSocket.open);

      await pair.a.close();
      await pair.b.close();
    },
  );

  test('malformed JSON frame is dropped without crashing the room', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'call-malformed');

    pair.a.add('{not valid json');
    await Future<void>.delayed(_settleDelay);
    expect(pair.bMessages, isEmpty);

    pair.a.add(envelope('call-malformed', body: 'after-bad'));
    await Future<void>.delayed(_settleDelay);
    expect(pair.bMessages, [envelope('call-malformed', body: 'after-bad')]);

    await pair.a.close();
    await pair.b.close();
  });

  test('disconnect closes the surviving peer with code 1000', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final pair = await connectAndPair(server.port, 'call-disconnect');

    final closeCode = Completer<int?>();
    pair.bSub.onDone(() => closeCode.complete(pair.b.closeCode));

    await pair.a.close();

    final code = await closeCode.future.timeout(const Duration(seconds: 5));
    expect(code, 1000);
  });

  test('different callIds are isolated from each other', () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final pairX = await connectAndPair(server.port, 'call-x');
    final pairY = await connectAndPair(server.port, 'call-y');

    pairX.a.add(envelope('call-x', body: 'only-for-x'));
    await Future<void>.delayed(_settleDelay);

    expect(pairX.bMessages, [envelope('call-x', body: 'only-for-x')]);
    expect(pairY.bMessages, isEmpty);
    expect(server.activeRooms, 2);

    await pairX.a.close();
    await pairX.b.close();
    await pairY.a.close();
    await pairY.b.close();
  });
}
