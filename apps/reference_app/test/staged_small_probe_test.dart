/// Local repro probe for the msg-loss60 staged-photo stall: SMALL
/// transfers (15 KB then 96 KB, one sender — the §0.2 pipeline shape)
/// through the REAL relay under the same 60% i.i.d. loss the 4 MiB probe
/// passes. If small transfers crawl where 4 MiB flies, the lane's rate
/// law has a small-transfer pathology (STATE-clocked debt parking).
@Timeout(Duration(minutes: 10))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';

import '../integration_test/support/datagram_lane_port.dart';
import 'support/relay_process.dart';

final class _LossySend implements DataChannelPort {
  _LossySend(this._inner, this.lossPerMille, this.seed);

  final DataChannelPort _inner;
  final int lossPerMille;
  int seed;

  final Map<String, int> typeCounts = {};

  void _count(String dir, List<int> frame, bool dropped) {
    final type = frame.length > 1 ? frame[1] : -1;
    final key = '$dir/t$type${dropped ? '/drop' : ''}';
    typeCounts[key] = (typeCounts[key] ?? 0) + 1;
  }

  bool _drop() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed % 1000) < lossPerMille;
  }

  @override
  Stream<List<int>> get inbound => _inner.inbound.map((f) {
    _count('in', f, false);
    return f;
  });

  @override
  Future<void> send(List<int> frame) {
    final dropped = _drop();
    _count('out', frame, dropped);
    return dropped ? Future.value() : _inner.send(frame);
  }

  @override
  Future<void> close() => _inner.close();
}

Uint8List _bytes(int n, int seed) {
  final b = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    b[i] = x & 0xff;
  }
  return b;
}

void main() {
  test('staged-photo-sized transfers (15KB then 96KB, one sender) through '
      'the real relay under 60% loss must not crawl', () async {
    final relay = await RelayProcess.start();
    addTearDown(relay.kill);
    final relayPort = relay.port;

    final key = DatagramLanePort.roomKeyFromCallId('probe-staged-small');
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

    final blobs = <Uint8List>[];
    final receiver = FountainStreamReceiver(
      rx,
      expireAfter: const Duration(minutes: 5),
      onCompleted: blobs.add,
    );
    addTearDown(receiver.dispose);
    final sender = FountainStreamSender(
      tx,
      symbolBytes: 1024,
      floorBytesPerSec: 32 * 1024,
      staleAfter: const Duration(seconds: 30),
    );

    final preview = _bytes(15 * 1024, 0x2545F491);
    final original = _bytes(96 * 1024, 0x1E552901);

    final sw = Stopwatch()..start();
    final FountainSendResult r1;
    try {
      r1 = await sender.send(preview).timeout(const Duration(minutes: 4));
    } finally {
      print('TX_COUNTS ${tx.typeCounts}');
      print('RX_COUNTS ${rx.typeCounts}');
    }
    final previewMs = sw.elapsedMilliseconds;
    final r2 = await sender.send(original).timeout(const Duration(minutes: 4));
    final originalMs = sw.elapsedMilliseconds - previewMs;

    print(
      'SMALL_PROBE previewMs=$previewMs originalMs=$originalMs '
      'previewSent=${r1.sentSymbols}/${r1.totalSourceSymbols} '
      'originalSent=${r2.sentSymbols}/${r2.totalSourceSymbols} '
      'txSent=${txRaw.sentDatagrams} rxReceived=${rxRaw.receivedDatagrams}',
    );
    expect(blobs.length, 2);
    // The stall signature from the rig was ~0.1 symbols/s. On an unshaped
    // host both transfers must finish in seconds, not minutes.
    expect(
      previewMs,
      lessThan(60000),
      reason: 'a 15KB rung must not crawl on an unshaped host',
    );
    expect(
      originalMs,
      lessThan(120000),
      reason: 'a 96KB rung must not crawl on an unshaped host',
    );
  });
}
