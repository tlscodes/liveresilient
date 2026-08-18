import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// In-memory port pair with deterministic i.i.d. loss in BOTH directions —
/// the lane's whole reason to exist is surviving exactly this.
class _LossyPort implements DataChannelPort {
  _LossyPort(this.lossPerMille, this.seed);

  final int lossPerMille;
  int seed;
  _LossyPort? peer;

  /// Total outage switch: while true, EVERY frame vanishes (both the
  /// harness's link model for a mid-transfer recovery window and nothing
  /// else — loss stays i.i.d. when unmuted).
  bool muted = false;
  final _inbound = StreamController<List<int>>.broadcast(sync: true);

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  bool _drop() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed % 1000) < lossPerMille;
  }

  bool Function()? onBeforeSend;

  @override
  Future<void> send(List<int> frame) async {
    final gate = onBeforeSend;
    if (gate != null && !gate()) return;
    if (muted || _drop()) return;
    final copy = Uint8List.fromList(frame);
    scheduleMicrotask(() {
      final p = peer;
      if (p != null && !p._inbound.isClosed) p._inbound.add(copy);
    });
  }

  @override
  Future<void> close() async {
    await _inbound.close();
  }
}

(_LossyPort, _LossyPort) lossyPair(int lossPerMille) {
  final a = _LossyPort(lossPerMille, 0x1234);
  final b = _LossyPort(lossPerMille, 0x9876);
  a.peer = b;
  b.peer = a;
  return (a, b);
}

Uint8List content(int bytes) {
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = (i * 31 + (i >> 8) * 17) & 0xFF;
  }
  return out;
}

void main() {
  test('a 60%-loss channel delivers intact, without retransmission, with '
      'bounded symbol overhead (the whole point of the lane)', () async {
    final (tx, rx) = lossyPair(600);
    final received = Completer<Uint8List>();
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 20),
      onCompleted: received.complete,
    );
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1024,
      generationSize: 8,
      stateInterval: const Duration(milliseconds: 20),
      staleAfter: const Duration(seconds: 30),
      floorBytesPerSec: 512 * 1024,
    );

    final data = content(64 * 1024); // 64 symbols, 8 generations
    final result = await sender
        .send(data)
        .timeout(const Duration(seconds: 60));
    final delivered = await received.future
        .timeout(const Duration(seconds: 5));

    expect(delivered, equals(data));
    expect(
      sha256.convert(delivered).bytes,
      equals(sha256.convert(data).bytes),
    );
    // Overhead bound: at 60% loss the information-theoretic floor is
    // 1/(1-p) = 2.5x; feedback lag costs more. 8x is the honesty rail —
    // an ARQ-style pathology would blow far past it.
    expect(result.sentSymbols, lessThan(result.totalSourceSymbols * 8));
    await receiver.dispose();
    await tx.close();
    await rx.close();
  });

  test('ragged tail: content that is not a whole number of symbols or '
      'generations round-trips byte-exact', () async {
    final (tx, rx) = lossyPair(300);
    final received = Completer<Uint8List>();
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 20),
      onCompleted: received.complete,
    );
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1000,
      generationSize: 5,
      stateInterval: const Duration(milliseconds: 20),
      staleAfter: const Duration(seconds: 30),
      floorBytesPerSec: 512 * 1024,
    );

    final data = content(12345); // 13 symbols: 2 full gens + ragged 3
    await sender.send(data).timeout(const Duration(seconds: 30));
    final delivered =
        await received.future.timeout(const Duration(seconds: 5));
    expect(delivered, equals(data));
    await receiver.dispose();
    await tx.close();
    await rx.close();
  });

  test('resume: a second sender for the same content skips generations '
      'the receiver already completed', () async {
    final data = content(32 * 1024); // 32 symbols, 4 generations of 8
    // First pass on a CLEAN channel, cut off by closing the sender side
    // after the receiver holds at least one complete generation.
    final (tx1, rx) = lossyPair(0);
    var progressGens = 0;
    final received = Completer<Uint8List>();
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 10),
      onCompleted: received.complete,
    );
    final sender1 = FountainStreamSender(
      tx1,
      symbolBytes: 1024,
      generationSize: 8,
      stateInterval: const Duration(milliseconds: 10),
      staleAfter: const Duration(seconds: 3),
      floorBytesPerSec: 64 * 1024,
    );
    // Watch the receiver's own STATE frames for a completed generation.
    final sub = rx.peer!._inbound.stream.listen(null);
    sub.onData((raw) {
      // STATE frames flow rx->tx1: byte 1 is the type, payload starts
      // at 30 with the completed bitmap.
      if (raw.length > 30 && raw[0] == 0xF7 && raw[1] == 2) {
        final bitmap = raw[30];
        progressGens = bitmap == 0
            ? progressGens
            : [1, 2, 3, 4]
                .where((g) => (bitmap >> (g - 1)) & 1 == 1)
                .length;
      }
    });
    unawaited(
      sender1.send(data).catchError((Object _) => const FountainSendResult(
            resumedGenerations: 0,
            totalGenerations: 0,
            sentSymbols: 0,
            totalSourceSymbols: 0,
          )),
    );
    while (progressGens < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await tx1.close(); // interrupt mid-transfer
    await sub.cancel();

    // Second sender, fresh instance, same content, fresh channel to the
    // SAME receiver.
    final tx2 = _LossyPort(0, 0x777);
    tx2.peer = rx;
    rx.peer = tx2;
    final sender2 = FountainStreamSender(
      tx2,
      symbolBytes: 1024,
      generationSize: 8,
      stateInterval: const Duration(milliseconds: 10),
      staleAfter: const Duration(seconds: 5),
      floorBytesPerSec: 64 * 1024,
    );
    final result =
        await sender2.send(data).timeout(const Duration(seconds: 30));
    final delivered =
        await received.future.timeout(const Duration(seconds: 5));
    expect(delivered, equals(data));
    expect(result.resumedGenerations, greaterThanOrEqualTo(1),
        reason: 'completed generations must be inherited, not re-sent');
    await receiver.dispose();
    await tx2.close();
    await rx.close();
  });

  test('a reused sender instance performs a full second transfer '
      '(per-send state resets — review H1)', () async {
    final (tx, rx) = lossyPair(100);
    final delivered = <Uint8List>[];
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 10),
      onCompleted: delivered.add,
    );
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 512,
      generationSize: 4,
      stateInterval: const Duration(milliseconds: 10),
      staleAfter: const Duration(seconds: 5),
      floorBytesPerSec: 256 * 1024,
    );
    final first = content(4096);
    final second = content(6000);
    await sender.send(first).timeout(const Duration(seconds: 20));
    await sender.send(second).timeout(const Duration(seconds: 20));
    while (delivered.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(delivered[0], equals(first));
    expect(delivered[1], equals(second));
    await receiver.dispose();
    await tx.close();
    await rx.close();
  });

  // expireAfter is a BINDING-SITE parameter because expiry mid-transfer is
  // unrecoverable by protocol design: a re-registered receiver restarts
  // empty while the sender's completed flags only rise (applyState is
  // monotone), so a binding site whose recovery windows can outlast the
  // default MUST raise it (the T2 rig budgets loss60 recoveries up to
  // 220 s against the old hard-coded 90 s). These two tests pin both
  // halves of the contract at scaled-down timings.

  test('an outage longer than expireAfter kills the transfer terminally: '
      'receiver drops state, beacons stop, sender hits staleAfter', () async {
    final (tx, rx) = lossyPair(0);
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 20),
      expireAfter: const Duration(milliseconds: 150),
    );
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1024,
      generationSize: 8,
      stateInterval: const Duration(milliseconds: 20),
      staleAfter: const Duration(milliseconds: 900),
      // Floor low enough that the 8-symbol content is still in flight when
      // the outage begins (the deadlock needs an INCOMPLETE transfer).
      floorBytesPerSec: 2 * 1024,
    );
    final sendF = sender.send(content(8 * 1024));
    while (!sender.helloAcked) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    tx.muted = true;
    rx.muted = true;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    tx.muted = false;
    rx.muted = false;
    // Silence from the last pre-outage STATE runs to staleAfter because the
    // expired receiver ignores unknown-id symbols and never beacons again.
    await expectLater(
      sendF.timeout(const Duration(seconds: 10)),
      throwsA(isA<TimeoutException>()),
    );
    await receiver.dispose();
    await tx.close();
    await rx.close();
  });

  test('a binding-site expireAfter that outlives the outage keeps decode '
      'state and the transfer completes after the link returns', () async {
    final (tx, rx) = lossyPair(0);
    final received = Completer<Uint8List>();
    final receiver = FountainStreamReceiver(
      rx,
      stateInterval: const Duration(milliseconds: 20),
      expireAfter: const Duration(seconds: 30),
      onCompleted: received.complete,
    );
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1024,
      generationSize: 8,
      stateInterval: const Duration(milliseconds: 20),
      staleAfter: const Duration(milliseconds: 900),
      floorBytesPerSec: 2 * 1024,
    );
    final data = content(8 * 1024);
    final sendF = sender.send(data);
    while (!sender.helloAcked) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    tx.muted = true;
    rx.muted = true;
    // Same 350 ms outage as above — shorter than staleAfter (900 ms), so
    // the ONLY behavioral difference between the two tests is expireAfter.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    tx.muted = false;
    rx.muted = false;
    await sendF.timeout(const Duration(seconds: 20));
    final delivered =
        await received.future.timeout(const Duration(seconds: 5));
    expect(delivered, equals(data));
    await receiver.dispose();
    await tx.close();
    await rx.close();
  });

  test(
      'terminal-confirmation deadlock is broken by the parked solicit: a '
      'receiver that completes while the reverse path is muted answers the '
      'first re-HELLO after the path returns', () async {
    final (sp, rp) = lossyPair(0); // clean forward AND reverse by default
    final delivered = <Uint8List>[];
    final rx = FountainStreamReceiver(
      rp,
      stateInterval: const Duration(milliseconds: 50),
      expireAfter: const Duration(seconds: 60),
      onCompleted: delivered.add,
    );
    addTearDown(rx.dispose);
    final tx = FountainStreamSender(
      sp,
      symbolBytes: 1024,
      stateInterval: const Duration(milliseconds: 50),
      staleAfter: const Duration(seconds: 60),
      floorBytesPerSec: 256 * 1024,
    );
    final content = Uint8List.fromList(
      List<int>.generate(12 * 1024, (i) => (i * 37 + 11) & 0xff),
    );

    // Mute the receiver->sender path after the FIRST state survives, so
    // the sender has rank feedback, keeps sending until the receiver
    // completes, and then: DONE lost, trailing STATEs lost, sender parked
    // at its debt cap — the exact msg-loss60 signature.
    var reverseFrames = 0;
    rp.onBeforeSend = () {
      reverseFrames++;
      return reverseFrames <= 1; // only the first reverse frame survives
    };

    final sendF = tx.send(content);
    var senderDone = false;
    unawaited(sendF.then((_) => senderDone = true));
    // Give the deadlock time to form: receiver completes, reverse muted.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(delivered, hasLength(1),
        reason: 'the receiver must have completed while muted');
    expect(senderDone, isFalse,
        reason: 'precondition: the sender must still be parked deaf');

    // The reverse path returns: the NEXT solicited answer must finish it.
    rp.onBeforeSend = null;
    final result = await sendF.timeout(const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
            'sender never recovered after the reverse path returned'));
    expect(result.totalSourceSymbols, 12);
    expect(delivered.single, equals(content));
  });
}
