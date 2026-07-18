import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/frame_collector.dart';

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
  /// both peers into [callId]'s room and awaits the seed exchange: `a`'s
  /// buffered seed flushes to `b` on join, and `b`'s seed relays live to
  /// `a`. Both collectors are drained before returning, so tests start from
  /// a proven-joined, empty state without any settle sleep.
  Future<
    ({
      WebSocket a,
      WebSocket b,
      FrameCollector aFrames,
      FrameCollector bFrames,
      StreamSubscription<dynamic> aSub,
      StreamSubscription<dynamic> bSub,
    })
  >
  connectAndPair(int port, String callId) async {
    final a = await connectClient(port);
    final b = await connectClient(port);
    final aFrames = FrameCollector();
    final bFrames = FrameCollector();
    final aSub = a.listen((event) => aFrames.add(event as String));
    final bSub = b.listen((event) => bFrames.add(event as String));

    a.add(envelope(callId, body: '__seed__'));
    b.add(envelope(callId, body: '__seed__'));
    await aFrames.waitForCount(1, '$callId: seed from b relayed to a');
    await bFrames.waitForCount(1, '$callId: seed from a flushed to b');

    aFrames.frames.clear();
    bFrames.frames.clear();

    return (
      a: a,
      b: b,
      aFrames: aFrames,
      bFrames: bFrames,
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
      await pair.bFrames.waitForCount(1, 'frame from a');
      await pair.aFrames.waitForCount(1, 'frame from b');

      expect(pair.bFrames.frames, [envelope('call-1', body: 'from-a-1')]);
      expect(pair.aFrames.frames, [envelope('call-1', body: 'from-b-1')]);

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

    final b = await connectClient(server.port);
    final received = FrameCollector();
    b.listen((event) => received.add(event as String));
    b.add(envelope('call-buffer', body: 'joins'));

    // The flush is triggered by b's join frame; ordering within the room is
    // FIFO, so awaiting the count IS awaiting the flush — no sleep needed
    // even though a's frames were still in flight when b connected.
    await received.waitForCount(2, 'buffered frames flushed on join');
    expect(received.frames, [
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

    final code = await closeCode.future.timeout(frameWaitTimeout);
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

      // "Peer receives nothing" cannot be awaited directly; instead ride the
      // relay's per-connection FIFO: the server fully processes (drops) the
      // oversized frame before it relays the barrier sent right behind it on
      // the same socket. When the barrier arrives alone, the drop is proven.
      final hugeBody = 'x' * (maxRelayFrameBytes + 1024);
      pair.a.add(envelope('call-oversize', body: hugeBody));
      pair.a.add(envelope('call-oversize', body: 'still-alive'));

      await pair.bFrames.waitForCount(1, 'barrier after oversized frame');
      expect(pair.bFrames.frames, [
        envelope('call-oversize', body: 'still-alive'),
      ]);

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

    // Same barrier pattern as the oversized-frame test: FIFO on a's
    // connection proves the malformed frame was dropped, not delayed.
    pair.a.add('{not valid json');
    pair.a.add(envelope('call-malformed', body: 'after-bad'));

    await pair.bFrames.waitForCount(1, 'barrier after malformed frame');
    expect(pair.bFrames.frames, [
      envelope('call-malformed', body: 'after-bad'),
    ]);

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

    final code = await closeCode.future.timeout(frameWaitTimeout);
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
    await pairX.bFrames.waitForCount(1, 'frame within room x');

    // Prove y saw nothing by round-tripping a barrier through room y AFTER
    // x's frame was fully relayed; if the relay had leaked x's frame into
    // room y it would sit in y's collector ahead of (or beside) the barrier.
    pairY.a.add(envelope('call-y', body: 'y-barrier'));
    await pairY.bFrames.waitForCount(1, 'barrier within room y');

    expect(pairX.bFrames.frames, [envelope('call-x', body: 'only-for-x')]);
    expect(pairY.bFrames.frames, [envelope('call-y', body: 'y-barrier')]);
    expect(server.activeRooms, 2);

    await pairX.a.close();
    await pairX.b.close();
    await pairY.a.close();
    await pairY.b.close();
  });
}
