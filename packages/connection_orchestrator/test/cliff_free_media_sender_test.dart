/// The send path as a unit: plan -> encode -> emit -> reassemble, including a
/// lossy channel, because a cliff-free sender that only works at 0% loss is the
/// thing this whole design exists to avoid.
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

List<MediaLayer> _layers() => [
  MediaLayer(
    Uint8List.fromList(List.generate(3 * 1024, (i) => (i * 7) & 0xFF)),
    kind: LayerKind.base,
  ),
  MediaLayer(
    Uint8List.fromList(List.generate(12 * 1024, (i) => (i * 11) & 0xFF)),
  ),
  MediaLayer(
    Uint8List.fromList(List.generate(24 * 1024, (i) => (i * 13) & 0xFF)),
    kind: LayerKind.losslessTail,
  ),
];

int _sourceBytes(List<MediaLayer> ls) =>
    ls.fold(0, (a, l) => a + l.bytes.length);

GilbertElliottEstimate _memoryless(double loss) =>
    GilbertElliottEstimate(0.5, 0.5, loss, loss);

/// Collects emitted datagrams, optionally dropping them, and feeds a
/// reassembler — the receiving half of the same pipeline.
class _Channel {
  _Channel(this.layerCount, {this.loss = 0.0, int seed = 7})
    : reassembler = CliffFreeReassembler(layerCount: layerCount),
      _rng = Random(seed);

  final int layerCount;
  final double loss;
  final CliffFreeReassembler reassembler;
  final Random _rng;

  int sent = 0;
  int delivered = 0;
  int bytesDelivered = 0;
  int bytesToFirstBase = -1;
  final List<int> layerOrder = [];

  bool accept(int layerIndex, Uint8List datagram) {
    sent++;
    if (layerOrder.isEmpty || layerOrder.last != layerIndex) {
      layerOrder.add(layerIndex);
    }
    if (_rng.nextDouble() < loss) return true; // accepted by the lane, lost
    delivered++;
    bytesDelivered += datagram.length;
    reassembler.addDatagram(layerIndex, datagram);
    if (bytesToFirstBase < 0 && reassembler.usableLayerCount >= 1) {
      bytesToFirstBase = bytesDelivered;
    }
    return true;
  }
}

void main() {
  group('planning', () {
    test('block counts match what RlncEncoder would produce', () {
      final sender = CliffFreeMediaSender();
      final layers = _layers();
      final plan = sender.plan(layers, budgetBytes: 10 * 1024 * 1024);

      for (var i = 0; i < layers.length; i++) {
        final direct = RlncEncoder(
          layers[i].bytes,
          blockSize: sender.blockSize,
        ).blockCount;
        expect(plan.layers[i].blockCount, direct, reason: 'layer $i');
      }
    });

    test('block size is pinned to the framing mandate', () {
      expect(
        CliffFreeMediaSender().blockSize,
        LayeredRedundancyAllocator.mandatedBlockSize,
      );
      expect(CliffFreeMediaSender().blockSize, 55);
    });

    test('the base layer is funded before refinements under a tight budget',
        () {
      final layers = _layers();
      final sender = CliffFreeMediaSender();
      final baseBlocks = sender
          .plan(layers, budgetBytes: 1 << 30)
          .layers
          .first
          .blockCount;

      // Enough for L0 with margin, nowhere near enough for the rest.
      final plan = sender.plan(
        layers,
        budgetBytes: baseBlocks * 60 * 3,
        lossPrior: 0.2,
      );

      expect(plan.layers.first.sendCount, greaterThan(baseBlocks));
      expect(plan.layers.first.fullyProtected, isTrue);
      expect(plan.layers.last.sendCount, 0);
    });

    test('rejects empty and oversized layer lists', () {
      final sender = CliffFreeMediaSender();
      expect(
        () => sender.plan(const [], budgetBytes: 1000),
        throwsArgumentError,
      );
      final many = List.generate(
        256,
        (_) => MediaLayer(Uint8List.fromList([1, 2, 3])),
      );
      expect(() => sender.plan(many, budgetBytes: 1000), throwsArgumentError);
    });

    test('rejects an incoherent layer stack', () {
      final sender = CliffFreeMediaSender();
      final bytes = Uint8List.fromList(List.filled(64, 7));

      // A refinement first: nothing would be renderable before layer 1.
      expect(
        () => sender.plan([MediaLayer(bytes)], budgetBytes: 1 << 20),
        throwsArgumentError,
      );
      // A base layer that is not first.
      expect(
        () => sender.plan([
          MediaLayer(bytes, kind: LayerKind.segment),
          MediaLayer(bytes, kind: LayerKind.base),
        ], budgetBytes: 1 << 20),
        throwsArgumentError,
      );
      // A lossless tail with layers after it.
      expect(
        () => sender.plan([
          MediaLayer(bytes, kind: LayerKind.base),
          MediaLayer(bytes, kind: LayerKind.losslessTail),
          MediaLayer(bytes),
        ], budgetBytes: 1 << 20),
        throwsArgumentError,
      );
      // An empty layer would encode to a datagram carrying nothing.
      expect(
        () => sender.plan([
          MediaLayer(Uint8List(0), kind: LayerKind.base),
        ], budgetBytes: 1 << 20),
        throwsArgumentError,
      );
      // Self-contained segments are a valid stack with no base layer at all.
      expect(
        () => sender.plan([
          MediaLayer(bytes, kind: LayerKind.segment),
          MediaLayer(bytes, kind: LayerKind.segment),
        ], budgetBytes: 1 << 20),
        returnsNormally,
      );
    });
  });

  group('send', () {
    test('clean channel: every layer decodes and is byte-identical', () async {
      final layers = _layers();
      final channel = _Channel(layers.length);
      final report = await CliffFreeMediaSender().send(
        layers,
        sink: channel.accept,
        budgetBytes: 10 * 1024 * 1024,
        // A WARM estimator reporting zero loss. Without it the cold-start law
        // applies (factor 1.2/(1-0) = 1.2, L0 x1.25) and absolute overhead is
        // ~1.34x BY DESIGN — the cold law's insurance premium, priced for not
        // knowing the channel. The 1.10x figure in the spec is the RELATIVE
        // gate (layered vs flat through the same stack), where redundancy
        // cancels; the absolute number below is framing 60/55 = 1.091 plus
        // block padding plus the planner's small epsilon.
        estimate: _memoryless(0.0),
      );

      expect(report.stoppedEarly, isFalse);
      expect(channel.reassembler.isComplete, isTrue);
      for (var i = 0; i < layers.length; i++) {
        expect(channel.reassembler.layerData(i), layers[i].bytes);
      }
      expect(report.overheadFactor(_sourceBytes(layers)), lessThan(1.16));
    });

    test('cold start on a clean channel pays the insurance premium, visibly',
        () async {
      // The same send WITHOUT an estimate. The cold law (F-3) charges ~20%
      // redundancy plus a 25% L0 margin because it cannot know the channel is
      // clean. This test pins that price so it is a documented property, not a
      // surprise: if someone "optimizes" the cold factor to 1.0, the 50%-loss
      // test below is what they will break.
      final layers = _layers();
      final channel = _Channel(layers.length);
      final report = await CliffFreeMediaSender().send(
        layers,
        sink: channel.accept,
        budgetBytes: 10 * 1024 * 1024,
      );

      expect(channel.reassembler.isComplete, isTrue);
      final overhead = report.overheadFactor(_sourceBytes(layers));
      expect(overhead, greaterThan(1.25));
      expect(overhead, lessThan(1.45));
    });

    test('emission is base-layer first, never interleaved', () async {
      final layers = _layers();
      final channel = _Channel(layers.length);
      await CliffFreeMediaSender().send(
        layers,
        sink: channel.accept,
        budgetBytes: 10 * 1024 * 1024,
      );
      expect(channel.layerOrder, [0, 1, 2]);
    });

    test('50% loss: the base layer still decodes exactly', () async {
      final layers = _layers();
      final channel = _Channel(layers.length, loss: 0.5, seed: 11);
      await CliffFreeMediaSender().send(
        layers,
        sink: channel.accept,
        budgetBytes: 10 * 1024 * 1024,
        estimate: _memoryless(0.5),
      );

      expect(channel.reassembler.usableLayerCount, greaterThanOrEqualTo(1));
      expect(channel.reassembler.layerData(0), layers.first.bytes);
      expect(channel.bytesToFirstBase, greaterThan(0));
    });

    test('a fixed low factor is what fails — the estimator is what saves it',
        () async {
      // The measured F-2 finding, as an executable statement: planning for a
      // clean channel and then running at 50% loss must NOT decode the base
      // layer, while planning WITH the estimate (previous test) does.
      final layers = _layers();
      final channel = _Channel(layers.length, loss: 0.5, seed: 11);
      await CliffFreeMediaSender().send(
        layers,
        sink: channel.accept,
        budgetBytes: 10 * 1024 * 1024,
        lossPrior: 0.0,
      );
      expect(channel.reassembler.usableLayerCount, 0);
    });

    test('a layer past the ESI ceiling is capped, not thrown', () async {
      // The reachable crash: RlncEncoder refuses esi > 0xFFFF, and a ~300 KB
      // layer at the 90%-loss factor of 12 plans ~65,500 symbols. One step
      // larger and an unclamped sender throws mid-object — losing an object
      // that was already 99% delivered. The cap turns that into a reported
      // under-protection the caller can act on.
      final big = Uint8List.fromList(
        List.generate(300 * 1024, (i) => (i * 29) & 0xFF),
      );
      final layers = [MediaLayer(big, kind: LayerKind.base)];
      var emitted = 0;

      final report = await CliffFreeMediaSender().send(
        layers,
        budgetBytes: 1 << 30, // no budget pressure: only the ESI space binds
        estimate: _memoryless(0.9),
        sink: (_, _) async {
          emitted++;
          return true;
        },
      );

      expect(report.esiCappedLayers, [0]);
      expect(report.datagramsEmitted, 0x10000);
      expect(emitted, 0x10000);
      expect(report.plan.layers.first.sendCount, greaterThan(0x10000));
      // Capped means under-protected for the estimate, and saying so is the
      // point: the caller can split the layer or lower the target.
      expect(report.stoppedEarly, isFalse);
    });

    test('a layer inside the ESI ceiling is not capped', () async {
      final layers = _layers();
      final report = await CliffFreeMediaSender().send(
        layers,
        budgetBytes: 1 << 30,
        estimate: _memoryless(0.5),
        sink: (_, _) async => true,
      );
      expect(report.esiCappedLayers, isEmpty);
    });

    test('a refusing sink stops the pass without corrupting the prefix',
        () async {
      final layers = _layers();
      final reassembler = CliffFreeReassembler(layerCount: layers.length);
      var accepted = 0;
      final report = await CliffFreeMediaSender().send(
        layers,
        budgetBytes: 10 * 1024 * 1024,
        sink: (layerIndex, datagram) {
          if (accepted >= 40) return false;
          accepted++;
          reassembler.addDatagram(layerIndex, datagram);
          return true;
        },
      );

      expect(report.stoppedEarly, isTrue);
      expect(report.datagramsEmitted, 40);
      // Whatever decoded is still exact; nothing is half-written.
      for (var i = 0; i < reassembler.usableLayerCount; i++) {
        expect(reassembler.layerData(i), layers[i].bytes);
      }
    });
  });
}
