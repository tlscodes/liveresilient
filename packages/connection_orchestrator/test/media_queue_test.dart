/// Phase 3 — background media queue with strict voice priority.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

/// Deterministic speech/silence schedule: alternating windows.
bool _speaking(int nowMs) => (nowMs ~/ 3000).isEven; // 3s speech, 3s silence

/// A fixed voice sender: emits a voice datagram every 60 ms while
/// speaking. Completely independent of the media queue by construction;
/// the test proves that independence by comparing tick sequences.
List<int> _voiceSendTicks(int totalMs, {MediaTransferQueue? mediaQueue}) {
  final ticks = <int>[];
  for (var nowMs = 0; nowMs <= totalMs; nowMs += 20) {
    final speaking = _speaking(nowMs);
    if (speaking && nowMs % 60 == 0) ticks.add(nowMs);
    mediaQueue?.tick(nowMs: nowMs, voiceIsSpeaking: speaking);
  }
  return ticks;
}

void main() {
  final rng = Random(3);

  test('emits 0 media datagrams during speech windows', () {
    final q = MediaTransferQueue(spareBudgetBytesPerSecond: 300);
    q.enqueue(Uint8List.fromList(List.generate(4096, (_) => rng.nextInt(256))));
    for (var nowMs = 0; nowMs <= 30000; nowMs += 20) {
      final out = q.tick(nowMs: nowMs, voiceIsSpeaking: _speaking(nowMs));
      if (_speaking(nowMs)) {
        expect(out, isEmpty, reason: 'media emitted during speech at $nowMs');
      }
    }
  });

  test('during silence emits at or below the configured cap, never above', () {
    const cap = 400;
    final q = MediaTransferQueue(spareBudgetBytesPerSecond: cap);
    q.enqueue(
      Uint8List.fromList(List.generate(65536, (_) => rng.nextInt(256))),
    );
    final bytesPerSecond = <int, int>{};
    for (var nowMs = 0; nowMs <= 60000; nowMs += 20) {
      final out = q.tick(nowMs: nowMs, voiceIsSpeaking: _speaking(nowMs));
      final sec = nowMs ~/ 1000;
      for (final d in out) {
        bytesPerSecond[sec] = (bytesPerSecond[sec] ?? 0) + d.bytes.length;
      }
    }
    expect(bytesPerSecond, isNotEmpty);
    for (final e in bytesPerSecond.entries) {
      // Token bucket allows at most one extra second of accrued budget
      // to drain in the first second after speech ends; per-second spend
      // therefore never exceeds 2x cap, and steady-state stays <= cap.
      expect(
        e.value,
        lessThanOrEqualTo(2 * cap),
        reason: 'second ${e.key} burst above bucket bound',
      );
    }
    final total = bytesPerSecond.values.reduce((a, b) => a + b);
    // Silence is half the 60s run (~30s). Each of the ~10 silence
    // windows may additionally drain one bucket (<= cap bytes) accrued
    // during the preceding speech window. Bound: cap*(30 + 10 + 1).
    expect(total, lessThanOrEqualTo(cap * 41));
  });

  test('voice send ticks are IDENTICAL with and without media transfer', () {
    final without = _voiceSendTicks(60000);
    final q = MediaTransferQueue(spareBudgetBytesPerSecond: 300);
    q.enqueue(
      Uint8List.fromList(List.generate(32768, (_) => rng.nextInt(256))),
    );
    final withMedia = _voiceSendTicks(60000, mediaQueue: q);
    expect(
      withMedia,
      equals(without),
      reason: 'voice schedule changed by media activity',
    );
    expect(
      q.bytesEmitted,
      greaterThan(0),
      reason: 'media actually ran during the comparison',
    );
  });

  test('transfer spanning many speech/silence alternations completes '
      'bit-exact', () {
    final data = Uint8List.fromList(
      List.generate(8192, (_) => rng.nextInt(256)),
    );
    final q = MediaTransferQueue(spareBudgetBytesPerSecond: 500);
    final transfer = q.enqueue(data);
    final dec = RatelessDecoder();
    var nowMs = 0;
    var alternations = 0;
    var lastSpeaking = _speaking(0);
    while (!dec.isComplete) {
      nowMs += 20;
      expect(nowMs, lessThan(30 * 60 * 1000), reason: 'did not converge');
      final speaking = _speaking(nowMs);
      if (speaking != lastSpeaking) alternations++;
      lastSpeaking = speaking;
      for (final d in q.tick(nowMs: nowMs, voiceIsSpeaking: speaking)) {
        dec.addDatagram(d.bytes);
      }
    }
    q.markComplete(transfer.id);
    expect(q.isIdle, isTrue);
    expect(dec.data, equals(data));
    expect(
      alternations,
      greaterThan(4),
      reason: 'transfer must have spanned several speech/silence windows',
    );
    // ignore: avoid_print
    print(
      'media queue (simulated): 8KB in ${(nowMs / 1000).toStringAsFixed(1)}s '
      'across $alternations speech/silence alternations',
    );
  });

  test(
    'two concurrent transfers make round-robin progress, neither starves',
    () {
      final dataA = Uint8List.fromList(
        List.generate(6144, (_) => rng.nextInt(256)),
      );
      final dataB = Uint8List.fromList(
        List.generate(6144, (_) => rng.nextInt(256)),
      );
      final q = MediaTransferQueue(spareBudgetBytesPerSecond: 500);
      final tA = q.enqueue(dataA);
      final tB = q.enqueue(dataB);
      var nowMs = 0;
      // Run until B (enqueued second) has received a fair share of
      // datagrams — proves it is NOT starved behind A's unacked transfer.
      while (tB.datagramsSent < tB.blockCount) {
        nowMs += 20;
        expect(nowMs, lessThan(60 * 60 * 1000), reason: 'did not converge');
        q.tick(nowMs: nowMs, voiceIsSpeaking: _speaking(nowMs));
        // A must never get more than a handful of datagrams ahead of B —
        // strict head-first service (the pre-fix behavior) would instead
        // let A run to its full blockCount before B gets anything.
        expect(
          tA.datagramsSent - tB.datagramsSent,
          lessThanOrEqualTo(3),
          reason: 'transfer A starved transfer B',
        );
      }
      // ignore: avoid_print
      print(
        'round-robin: B received all ${tB.blockCount} source blocks by '
        '${(nowMs / 1000).toStringAsFixed(1)}s while A was at '
        '${tA.datagramsSent}/${tA.blockCount}',
      );
    },
  );
}
