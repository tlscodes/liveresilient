/// Full-shape local repro of the rig's 5b staged-photo section: the
/// announcement rides a real ReliableMessenger loopback (with the rig's
/// slow retry pacing) and the two blobs ride StagedPhoto fountain lanes
/// through the REAL relay under 60% i.i.d. loss. Five seeds. If the rig's
/// "sender DONE but receiver ladder silent" split reproduces anywhere,
/// this catches it with the receiver's internal state printed.
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

/// In-process loopback pair for the messenger (announcement path).
final class _LoopPort implements DataChannelPort {
  late _LoopPort peer;
  final _in = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    final copy = List<int>.from(frame);
    Future<void>.delayed(Duration.zero, () {
      if (!peer._in.isClosed) peer._in.add(copy);
    });
  }

  @override
  Future<void> close() async {
    await _in.close();
  }
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
  test('full 5b shape x5 seeds: announcement over ReliableMessenger + '
      'fountain lanes over the real relay at 60% loss — ladder must verify '
      'every time the sender finishes', () async {
    final repoRoot = Directory.current.parent.parent.path;
    final proc = await Process.start(
      'dart',
      ['run', 'bin/datagram_relay.dart', '--port', '0'],
      workingDirectory: '$repoRoot/server/signaling_server',
    );
    addTearDown(proc.kill);
    final readiness = await proc.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('datagram relay listening on'))
        .timeout(const Duration(seconds: 60));
    final relayPort = int.parse(readiness.split(':').last.trim());

    for (var round = 0; round < 5; round++) {
      final key = DatagramLanePort.roomKeyFromCallId('probe-5b-r$round');
      final txRaw = await DatagramLanePort.bind(
          relayHost: '127.0.0.1', relayPort: relayPort, roomKey: key);
      final rxRaw = await DatagramLanePort.bind(
          relayHost: '127.0.0.1', relayPort: relayPort, roomKey: key);
      final tx = _LossySend(txRaw, 600, 0x1111 + round);
      final rx = _LossySend(rxRaw, 600, 0x9999 + round);

      final mA = _LoopPort();
      final mB = _LoopPort();
      mA.peer = mB;
      mB.peer = mA;
      final senderMessenger = ReliableMessenger(mA, peerId: 'a');
      final receiverMessenger = ReliableMessenger(mB, peerId: 'b');

      final receiver = StagedPhotoReceiver.fountain(
        rx,
        expireAfter: const Duration(minutes: 5),
      );
      final stages = <PhotoStage>[];
      final verified = Completer<void>();
      final sub = receiver.updates.listen((u) {
        stages.add(u.stage);
        if (u.stage == PhotoStage.originalVerified &&
            !verified.isCompleted) {
          verified.complete();
        }
      });
      receiverMessenger.incoming.listen((m) {
        receiver.offerText(m.text);
      });
      final sender = StagedPhotoSender.fountain(
        tx,
        announce: (text) async {
          await senderMessenger.send(text);
        },
        symbolBytes: 1024,
        floorBytesPerSec: 32 * 1024,
        staleAfter: const Duration(seconds: 30),
      );

      final artifacts = StagedPhotoArtifacts(
        thumbHash: Uint8List.fromList(List<int>.filled(30, round + 1)),
        preview: _bytes(15 * 1024, 0x2545F491 + round),
        original: _bytes(96 * 1024, 0x1E552901 + round),
        width: 2048,
        height: 1536,
      );

      final res = await sender
          .deliver(artifacts)
          .timeout(const Duration(minutes: 4));
      try {
        await verified.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        final ladder = receiver.photos[res.announcement.photoId];
        fail('round $round: sender finished but ladder silent — '
            'stages=$stages photos=${receiver.photos.keys.toList()} '
            'stage=${ladder?.stage} sha=${ladder?.sha256Verified}');
      }
      print('ROUND $round ok stages=$stages '
          'sent=${res.sentSymbols}/${res.totalSourceSymbols}');

      await sub.cancel();
      await receiver.close();
      await senderMessenger.close();
      await receiverMessenger.close();
      await txRaw.close();
      await rxRaw.close();
    }
  });
}
