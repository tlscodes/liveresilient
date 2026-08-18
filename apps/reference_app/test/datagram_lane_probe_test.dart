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
@Timeout(Duration(minutes: 10))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';

import '../integration_test/support/datagram_lane_port.dart';

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
    // Spawn the REAL bin on an ephemeral port; parse the readiness line.
    final repoRoot = Directory.current.parent.parent.path;
    final relayDir = '$repoRoot/server/signaling_server';
    final proc = await Process.start(
      'dart',
      ['run', 'bin/datagram_relay.dart', '--port', '0'],
      workingDirectory: relayDir,
    );
    addTearDown(proc.kill);
    final stderrBuf = StringBuffer();
    proc.stderr.transform(const SystemEncoding().decoder).listen(stderrBuf.write);
    final readiness = await proc.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('datagram relay listening on'))
        .timeout(const Duration(seconds: 60), onTimeout: () {
      throw StateError('relay bin never became ready; stderr: $stderrBuf');
    });
    final relayPort = int.parse(readiness.split(':').last.trim());

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
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1024,
      floorBytesPerSec: 32 * 1024,
      staleAfter: const Duration(seconds: 30),
    );

    final clip = deterministicVideo(4 * 1024 * 1024);
    final started = DateTime.now();
    final resultF = sender.send(clip);
    unawaited(resultF.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        if (!delivered.isCompleted) delivered.completeError(e, st);
      },
    ));
    // The official row's window for this size/profile is 790 s; the probe
    // must fit it with margin on an unshaped host or the device run is not
    // worth spending (rtt here ~0, so headroom vs the rig is enormous —
    // a probe needing >8 min signals the T2 rate-law stall, not slowness).
    final received =
        await delivered.future.timeout(const Duration(minutes: 8));
    final ms = DateTime.now().difference(started).inMilliseconds;
    final result = await resultF.timeout(const Duration(seconds: 30));

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
    print('PROBE_SUMMARY sentSymbols=${result.sentSymbols} '
        'totalSourceSymbols=${result.totalSourceSymbols} '
        'overhead=${overhead.toStringAsFixed(2)}x ms=$ms '
        'deliveredKbps=${(clip.length * 8 / ms).round()} '
        'txSent=${txRaw.sentDatagrams} txLocalDrops=${txRaw.localSendDrops} '
        'rxReceived=${rxRaw.receivedDatagrams}');
    // Honesty rail, not a tight bound: at 60% i.i.d. the floor is 2.5x;
    // feedback lag costs more. 8x is the same rail the unit suite pins.
    expect(overhead, lessThan(8));
  });
}
