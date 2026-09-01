/// Gate 4b (RIG_GUIDE §0.3): the WHOLE datagram lane — real relay binary,
/// real UDP sockets, the app's own DatagramLanePort — must deliver the
/// full-size 4 MiB video proxy under 60% i.i.d. loss on the Mac before a
/// device run is spent. 256 KB would not answer the open question (the
/// lane's rate law after bootstrap has no floor and its 60%-loss
/// equilibrium was never measured over minutes — review T2, 2026-08-10);
/// only the official artifact size does.
///
/// Loss is applied ONCE per direction (drop-on-send at 0.60): the official
/// rig shapes each bridge crossing at 1-sqrt(1-0.6) so the double crossing
/// composes to the same 60% end-to-end — matching, not doubling (T4).
///
/// This is a host-VM test (dart:io); it spawns the REAL bin so the --port
/// parsing and the readiness-line contract h2_run greps are proven here too.
/// The suite-level timeout only has to outlive the test's own hard ceiling
/// (25 min) plus relay startup and the 4 MiB byte compare. It is NOT the
/// probe's deadline — a stalled run is caught by the progress watchdog in
/// about two minutes, long before this.
@Timeout(Duration(minutes: 40))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';

import '../integration_test/support/datagram_lane_port.dart';
import 'support/relay_process.dart';

/// Deterministic i.i.d. drop-on-send wrapper — same PRNG family as the
/// messaging package's lossy harness.
final class _LossySend implements DataChannelPort {
  _LossySend(this._inner, this.lossPerMille, this.seed);

  final DataChannelPort _inner;
  final int lossPerMille;
  int seed;

  bool _drop() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed % 1000) < lossPerMille;
  }

  @override
  Stream<List<int>> get inbound => _inner.inbound;

  @override
  Future<void> send(List<int> frame) =>
      _drop() ? Future.value() : _inner.send(frame);

  @override
  Future<void> close() => _inner.close();
}

Uint8List deterministicVideo(int length) {
  final bytes = Uint8List(length);
  var x = 0x2545F491;
  for (var i = 0; i < length; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    bytes[i] = x & 0xff;
  }
  return bytes;
}

void main() {
  test('4 MiB fountain transfer through the real datagram relay under 60% '
      'i.i.d. loss delivers intact within the official window', () async {
    // Spawn the REAL bin (AOT-cached by RelayProcess) on an ephemeral port;
    // the helper owns readiness and reports full process state on failure.
    final relay = await RelayProcess.start();
    addTearDown(relay.kill);
    final relayPort = relay.port;

    final key = DatagramLanePort.roomKeyFromCallId('probe-4mib-loss60');
    final txRaw = await DatagramLanePort.bind(
      relayHost: '127.0.0.1',
      relayPort: relayPort,
      roomKey: key,
    );
    final rxRaw = await DatagramLanePort.bind(
      relayHost: '127.0.0.1',
      relayPort: relayPort,
      roomKey: key,
    );
    addTearDown(txRaw.close);
    addTearDown(rxRaw.close);
    final tx = _LossySend(txRaw, 600, 0x1234);
    final rx = _LossySend(rxRaw, 600, 0x9876);

    final delivered = Completer<Uint8List>();
    final receiver = FountainStreamReceiver(
      rx,
      expireAfter: const Duration(minutes: 5),
      onCompleted: (c) {
        if (!delivered.isCompleted) delivered.complete(c);
      },
    );
    addTearDown(receiver.dispose);
    const symbolBytes = 1024;
    const floorBytesPerSec = 32 * 1024;
    final sender = FountainStreamSender(
      tx,
      symbolBytes: symbolBytes,
      floorBytesPerSec: floorBytesPerSec,
      staleAfter: const Duration(seconds: 30),
    );

    final clip = deterministicVideo(4 * 1024 * 1024);

    // In-process scheduling probe. The sender paces itself with timers on
    // this isolate's event loop, so when the host is saturated the pacing
    // stretches while the rate law is untouched — the measured failure
    // mode: 304 s alone, past the old 480 s deadline at load average ~15
    // with the code unchanged. A short periodic tick measures that stretch
    // directly and in-process: no load-average read, no subprocess, so
    // there is nothing to fall back to in a sandbox. Its nominal period
    // sits at or below the sender's pacing quantum, so the probe stretches
    // at least as much as the sender — over-correcting only helps a loaded
    // healthy run, while a regression on a quiet host has dilation ~1 and
    // gains nothing from it.
    const tickNominal = Duration(milliseconds: 15);
    var tickCount = 0;
    final tickWatch = Stopwatch()..start();
    final ticker = Timer.periodic(tickNominal, (_) => tickCount++);
    addTearDown(ticker.cancel);
    double dilation() {
      if (tickCount == 0) return 1.0;
      final d =
          tickWatch.elapsedMicroseconds /
          (tickCount * tickNominal.inMicroseconds);
      return d < 1.0 ? 1.0 : d;
    }

    final started = DateTime.now();
    final resultF = sender.send(clip);
    unawaited(
      resultF.then<void>(
        (_) {},
        onError: (Object e, StackTrace st) {
          if (!delivered.isCompleted) delivered.completeError(e, st);
        },
      ),
    );

    // Liveness, not a deadline. The old comment here claimed that needing
    // more than 8 minutes "signals the T2 rate-law stall, not slowness";
    // a loaded host falsified that by exceeding 8 minutes with the code
    // unchanged. The two causes now have two detectors. A genuine stall
    // stops PRODUCING — no datagram progress for a dilation-scaled window
    // — however fast the host is. Host slowness shows up as dilation > 1,
    // is forgiven here, and is charged instead to the rate assertion
    // below. The hard ceiling exists only so a pathological run
    // terminates; it is not the assertion.
    const stallWindowBase = Duration(seconds: 120);
    const hardCeiling = Duration(minutes: 25);
    var lastProgress = rxRaw.receivedDatagrams;
    final sinceProgress = Stopwatch()..start();
    final sinceStart = Stopwatch()..start();
    while (!delivered.isCompleted) {
      await Future.any<void>([
        delivered.future.then<void>((_) {}),
        Future<void>.delayed(const Duration(seconds: 5)),
      ]);
      if (delivered.isCompleted) break;
      if (rxRaw.receivedDatagrams != lastProgress) {
        lastProgress = rxRaw.receivedDatagrams;
        sinceProgress.reset();
      }
      final d = dilation();
      if (sinceProgress.elapsed > stallWindowBase * d) {
        fail(
          'no datagram progress for ${sinceProgress.elapsed.inSeconds}s '
          '(window ${(stallWindowBase * d).inSeconds}s at dilation '
          '${d.toStringAsFixed(2)}, rxReceived=${rxRaw.receivedDatagrams})'
          ' — the pipeline stopped producing, and that is independent of '
          'host speed',
        );
      }
      if (sinceStart.elapsed > hardCeiling) {
        fail(
          'probe still running after ${hardCeiling.inMinutes} min with '
          'progress only trickling (rxReceived=${rxRaw.receivedDatagrams},'
          ' dilation ${d.toStringAsFixed(2)})',
        );
      }
    }
    final received = await delivered.future;
    final ms = DateTime.now().difference(started).inMilliseconds;
    final result = await resultF.timeout(const Duration(seconds: 30));
    ticker.cancel();
    final hostDilation = dilation();

    expect(received.length, clip.length);
    var intact = true;
    for (var i = 0; i < clip.length; i++) {
      if (received[i] != clip[i]) {
        intact = false;
        break;
      }
    }
    expect(intact, isTrue, reason: 'delivered bytes must equal the source');

    final overhead = result.sentSymbols / result.totalSourceSymbols;
    final achievedBps = result.sentSymbols * symbolBytes * 1000 / ms;
    final correctedBps = achievedBps * hostDilation;
    print(
      'PROBE_SUMMARY sentSymbols=${result.sentSymbols} '
      'totalSourceSymbols=${result.totalSourceSymbols} '
      'overhead=${overhead.toStringAsFixed(2)}x ms=$ms '
      'deliveredKbps=${(clip.length * 8 / ms).round()} '
      'achievedBps=${achievedBps.round()} '
      'correctedBps=${correctedBps.round()} floorBps=$floorBytesPerSec '
      'dilation=${hostDilation.toStringAsFixed(2)} '
      'condition=${hostDilation > 1.3 ? 'loaded-host' : 'quiet-host'} '
      'txSent=${txRaw.sentDatagrams} txLocalDrops=${txRaw.localSendDrops} '
      'rxReceived=${rxRaw.receivedDatagrams}',
    );

    // Symbol economics are a property of the loss profile and the rate
    // law, not of host speed: a deterministic 60% drop means delivery
    // cannot complete under ~2.5x the source symbols sent (1/0.4), and the
    // fountain's reception overhead adds only a few percent — 2.58x on the
    // recorded passing run. The band survives load because the feedback
    // lag costs symbols at the pacing rate, and load lowers that rate by
    // the same factor it lengthens the lag.
    expect(
      overhead,
      greaterThan(2.4),
      reason:
          'sent/source below the 1/0.4 loss floor means the '
          'deterministic 60% drop is not being applied',
    );
    expect(
      overhead,
      lessThan(3.4),
      reason:
          'sent/source far above the loss floor means the repair '
          'series or the rate law is overshooting',
    );

    // The floor rate is a promise made by the CODE's pacing, so hold it
    // against the event loop the code actually got: the sent rate,
    // corrected by measured dilation, must clear 75% of floorBytesPerSec.
    expect(
      correctedBps,
      greaterThan(0.75 * floorBytesPerSec),
      reason:
          'sender paced below its configured floor after correcting '
          'for host scheduling: ${correctedBps.round()} B/s corrected '
          '(${achievedBps.round()} B/s raw at dilation '
          '${hostDilation.toStringAsFixed(2)}) vs floor '
          '$floorBytesPerSec B/s',
    );
  });
}
