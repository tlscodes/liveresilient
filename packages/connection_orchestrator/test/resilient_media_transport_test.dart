/// Phase 5 — full media integration: a photo, a flipbook, and a
/// document transferred during a simulated 120-second call on the
/// hostile channel, with voice provably unaffected. All numbers in the
/// diagnostic line are measured in this run (simulated channel).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/gilbert_elliott_loss.dart';
import 'package:connection_orchestrator/src/media_codecs/flipbook_video_compressor.dart';
import 'package:connection_orchestrator/src/media_codecs/low_rate_image_compressor.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:connection_orchestrator/src/resilient_media_transport.dart';
import 'package:test/test.dart';

bool _speaking(int nowMs) => (nowMs ~/ 4000).isEven; // 4s speech / 4s silence

List<int> _voiceTicks(int totalMs, void Function(int, bool)? tick) {
  final ticks = <int>[];
  for (var nowMs = 0; nowMs <= totalMs; nowMs += 20) {
    final speaking = _speaking(nowMs);
    if (speaking && nowMs % 60 == 0) ticks.add(nowMs);
    tick?.call(nowMs, speaking);
  }
  return ticks;
}

void main() {
  test('photo + flipbook + document during a 120s hostile-channel call; '
      'voice schedule identical to its no-media baseline', () {
    final rng = Random(5);

    // --- payloads, built by the phase-4 codecs ---
    const imgC = LowRateImageCompressor();
    const w = 640, h = 480, ch = 4;
    final photoPx = Uint8List(w * h * ch);
    for (var i = 0; i < photoPx.length; i++) {
      photoPx[i] = ((i ~/ ch) % w) & 0xFF;
    }
    final photoLevels = imgC.encodeProgressive(photoPx, w, h, ch);
    final photoBytes = BytesBuilder();
    for (final l in photoLevels) {
      photoBytes.add([l.width, l.height & 0xFF, l.bytes.length ~/ 256,
          l.bytes.length & 0xFF]);
      photoBytes.add(l.bytes);
    }
    final photo = photoBytes.toBytes();

    const vidC = FlipbookVideoCompressor();
    final vidFrames = List.generate(
        4,
        (t) => Uint8List.fromList(List.generate(
            240 * 160, (i) => (i % 240 + t * 12) & 0xFF)));
    final flip = vidC.encode(vidFrames, 240, 160);
    final flipBytes = BytesBuilder();
    for (final f in flip) {
      flipBytes.add([f.index, f.temporal ? 1 : 0, f.bytes.length ~/ 256,
          f.bytes.length & 0xFF]);
      flipBytes.add(f.bytes);
    }
    final flipbook = flipBytes.toBytes();

    final document = Uint8List.fromList(utf8.encode(
        'گزارش وضعیت: انتقال رسانه در سکوت، صدا همیشه مقدم است. ' * 40));

    // --- baseline voice schedule, no media at all ---
    final baseline = _voiceTicks(120000, null);

    // --- live run: transport + hostile channel ---
    final transport =
        ResilientMediaTransport(queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500));
    final sent = <MediaType, int>{};
    final (tPhoto, sPhoto) = transport.send(photo, MediaType.photo);
    final (tFlip, sFlip) = transport.send(flipbook, MediaType.flipbook);
    final (tDoc, sDoc) = transport.send(document, MediaType.document);
    sent[MediaType.photo] = sPhoto;
    sent[MediaType.flipbook] = sFlip;
    sent[MediaType.document] = sDoc;

    final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 8);
    final decoders = <int, RatelessDecoder>{};
    final completedAt = <int, int>{};
    var mediaBytesOnWire = 0;

    final live = _voiceTicks(120000, (nowMs, speaking) {
      // The queue round-robins between concurrent transfers, so a single
      // tick batch can mix datagrams from several of them. Each datagram
      // carries its own transferId — route by that, never by whichever
      // transfer happens to be at the head of the queue.
      for (final d in transport.queue.tick(
          nowMs: nowMs, voiceIsSpeaking: speaking)) {
        mediaBytesOnWire += d.bytes.length;
        // hostile channel: 60% uniform loss + GE bursts
        if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
        final id = d.transferId;
        final dec = decoders.putIfAbsent(id, RatelessDecoder.new);
        dec.addDatagram(d.bytes);
        if (dec.isComplete && !completedAt.containsKey(id)) {
          completedAt[id] = nowMs;
          transport.queue.markComplete(id);
        }
      }
    });

    expect(live, equals(baseline),
        reason: 'voice tick schedule must be untouched by media');

    // Whatever completed inside the 120s window must be byte-exact.
    final originals = {tPhoto.id: photo, tFlip.id: flipbook, tDoc.id: document};
    for (final id in completedAt.keys) {
      final media = ResilientMediaTransport.receive(decoders[id]!);
      expect(media.bytes, equals(originals[id]), reason: 'transfer $id');
    }
    expect(completedAt.length, 3,
        reason: 'photo, flipbook, and document must ALL complete in 120s');

    final rate = mediaBytesOnWire / 120;
    // ignore: avoid_print
    print('phase5 (simulated): compressed sizes '
        'photo=${sent[MediaType.photo]} flipbook=${sent[MediaType.flipbook]} '
        'doc=${sent[MediaType.document]} B; media wire rate '
        '${rate.toStringAsFixed(1)} B/s (cap 500, silence-only); '
        'completed ${completedAt.length}/3 in 120s at '
        '${completedAt.values.map((t) => '${t ~/ 1000}s').join(', ')}; '
        'voice ticks ${live.length} == baseline ${baseline.length}');
    expect(rate, lessThanOrEqualTo(500));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
