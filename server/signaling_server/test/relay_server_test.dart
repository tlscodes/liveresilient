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

  // Room membership is identity-keyed (senderKeyId), so a protocol-valid
  // frame ALWAYS carries one — exactly like real `SignalEnvelope` traffic.
  // Frames without it are dropped before pairing (and there is a dedicated
  // test asserting that).
  String envelope(String callId, {String body = 'hello', String from = 'a'}) =>
      jsonEncode({'callId': callId, 'senderKeyId': '$from-key', 'body': body});

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

    a.add(envelope(callId, body: '__seed__', from: 'a'));
    b.add(envelope(callId, body: '__seed__', from: 'b'));
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
    b.add(envelope('call-buffer', body: 'joins', from: 'b'));

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
    // A third IDENTITY: with identity-keyed membership, "full" means two
    // other identities are seated — not merely two sockets.
    c.add(envelope('call-full', body: 'reject-me', from: 'c'));

    final code = await closeCode.future.timeout(frameWaitTimeout);
    expect(code, 4409);
    expect(server.activeRooms, 1);

    await pair.a.close();
    await pair.b.close();
  });

  test(
    'a reconnecting identity JOINS its seat (multi-socket, raised '
    '2026-08-09): sockets coexist up to the cap, frames fan out to all, '
    'and only overflow beyond the cap evicts the OLDEST (no lockout ever)',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
      );
      addTearDown(server.close);

      final pair = await connectAndPair(server.port, 'call-resume');

      // b's old socket goes silent-zombie and b reconnects: the fresh
      // socket JOINS the seat (no supersede below the cap of 3).
      final b2 = await connectClient(server.port);
      final b2Frames = FrameCollector();
      b2.listen((event) => b2Frames.add(event as String));
      final oldClosed = Completer<int?>();
      pair.bSub.onDone(() => oldClosed.complete(pair.b.closeCode));
      b2.add(envelope('call-resume', body: '__resumed__', from: 'b'));

      // The peer receives b's post-resume frame — the room stayed alive.
      await pair.aFrames.waitForCount(1, 'resumed frame relayed to a');
      expect(pair.aFrames.frames, [
        envelope('call-resume', body: '__resumed__', from: 'b'),
      ]);
      expect(server.activeRooms, 1);

      // A frame from the peer fans out to EVERY socket of b's seat —
      // the hedge: whichever stream is not stalled delivers first.
      pair.a.add(envelope('call-resume', body: 'after-resume'));
      await b2Frames.waitForCount(1, 'frame relayed to resumed socket');

      // Two more joins overflow the cap (3): only then is the OLDEST
      // (the zombie) actively closed as superseded (4410).
      final b3 = await connectClient(server.port);
      b3.listen((_) {});
      b3.add(envelope('call-resume', body: '__resumed3__', from: 'b'));
      final b4 = await connectClient(server.port);
      b4.listen((_) {});
      b4.add(envelope('call-resume', body: '__resumed4__', from: 'b'));
      final code = await oldClosed.future.timeout(frameWaitTimeout);
      expect(code, supersededCloseCode);
      expect(server.activeRooms, 1);

      await pair.a.close();
      await b2.close();
      await b3.close();
      await b4.close();
    },
  );

  test('a join frame without a sender identity is dropped, not paired',
      () async {
    final server = await SignalingRelayServer.bind(
      security: buildServerSecurityContext(),
    );
    addTearDown(server.close);

    final a = await connectClient(server.port);
    a.add(jsonEncode({'callId': 'call-anon', 'body': 'no-identity'}));
    // Give the frame time to be processed, then confirm no room formed.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.activeRooms, 0);
    await a.close();
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

  test(
    'a member disconnect only vacates its seat: the survivor keeps its '
    'socket and the returning identity resumes the same room (raised '
    '2026-08-07 — the old close-the-peer-with-1000 behavior turned every '
    'one-sided flap under loss into a two-sided from-zero rebuild)',
    () async {
      final server = await SignalingRelayServer.bind(
        security: buildServerSecurityContext(),
      );
      addTearDown(server.close);

      final pair = await connectAndPair(server.port, 'call-disconnect');

      await pair.a.close();
      // Let the server observe the disconnect and vacate the seat BEFORE
      // b transmits — a frame relayed into the still-closing socket would
      // be lost instead of buffered (client close() resolves before the
      // server's stream-done fires).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The room survives with b seated; a buffered frame from b waits for
      // a's return.
      pair.b.add(envelope('call-disconnect', body: 'while-you-were-out'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.activeRooms, 1);
      expect(pair.b.closeCode, isNull, reason: 'survivor must stay open');

      // a's identity returns on a fresh socket and receives the OTHER
      // side's recent history — including frames already delivered to
      // its predecessor socket. Raised 2026-08-09 (loss60): the ring is
      // no longer cleared on flush, because a TCP write into a zombie
      // seat is not delivery and the server cannot tell the difference;
      // the client adapter's dedup absorbs the re-delivery.
      final a2 = await connectClient(server.port);
      final a2Frames = FrameCollector();
      a2.listen((event) => a2Frames.add(event as String));
      a2.add(envelope('call-disconnect', body: '__back__', from: 'a'));
      await a2Frames.waitForCount(2, 'buffered frames flushed on resume');
      expect(a2Frames.frames, [
        envelope('call-disconnect', body: '__seed__', from: 'b'),
        envelope('call-disconnect', body: 'while-you-were-out'),
      ]);

      await a2.close();
      await pair.b.close();
    },
  );

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
