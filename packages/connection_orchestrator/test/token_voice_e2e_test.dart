/// End-to-end desert call, microphone to speaker (simulated device
/// codec): PCM -> VoiceCodecBinding.encodeFrames -> hamseda blocks ->
/// pulsing DTN link -> in-order replay -> decodeFrames -> PCM.
/// Pins that the WHOLE lane fits together: token integrity across the
/// full pipeline and audio of the right shape coming out the far end.
library;

import 'dart:math';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

void main() {
  test('mic-to-speaker over a pulsing link: tokens survive bit-exact and '
      'audio comes out frame-aligned', () async {
    final codec = SimulatedVoiceCodecBinding(installed: true);
    final info = await codec.modelInfo;
    expect(info.nRows, 2);

    // 8 seconds of synthetic "speech" at 24kHz-ish frame granularity
    final rng = Random(5);
    final samples = [
      for (var i = 0; i < 160 * 300; i++) sin(i / 17) * (rng.nextDouble()),
    ];
    final tokens = await codec.encodeFrames(samples);
    expect(tokens.length, 300);

    final queue = DtnBundleQueue();
    final sender = TokenVoiceSender(nRows: info.nRows, queue: queue);
    final receiver = TokenVoiceReceiver(nRows: info.nRows);

    // send in 25-frame blocks over a link alive 1 pulse in 4
    var nowMs = 0;
    for (var i = 0; i < tokens.length; i += 25) {
      sender.sendBlock(
        tokens.sublist(i, min(i + 25, tokens.length)),
        nowMs: nowMs,
      );
      if ((i ~/ 25) % 4 == 3) {
        await queue.flush((bundle) async {
          receiver.offer(bundle.payload);
          return true;
        }, nowMs: nowMs);
      }
      nowMs += 333;
    }
    await queue.flush((bundle) async {
      receiver.offer(bundle.payload);
      return true;
    }, nowMs: nowMs);

    // token integrity end-to-end
    final received = [for (final block in receiver.played) ...block];
    expect(received, equals(tokens), reason: 'bit-exact across the lane');

    // and the speaker end produces frame-aligned audio
    final out = await codec.decodeFrames(received);
    expect(
      out.length,
      samples.length,
      reason: '160 samples per token column, nothing dropped',
    );
  });
}
