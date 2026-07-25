/// The pulsing-link scenario: the link breathes for ~3 seconds, dies for
/// ~30, repeats. Token-voice blocks must all arrive (within lifetime),
/// replay strictly in order, keep codec state byte-identical, and an
/// expired chain must restart cleanly instead of crashing or diverging.
library;

import 'dart:convert';
import 'dart:math';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

List<List<int>> speechBlock(Random rng, int frames) => [
      for (var i = 0; i < frames; i++)
        [rng.nextInt(1024), rng.nextInt(1024)]
    ];

void main() {
  test('pulsing link 3s-alive/30s-dead: 100% of in-lifetime blocks '
      'deliver, replay in exact production order, zero state divergence',
      () async {
    final rng = Random(42);
    final queue = DtnBundleQueue();
    final sender = TokenVoiceSender(
      nRows: 2,
      queue: queue,
      blockLifetime: const Duration(minutes: 5), // lifetime covers pulses
    );
    final receiver = TokenVoiceReceiver(nRows: 2);
    final produced = <List<List<int>>>[];

    var nowMs = 0;
    var linkAlive = false;
    for (var step = 0; step < 120; step++) {
      // one block every second; link alive 3s out of every 33
      linkAlive = step % 33 < 3;
      final block = speechBlock(rng, 25);
      produced.add(block);
      sender.sendBlock(block, nowMs: nowMs);
      if (linkAlive) {
        await queue.flush((bundle) async {
          receiver.offer(bundle.payload);
          return true;
        }, nowMs: nowMs);
      }
      nowMs += 1000;
    }
    // final pulse drains whatever is still queued (within lifetime)
    await queue.flush((bundle) async {
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: nowMs);

    expect(sender.epochRestarts, 0, reason: 'lifetime covered every gap');
    expect(receiver.played.length, produced.length,
        reason: '100% delivery inside lifetime');
    expect(receiver.played, equals(produced), reason: 'exact order');
    expect(queue.pendingCount, 0);
  });

  test('a flush attempt that fails mid-pulse keeps the bundle queued; a '
      'later pulse delivers it — nothing lost, order preserved', () async {
    final rng = Random(7);
    final queue = DtnBundleQueue();
    final sender = TokenVoiceSender(nRows: 2, queue: queue);
    final receiver = TokenVoiceReceiver(nRows: 2);
    final produced = <List<List<int>>>[];
    for (var i = 0; i < 3; i++) {
      final block = speechBlock(rng, 10);
      produced.add(block);
      sender.sendBlock(block, nowMs: i * 100);
    }
    // first pulse: transport throws on the second bundle
    var delivered = 0;
    await queue.flush((bundle) async {
      if (delivered == 1) throw StateError('link died mid-pulse');
      delivered++;
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: 300).catchError((Object _) => 0);
    expect(queue.pendingCount, greaterThan(0));
    // second pulse delivers the rest
    await queue.flush((bundle) async {
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: 400);
    expect(receiver.played, equals(produced));
  });

  test('expired chain: sender bumps epoch and restarts from fresh state; '
      'receiver follows, drops stale blocks, keeps playing — no crash',
      () async {
    final rng = Random(3);
    final queue = DtnBundleQueue();
    final sender = TokenVoiceSender(
      nRows: 2,
      queue: queue,
      blockLifetime: const Duration(seconds: 5),
    );
    final receiver = TokenVoiceReceiver(nRows: 2);

    // epoch 0: two blocks sent, NEVER delivered, left to expire
    sender.sendBlock(speechBlock(rng, 10), nowMs: 0);
    sender.sendBlock(speechBlock(rng, 10), nowMs: 1000);

    // 60s later (long dead zone): next send detects expiry, restarts
    final freshBlock = speechBlock(rng, 10);
    sender.sendBlock(freshBlock, nowMs: 60000);
    expect(sender.epochRestarts, 1);
    expect(sender.epoch, 1);

    await queue.flush((bundle) async {
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: 60100);
    expect(receiver.epoch, 1);
    expect(receiver.played, equals([freshBlock]),
        reason: 'new-epoch block plays despite the broken old chain');

    // conversation continues normally on the new epoch
    final nextBlock = speechBlock(rng, 10);
    sender.sendBlock(nextBlock, nowMs: 61000);
    await queue.flush((bundle) async {
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: 61100);
    expect(receiver.played.last, equals(nextBlock));
  });

  test('per-contact persistence: call 2 with the saved state costs less '
      'than call 1 and still decodes bit-exact', () async {
    final rng = Random(9);
    final block = speechBlock(rng, 200);

    Future<(int, HamsedaState, HamsedaState)> call(
        HamsedaState? sSt, HamsedaState? rSt) async {
      final queue = DtnBundleQueue();
      final sender =
          TokenVoiceSender(nRows: 2, queue: queue, initialState: sSt);
      final receiver = TokenVoiceReceiver(nRows: 2, initialState: rSt);
      sender.sendBlock(block, nowMs: 0);
      var bytes = 0;
      await queue.flush((bundle) async {
        bytes = bundle.payload.length;
        receiver.offer(bundle.payload);
        return true;
      }, nowMs: 1);
      expect(receiver.played.last, equals(block));
      return (bytes, sender.state, receiver.state);
    }

    final (size1, sSt, rSt) = await call(null, null);
    // persist via JSON like the app would, then a fresh "call 2"
    final sWarm = HamsedaState.fromJson(
        jsonDecode(jsonEncode(sSt.toJson())) as Map<String, dynamic>);
    final rWarm = HamsedaState.fromJson(
        jsonDecode(jsonEncode(rSt.toJson())) as Map<String, dynamic>);
    final (size2, _, _) = await call(sWarm, rWarm);
    expect(size2, lessThan(size1 ~/ 2),
        reason: 'warm dictionary must at least halve the repeat');
  });

  test('out-of-order delivery replays in order through the reorder '
      'buffer (state never decodes ahead of the chain)', () async {
    final rng = Random(11);
    final queue = DtnBundleQueue();
    final sender = TokenVoiceSender(nRows: 2, queue: queue);
    final receiver = TokenVoiceReceiver(nRows: 2);
    final produced = <List<List<int>>>[];
    final payloads = <List<int>>[];
    for (var i = 0; i < 4; i++) {
      final block = speechBlock(rng, 10);
      produced.add(block);
      sender.sendBlock(block, nowMs: i);
    }
    await queue.flush((bundle) async {
      payloads.add(bundle.payload);
      return true;
    }, nowMs: 10);
    // deliver 2,0,3,1
    for (final i in [2, 0, 3, 1]) {
      receiver.offer(payloads[i]);
    }
    expect(receiver.played, equals(produced));
  });
}
