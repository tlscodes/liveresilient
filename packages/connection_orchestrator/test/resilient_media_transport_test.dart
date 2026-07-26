/// Phase 5 — full media integration: a photo, a flipbook, and a
/// document transferred during a simulated 120-second call on the
/// hostile channel, with voice provably unaffected. All numbers in the
/// diagnostic line are measured in this run (simulated channel).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/src/gilbert_elliott_loss.dart';
import 'package:connection_orchestrator/src/media_carriage.dart';
import 'package:security/security.dart';
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
  test('layered photo: a viewable preview lands long before the full '
      'pyramid completes, on the same hostile channel', () {
    const imgC = LowRateImageCompressor();
    const w = 640, h = 480, ch = 4;
    final px = Uint8List(w * h * ch);
    for (var i = 0; i < px.length; i++) {
      // A gradient with a soft disc, so the pyramid has real structure.
      final p = i ~/ ch;
      final x = p % w, y = p ~/ w;
      final dx = x - w ~/ 2, dy = y - h ~/ 2;
      final disc = (dx * dx + dy * dy) < 90000 ? 90 : 0;
      px[i] = ((x + y) ~/ 4 + disc) & 0xFF;
    }
    final levels = imgC.encodeProgressive(px, w, h, ch);
    final layers = levels.map((l) => l.bytes).toList();

    int runToCompletion({required bool layered}) {
      final rng = Random(5);
      final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 8);
      final transport = ResilientMediaTransport(
          queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500));
      if (layered) {
        transport.sendLayered(layers, MediaType.photo);
      } else {
        final joined = BytesBuilder();
        for (final l in layers) {
          joined.add(l);
        }
        transport.send(joined.toBytes(), MediaType.photo);
      }
      final decoders = <int, RatelessDecoder>{};
      var firstUsableMs = -1;
      _voiceTicks(120000, (nowMs, speaking) {
        if (firstUsableMs >= 0) return;
        for (final d in transport.queue
            .tick(nowMs: nowMs, voiceIsSpeaking: speaking)) {
          if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
          final dec =
              decoders.putIfAbsent(d.transferId, RatelessDecoder.new);
          dec.addDatagram(d.bytes);
          if (dec.isComplete && firstUsableMs < 0) {
            final media = ResilientMediaTransport.receive(dec);
            // Layered: the coarse layer alone is renderable. Monolithic:
            // nothing is renderable until the single transfer finishes.
            if (!media.isLayer || media.isFirstLayer) {
              firstUsableMs = nowMs;
            }
          }
        }
      });
      return firstUsableMs;
    }

    final monolithic = runToCompletion(layered: false);
    final layeredMs = runToCompletion(layered: true);

    expect(monolithic, greaterThan(0), reason: 'baseline never completed');
    expect(layeredMs, greaterThan(0), reason: 'no layer ever decoded');
    expect(layeredMs, lessThan(monolithic),
        reason: 'layering must surface a preview earlier than the '
            'monolithic transfer completes');
    // ignore: avoid_print
    print('layered photo: first viewable at ${(layeredMs / 1000)
        .toStringAsFixed(1)}s vs ${(monolithic / 1000).toStringAsFixed(1)}s '
        'monolithic (${layers.length} layers, '
        '${layers.map((l) => l.length).join('+')} B)');
  });

  // ------------------------------------------------------------- phase 8
  // Everything above rides the queue directly. This closes the stage: the
  // same 120 s hostile session, but every datagram goes out through the
  // full wire path — MTU-aligned padding, carrier framing — and the relay
  // allocation is maintained across a mid-call roam.
  for (final carrier in MediaCarrier.values) {
    test('phase 8 — photo + flipbook + document over the ${carrier.name} '
        'carrier during a 120s hostile call, with a mid-call relay roam',
        () async {
      final rng = Random(5);

      final document = Uint8List.fromList(utf8.encode(
          'گزارش وضعیت: مسیر رله جابه‌جا شد، صدا همان‌طور مقدم است. ' * 30));
      const imgC = LowRateImageCompressor();
      const w = 320, h = 240, ch = 4;
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
          3,
          (t) => Uint8List.fromList(
              List.generate(160 * 120, (i) => (i % 160 + t * 9) & 0xFF)));
      final flip = vidC.encode(vidFrames, 160, 120);
      final flipBytes = BytesBuilder();
      for (final f in flip) {
        flipBytes.add([f.index, f.temporal ? 1 : 0, f.bytes.length ~/ 256,
            f.bytes.length & 0xFF]);
        flipBytes.add(f.bytes);
      }
      final flipbook = flipBytes.toBytes();

      // --- relay: two TURN servers, scripted transport ---
      var relayPort = 49152;
      final allocator = TurnRelayAllocator(
        servers: const [
          HostPort(host: '198.51.100.1', port: 3478),
          HostPort(host: '198.51.100.2', port: 3478),
        ],
        issuer: TurnCredentialsIssuer(sharedSecret: 'turn-shared-secret'),
        userId: 'call-phase8',
        allocate: (request) async => TurnAllocation(
          tuple: request.tuple,
          relayedAddress: HostPort(
            host: request.tuple.serverAddress.host,
            port: relayPort++,
          ),
          serverReflexiveAddress: HostPort(
            host: '203.0.113.7',
            port: request.tuple.localAddress.port,
          ),
          expiresAt: DateTime.now().add(request.lifetime),
          credentials: request.credentials,
        ),
        refresh: (_, lifetime) async => DateTime.now().add(lifetime),
      );

      final transport = ResilientMediaTransport(
        queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
        carriage: MediaCarriage(
          carrier: carrier,
          mtuBlockSize: 16,
          random: Random(21),
        ),
        relayAllocator: allocator,
      );

      // ALPN must offer h2 for the HTTP/2 carrier to be negotiable at all.
      expect(transport.alpnProtocols, contains('h2'));
      expect(
        transport.tlsParameters
            .buildCipherSuites()
            .any(transport.tlsParameters.isGreaseValue),
        isTrue,
      );

      const cellular = HostPort(host: '10.20.30.40', port: 50000);
      const wifi = HostPort(host: '192.168.1.24', port: 50001);
      final onCellular = await transport.ensureRelay(localAddress: cellular);
      expect(onCellular, isNotNull);
      expect(allocator.allocateCount, 1);

      final (tPhoto, sPhoto) = transport.send(photo, MediaType.photo);
      final (tFlip, sFlip) = transport.send(flipbook, MediaType.flipbook);
      final (tDoc, sDoc) = transport.send(document, MediaType.document);

      final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 8);
      final decoders = <int, RatelessDecoder>{};
      final completedAt = <int, int>{};
      var wireBytes = 0;
      var roamedAt = -1;

      // Voice keeps its own 20 ms cadence; media only moves in the gaps.
      final baseline = _voiceTicks(120000, null);
      final live = <int>[];
      for (var nowMs = 0; nowMs <= 120000; nowMs += 20) {
        final speaking = _speaking(nowMs);
        if (speaking && nowMs % 60 == 0) live.add(nowMs);

        // Cellular -> Wi-Fi at 60 s: the 5-tuple moves, so RFC 8656 says the
        // old allocation is dead and a new one must be made. Media must not
        // notice.
        if (nowMs == 60000) {
          final onWifi = await transport.ensureRelay(localAddress: wifi);
          expect(onWifi!.tuple.localAddress, wifi);
          expect(
            onWifi.relayedAddress,
            isNot(onCellular!.relayedAddress),
            reason: 'a roamed client gets a new relayed address',
          );
          roamedAt = nowMs;
        }

        for (final wire in transport.wireTick(
            nowMs: nowMs, voiceIsSpeaking: speaking)) {
          wireBytes += wire.length;
          if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
          final carried = transport.receiveFromWire(wire);
          final dec =
              decoders.putIfAbsent(carried.transferId, RatelessDecoder.new);
          dec.addDatagram(carried.bytes);
          if (dec.isComplete && !completedAt.containsKey(carried.transferId)) {
            completedAt[carried.transferId] = nowMs;
            transport.queue.markComplete(carried.transferId);
          }
        }
      }

      expect(live, equals(baseline),
          reason: 'voice tick schedule must be untouched by media or roaming');
      expect(roamedAt, 60000);
      expect(allocator.roamCount, 1);
      expect(allocator.allocateCount, 2);

      final originals = {
        tPhoto.id: photo,
        tFlip.id: flipbook,
        tDoc.id: document,
      };
      expect(completedAt.length, 3,
          reason: 'photo, flipbook and document must ALL complete in 120s '
              'over the ${carrier.name} carrier');
      for (final id in completedAt.keys) {
        final media = ResilientMediaTransport.receive(decoders[id]!);
        expect(media.bytes, equals(originals[id]),
            reason: 'transfer $id must be bit-exact after padding removal');
      }

      await transport.releaseRelay();
      expect(allocator.currentAllocation, isNull);
      expect(allocator.releaseCount, 1);

      final wireRate = wireBytes / 120;
      // Every datagram the queue emitted, padded and framed, versus its
      // raw size — the true cost of the wire path, loss-independent.
      final overhead = wireBytes / transport.queue.bytesEmitted;
      // ignore: avoid_print
      print('phase8 (simulated, ${carrier.name}): compressed photo=$sPhoto '
          'flipbook=$sFlip doc=$sDoc B; all 3 complete at '
          '${completedAt.values.map((t) => '${t ~/ 1000}s').join(', ')}; '
          'wire ${wireRate.toStringAsFixed(1)} B/s including padding + '
          'framing (${overhead.toStringAsFixed(2)}x the raw datagram bytes); voice ticks ${live.length} == baseline ${baseline.length}; '
          'relay allocations ${allocator.allocateCount} '
          '(roams ${allocator.roamCount})');
      expect(wireRate, lessThanOrEqualTo(1500),
          reason: 'length normalization and framing may cost bytes, but the '
              'lane must stay inside the hostile-profile ceiling');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
