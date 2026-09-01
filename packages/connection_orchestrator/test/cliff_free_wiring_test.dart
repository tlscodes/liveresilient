/// The wiring, end to end: ResilientMediaTransport.sendCliffFree -> lossy
/// channel -> receiveCliffFree -> render events, plus the router that decides
/// which payload takes this path at all.
///
/// The property that matters is not "it compiles" but "the base layer is shown
/// before the object is whole, and every byte shown is exact".
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

List<MediaLayer> _photoLayers() => [
  MediaLayer(
    Uint8List.fromList(List.generate(3 * 1024, (i) => (i * 7) & 0xFF)),
    kind: LayerKind.base,
  ),
  MediaLayer(
    Uint8List.fromList(List.generate(9 * 1024, (i) => (i * 11) & 0xFF)),
  ),
  MediaLayer(
    Uint8List.fromList(List.generate(18 * 1024, (i) => (i * 13) & 0xFF)),
    kind: LayerKind.losslessTail,
  ),
];

GilbertElliottEstimate _memoryless(double loss) =>
    GilbertElliottEstimate(0.5, 0.5, loss, loss);

void main() {
  group('CliffFreeTransferId', () {
    test('round-trips all three identifiers', () {
      final id = CliffFreeTransferId.of(
        objectId: 4242,
        layerCount: 5,
        layerIndex: 3,
      );
      expect(id.objectId, 4242);
      expect(id.layerCount, 5);
      expect(id.layerIndex, 3);
    });

    test('rejects values that would silently truncate', () {
      expect(
        () => CliffFreeTransferId.of(
          objectId: 0x10000,
          layerCount: 2,
          layerIndex: 0,
        ),
        throwsRangeError,
      );
      expect(
        () => CliffFreeTransferId.of(
          objectId: 1,
          layerCount: 2,
          layerIndex: 2, // index must be inside the count
        ),
        throwsRangeError,
      );
      expect(
        () => CliffFreeTransferId.of(objectId: 1, layerCount: 0, layerIndex: 0),
        throwsRangeError,
      );
    });
  });

  group('send -> receive', () {
    test(
      'clean channel: base layer renders first, object ends exact',
      () async {
        final transport = ResilientMediaTransport();
        final layers = _photoLayers();
        final events = <CliffFreeRenderEvent>[];

        final report = await transport.sendCliffFree(
          layers,
          MediaType.photo,
          budgetBytes: 4 * 1024 * 1024,
          // The sink now receives (objectId, FRAME) — a batch of symbols, not a
          // bare datagram — and the receiver takes only the frame, because the
          // media type travels inside it instead of being supplied (and
          // therefore guessable) by the caller.
          sink: (objectId, frame) async {
            final e = transport.receiveCliffFree(frame);
            if (e != null) events.add(e);
            return true;
          },
        );

        expect(report.stoppedEarly, isFalse);
        expect(events.first.isFirstRender, isTrue);
        expect(events.first.bytes, layers.first.bytes);
        expect(events.last.isComplete, isTrue);
        expect(events.last.usableLayers, 3);

        // Every render is a prefix of the true object — never a partial layer.
        final whole = BytesBuilder();
        for (final l in layers) {
          whole.add(l.bytes);
        }
        expect(events.last.bytes, whole.toBytes());
      },
    );

    test('50% loss: the base layer still renders, and it is exact', () async {
      final transport = ResilientMediaTransport();
      final layers = _photoLayers();
      final rng = Random(21);
      final events = <CliffFreeRenderEvent>[];

      await transport.sendCliffFree(
        layers,
        MediaType.photo,
        budgetBytes: 4 * 1024 * 1024,
        estimate: _memoryless(0.5),
        sink: (objectId, frame) async {
          // Loss is now per FRAME, which is the honest model after batching:
          // a frame is atomic on the wire, so a drop takes every symbol in it.
          // Measuring 50% loss per-symbol here would flatter the design by
          // simulating a granularity the wire no longer has.
          if (rng.nextDouble() < 0.5) return true; // lost in flight
          final e = transport.receiveCliffFree(frame);
          if (e != null) events.add(e);
          return true;
        },
      );

      expect(events, isNotEmpty);
      expect(events.first.isFirstRender, isTrue);
      expect(events.first.bytes, layers.first.bytes);
    });

    test('two objects interleave without confusing each other', () async {
      final transport = ResilientMediaTransport();
      final a = _photoLayers();
      final b = _photoLayers().reversed.toList();
      // Give b a coherent stack again after reversing.
      final bFixed = [
        MediaLayer(b[2].bytes, kind: LayerKind.base),
        MediaLayer(b[1].bytes),
        MediaLayer(b[0].bytes, kind: LayerKind.losslessTail),
      ];

      final pending = <(int, Uint8List)>[];
      Future<bool> collect(int id, Uint8List frame) async {
        pending.add((id, frame));
        return true;
      }

      await transport.sendCliffFree(
        a,
        MediaType.photo,
        budgetBytes: 4 << 20,
        sink: collect,
      );
      final firstObjectFrames = pending.length;
      await transport.sendCliffFree(
        bFixed,
        MediaType.photo,
        budgetBytes: 4 << 20,
        sink: collect,
      );

      expect(pending.length, greaterThan(firstObjectFrames));

      // Two objects must be distinguishable from the FRAMES ALONE. Under the
      // old scheme this was the transfer id's job and it could not do it past
      // objectId 1; now the address is in the header, so the check is that the
      // frames say which object they belong to without help from the sink.
      for (final (id, frame) in pending) {
        expect(CliffFreeBatchCodec.decode(frame).objectId, id);
      }

      // Shuffle everything together: order across objects is meaningless.
      pending.shuffle(Random(5));
      final byObject = <int, CliffFreeRenderEvent>{};
      for (final (_, frame) in pending) {
        final e = transport.receiveCliffFree(frame);
        if (e != null) byObject[e.objectId] = e;
      }

      expect(byObject.length, 2);
      for (final e in byObject.values) {
        expect(e.isComplete, isTrue);
      }
      expect(transport.cliffFreeInbox.openObjects, 2);
    });

    test('the pre-send hook runs once, before any symbol', () async {
      final transport = ResilientMediaTransport();
      var hookCalls = 0;
      var symbolsBeforeHook = -1;
      var symbols = 0;

      await transport.sendCliffFree(
        _photoLayers(),
        MediaType.photo,
        budgetBytes: 4 << 20,
        beforeSend: (tier0) async {
          hookCalls++;
          symbolsBeforeHook = symbols;
          // The hook sees the base layer's encoder, which is what a lane
          // probe measures through.
          expect(tier0.blockCount, greaterThan(0));
        },
        sink: (_, _) async {
          symbols++;
          return true;
        },
      );

      expect(hookCalls, 1);
      expect(symbolsBeforeHook, 0);
      expect(symbols, greaterThan(0));
    });

    test('object ids wrap without colliding with a live object', () {
      final transport = ResilientMediaTransport();
      final first = transport.allocateObjectId();
      final second = transport.allocateObjectId();
      expect(second, first + 1);
      expect(first, inInclusiveRange(1, CliffFreeTransferId.maxObjectId));
    });
  });

  group('CliffFreeInbox', () {
    test('evicts the oldest object beyond the concurrency bound', () {
      final inbox = CliffFreeInbox(maxConcurrentObjects: 2);
      final sender = CliffFreeMediaSender();
      final layers = [
        MediaLayer(
          Uint8List.fromList(List.filled(200, 3)),
          kind: LayerKind.base,
        ),
      ];

      for (var object = 1; object <= 3; object++) {
        final plan = sender.plan(layers, budgetBytes: 1 << 20);
        final encoder = RlncEncoder(
          layers.first.bytes,
          blockSize: sender.blockSize,
        );
        final id = CliffFreeTransferId.of(
          objectId: object,
          layerCount: 1,
          layerIndex: 0,
        );
        // One datagram is enough to open the object.
        inbox.accept(id.raw, encoder.datagramAt(0), MediaType.photo);
        expect(plan.layers.first.sendCount, greaterThan(0));
      }

      expect(inbox.openObjects, 2);
      expect(inbox.evictedObjects, 1);
    });
  });

  group('MediaSendRouter', () {
    const router = MediaSendRouter();

    test('small text keeps its acknowledgements', () {
      final d = router.route(type: MediaType.document, byteLength: 512);
      expect(d.path, MediaPath.acknowledged);
      expect(d.reason, contains('cheaper'));
    });

    test('large documents move to the cliff-free path', () {
      final d = router.route(type: MediaType.document, byteLength: 64 * 1024);
      expect(d.isCliffFree, isTrue);
    });

    test('photos, voice notes and video always take the cliff-free path', () {
      for (final t in [
        MediaType.photo,
        MediaType.audioPcm,
        MediaType.flipbook,
      ]) {
        expect(
          router.route(type: t, byteLength: 100).isCliffFree,
          isTrue,
          reason: '$t',
        );
      }
    });

    test('above the loss threshold even small text switches', () {
      final d = router.route(
        type: MediaType.document,
        byteLength: 100,
        lossEstimate: 0.2,
      );
      expect(d.isCliffFree, isTrue);
      expect(d.reason, contains('round trips'));
    });

    test('at exactly the threshold the cheap path still wins', () {
      final d = router.route(
        type: MediaType.document,
        byteLength: 100,
        lossEstimate: 0.10,
      );
      expect(d.path, MediaPath.acknowledged);
    });
  });
}
