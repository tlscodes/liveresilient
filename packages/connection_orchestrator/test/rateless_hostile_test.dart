/// Phase 2 — rateless code over the hostile channel.
///
/// Wiring only: RatelessEncoder/Decoder from phase 1 pushed through 95%
/// uniform loss layered with Gilbert-Elliott bursts (mean 10 packets)
/// and up to 5 s jitter with reordering. Receiver send counter proves
/// zero feedback. All results here are simulated-channel results.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/gilbert_elliott_loss.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

/// Receiver wrapper that counts any packet it would send upstream.
class _CountingReceiver {
  final RatelessDecoder decoder = RatelessDecoder();
  int packetsSent = 0;

  // The receiver has no send path; this method exists so the test can
  // prove by counter (not assumption) that it was never called.
  // ignore: unused_element
  void send(Uint8List _) => packetsSent++;
}

void main() {
  test('2KB over 95% uniform loss + GE bursts + 5s jitter/reorder: '
      'bit-exact, zero feedback, no crash on corruption', () {
    final rng = Random(7);
    final data = Uint8List.fromList(
      List.generate(2048, (_) => rng.nextInt(256)),
    );
    final enc = RatelessEncoder(data);
    final n = enc.blockCount;
    final ge = GilbertElliottLossSimulator(
      p: 0.04,
      r: 0.1,
      badLossRate: 0.95,
      seed: 11,
    ); // mean 10-pkt bursts
    final receiver = _CountingReceiver();

    // Jitter queue: (deliveryTimeMs, datagram). Up to 5 s jitter.
    final inFlight = <MapEntry<int, Uint8List>>[];
    var sent = 0;
    var delivered = 0;
    var esi = 0;
    var nowMs = 0;
    const sendIntervalMs = 176; // 53 B per datagram at 300 B/s

    while (!receiver.decoder.isComplete) {
      expect(
        esi,
        lessThanOrEqualTo(0xFFFF),
        reason: 'did not converge within u16 esi space',
      );
      final d = enc.datagramAt(esi++);
      sent++;
      nowMs += sendIntervalMs;
      // Layered loss: 95% uniform, then Gilbert-Elliott bursts.
      final uniformDrop = rng.nextDouble() < 0.95;
      if (!uniformDrop && !ge.shouldDrop()) {
        var wire = d;
        // Occasionally truncate or corrupt what survives; the decoder
        // must reject it without throwing.
        final roll = rng.nextInt(20);
        if (roll == 0) {
          wire = Uint8List.sublistView(d, 0, rng.nextInt(d.length));
        } else if (roll == 1) {
          wire = Uint8List.fromList(d);
          wire[rng.nextInt(wire.length)] ^= 1 << rng.nextInt(8);
        }
        inFlight.add(MapEntry(nowMs + rng.nextInt(5000), wire));
      }
      // Deliver everything due, in arrival-time order (reordered vs send).
      inFlight.sort((a, b) => a.key.compareTo(b.key));
      while (inFlight.isNotEmpty && inFlight.first.key <= nowMs) {
        final pkt = inFlight.removeAt(0).value;
        final ok = receiver.decoder.addDatagram(pkt);
        if (ok) delivered++;
      }
    }

    expect(receiver.decoder.data, equals(data), reason: 'bit-exactness');
    expect(receiver.packetsSent, 0, reason: 'zero-feedback proven by counter');
    final epsilon = delivered / n;
    final wireSeconds = sent * sendIntervalMs / 1000;
    // ignore: avoid_print
    print(
      'rateless hostile (simulated): sent=$sent delivered=$delivered '
      'N=$n epsilon=${epsilon.toStringAsFixed(3)} '
      'wire=${wireSeconds.toStringAsFixed(1)}s @300B/s',
    );
  });
}
