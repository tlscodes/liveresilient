// Standalone probe: drive the real fountain classes at 60% loss and dump
// sender/receiver internals once per second so an endgame stall names its
// own cause. Run: dart run tool/fountain_probe.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:messaging/messaging.dart';

class LossyPort implements DataChannelPort {
  LossyPort(this.lossPerMille, this.seed);
  final int lossPerMille;
  int seed;
  LossyPort? peer;
  int sent = 0;
  int dropped = 0;
  final inboundCtrl = StreamController<List<int>>.broadcast(sync: true);

  @override
  Stream<List<int>> get inbound => inboundCtrl.stream;

  bool drop() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed % 1000) < lossPerMille;
  }

  @override
  Future<void> send(List<int> frame) async {
    sent++;
    if (drop()) {
      dropped++;
      return;
    }
    final copy = Uint8List.fromList(frame);
    scheduleMicrotask(() {
      final p = peer;
      if (p != null && !p.inboundCtrl.isClosed) p.inboundCtrl.add(copy);
    });
  }

  @override
  Future<void> close() async {
    await inboundCtrl.close();
  }
}

Uint8List content(int bytes) {
  final out = Uint8List(bytes);
  for (var i = 0; i < bytes; i++) {
    out[i] = (i * 31 + (i >> 8) * 17) & 0xFF;
  }
  return out;
}

Future<void> main() async {
  final tx = LossyPort(600, 0x1234);
  final rx = LossyPort(600, 0x9876);
  tx.peer = rx;
  rx.peer = tx;

  final done = Completer<void>();
  final receiver = FountainStreamReceiver(
    rx,
    stateInterval: const Duration(milliseconds: 20),
    onCompleted: (_) {
      print('RECEIVER COMPLETED');
      if (!done.isCompleted) done.complete();
    },
  );
  final sender = FountainStreamSender(
    tx,
    symbolBytes: 1024,
    generationSize: 8,
    stateInterval: const Duration(milliseconds: 20),
    staleAfter: const Duration(seconds: 10),
    floorBytesPerSec: 512 * 1024,
  );

  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    print(
      'tick ${sender.diag()} txSent=${tx.sent} txDrop=${tx.dropped} '
      'rxSent=${rx.sent} rxDrop=${rx.dropped}',
    );
  });

  try {
    final result = await sender
        .send(content(64 * 1024))
        .timeout(const Duration(seconds: 25));
    print(
      'SENDER DONE sent=${result.sentSymbols} '
      'of=${result.totalSourceSymbols}',
    );
  } catch (e) {
    print('SENDER FAILED: $e');
  } finally {
    ticker.cancel();
    await receiver.dispose();
    await tx.close();
    await rx.close();
  }
}
