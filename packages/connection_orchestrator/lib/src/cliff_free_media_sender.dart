/// The cliff-free send path, as a production unit.
///
/// WHY THIS FILE EXISTS. `RlncEncoder`, `LayeredRedundancyAllocator` and
/// `CliffFreeReassembler` were all written, tested and barrel-exported, but the
/// composition that joins them lived only inside
/// `test/cliff_free_channel_sim_test.dart`. A pipeline that exists only in a
/// test is a claim, not a feature: nothing in the app could send a layered
/// object. This class is that composition, moved where callers can reach it.
///
/// What it does NOT do, on purpose:
/// - it does not compress. Layers arrive already coded by their front-end
///   (`LowRateImageCompressor` pyramid levels, `FlipbookVideoCompressor`
///   frames, document text/full split). Mixing entropy coding into the
///   erasure path would make a failed decode indistinguishable from a failed
///   decompress.
/// - it does not retransmit, ack, or negotiate. That is the whole point: the
///   symbol stream is rateless, so the only tuning knob is HOW MANY symbols,
///   which is [LayeredRedundancyAllocator]'s job.
/// - it does not choose lanes. It emits datagrams to a sink; the fabric routes
///   them. Multi-lane aggregation is decided by `LaneAggregationProbe` through
///   [RlncProbeCarrier], not here.
library;

import 'dart:async';
import 'dart:typed_data';

import 'blind_channel_estimator.dart';
import 'gf256_rlnc_stream.dart';
import 'layered_redundancy_allocator.dart';

/// Where an emitted symbol goes. Returns false when the sink refused it (a
/// closed lane, a full queue) so the sender can stop early instead of
/// pretending the bytes left the device.
typedef LayerDatagramSink =
    FutureOr<bool> Function(int layerIndex, Uint8List datagram);

/// One layer as handed to the sender.
class MediaLayer {
  const MediaLayer(this.bytes, {this.kind = LayerKind.refinement});

  final Uint8List bytes;
  final LayerKind kind;
}

/// What a layer contributes, so a renderer can decide whether an out-of-order
/// layer is showable on its own (frames) or only as part of a prefix
/// (refinements). Mirrors the `kind` byte of the object manifest.
enum LayerKind {
  /// The base layer: the first thing worth rendering.
  base,

  /// An embedded refinement — meaningful only above the layers below it.
  refinement,

  /// A self-contained time segment (flipbook frames): renderable alone.
  segment,

  /// The residual that makes the object bit-exact.
  losslessTail,
}

/// Result of one send pass — what was planned, what was actually emitted.
class LayeredSendReport {
  const LayeredSendReport({
    required this.plan,
    required this.datagramsEmitted,
    required this.bytesEmitted,
    required this.stoppedEarly,
    this.sinkThrew = false,
    this.esiCappedLayers = const [],
  });

  /// The pass ended because the sink raised, not because it declined.
  ///
  /// Separate from [stoppedEarly] because the recoveries differ: a sink that
  /// returns false is applying backpressure and a retry later is reasonable; a
  /// sink that throws is broken, and retrying into it is how a transient fault
  /// becomes a loop.
  final bool sinkThrew;

  final AllocationResult plan;
  final int datagramsEmitted;
  final int bytesEmitted;

  /// True when the sink refused a datagram and the pass ended before the plan
  /// was exhausted. Not an error: a rateless stream that stops early simply
  /// delivered less quality, and the receiver's prefix is still exact.
  final bool stoppedEarly;

  /// Layers whose planned send count exceeded the 16-bit ESI space and were
  /// clamped to 65,536 symbols. Reachable in the wild: a ~300 KB layer at the
  /// 90%-loss factor of 12 plans ~65,500 symbols — one step larger and an
  /// unclamped sender would throw inside `RlncEncoder.datagramAt` mid-object.
  /// A clamped layer is under-protected for the estimate, which the caller can
  /// see here and choose to split the layer or lower the target.
  final List<int> esiCappedLayers;

  /// Overhead against the bare source bytes of the layers actually funded.
  double overheadFactor(int sourceBytes) =>
      sourceBytes == 0 ? 0 : bytesEmitted / sourceBytes;
}

/// Encodes layers as independent RLNC streams and emits them base-layer first.
class CliffFreeMediaSender {
  CliffFreeMediaSender({
    LayeredRedundancyAllocator? allocator,
    this.plannerTrials = 200,
  }) : allocator = allocator ?? LayeredRedundancyAllocator();

  final LayeredRedundancyAllocator allocator;
  final int plannerTrials;

  int get blockSize => allocator.blockSize;

  /// Plans the spend for [layers] without emitting anything.
  ///
  /// [budgetBytes] is the wire budget for this object. [estimate] is the
  /// blind channel model when one exists (warm path); otherwise [lossPrior]
  /// drives the measured cold-start law. A caller with neither passes 0 and
  /// gets the clean-channel plan.
  AllocationResult plan(
    List<MediaLayer> layers, {
    required int budgetBytes,
    GilbertElliottEstimate? estimate,
    double lossPrior = 0.0,
  }) => _planFrom(
    _encodersFor(layers),
    budgetBytes: budgetBytes,
    estimate: estimate,
    lossPrior: lossPrior,
  );

  /// Builds one encoder per layer after checking the layer stack is coherent.
  ///
  /// Validation is not decoration: a stack whose base layer is not first would
  /// make the "renderable prefix" of the reassembler meaningless, and the
  /// failure would show up as a blank first render rather than as an error.
  List<RlncEncoder> _encodersFor(List<MediaLayer> layers) {
    if (layers.isEmpty) throw ArgumentError('no layers');
    if (layers.length > 0xFF) throw ArgumentError('at most 255 layers');
    for (var i = 0; i < layers.length; i++) {
      final l = layers[i];
      if (l.bytes.isEmpty) {
        throw ArgumentError('layer $i is empty');
      }
      if (l.kind == LayerKind.base && i != 0) {
        throw ArgumentError('the base layer must be layer 0, found one at $i');
      }
      if (i == 0 && l.kind == LayerKind.refinement) {
        throw ArgumentError(
          'layer 0 is a refinement: nothing would be renderable first',
        );
      }
      if (l.kind == LayerKind.losslessTail && i != layers.length - 1) {
        throw ArgumentError('the lossless tail must be the last layer');
      }
    }
    return [for (final l in layers) RlncEncoder(l.bytes, blockSize: blockSize)];
  }

  /// Block counts come from the encoders themselves rather than from a copy of
  /// their arithmetic: a private re-implementation would silently disagree the
  /// day the framing changes, and the allocator would then fund the wrong
  /// number of symbols.
  AllocationResult _planFrom(
    List<RlncEncoder> encoders, {
    required int budgetBytes,
    GilbertElliottEstimate? estimate,
    double lossPrior = 0.0,
  }) {
    return allocator.allocate(
      blockCounts: [for (final e in encoders) e.blockCount],
      budgetBytes: budgetBytes,
      estimate: estimate,
      lossPrior: lossPrior,
      plannerTrials: plannerTrials,
    );
  }

  /// Emits the planned symbols, layer 0 first.
  ///
  /// Order within a layer is the encoder's ESI order, which begins with the
  /// systematic prefix — so the earliest arrivals are source blocks and a
  /// receiver can show something before any generation reaches full rank.
  /// Across layers the order is strictly base-first, because the whole design
  /// is that the coarse layer must not wait behind refinements.
  Future<LayeredSendReport> send(
    List<MediaLayer> layers, {
    required LayerDatagramSink sink,
    required int budgetBytes,
    GilbertElliottEstimate? estimate,
    double lossPrior = 0.0,
  }) async {
    final encoders = _encodersFor(layers);
    final allocation = _planFrom(
      encoders,
      budgetBytes: budgetBytes,
      estimate: estimate,
      lossPrior: lossPrior,
    );

    var datagrams = 0;
    var bytes = 0;
    var stoppedEarly = false;
    var sinkError = false;
    final esiCapped = <int>[];

    /// One past the largest ESI `RlncEncoder`'s u16 header can carry.
    const esiSpace = 0x10000;

    outer:
    for (var li = 0; li < layers.length; li++) {
      var sendCount = allocation.layers[li].sendCount;
      if (sendCount > esiSpace) {
        sendCount = esiSpace;
        esiCapped.add(li);
      }
      for (var esi = 0; esi < sendCount; esi++) {
        final datagram = encoders[li].datagramAt(esi);
        // A SINK THAT THROWS MUST NOT LOSE THE REPORT.
        //
        // Previously an exception escaped mid-object: the datagram and byte
        // counts died with it, and the caller could not tell whether the base
        // layer had already gone out or nothing had. Since a rateless stream
        // that stops early is still exact on whatever decoded, the useful
        // answer is always "here is how far it got" — never a stack trace in
        // place of a report.
        bool accepted;
        try {
          accepted = await sink(li, datagram);
        } on Object {
          sinkError = true;
          stoppedEarly = true;
          break outer;
        }
        if (!accepted) {
          stoppedEarly = true;
          break outer;
        }
        datagrams++;
        bytes += datagram.length;
      }
    }

    return LayeredSendReport(
      plan: allocation,
      datagramsEmitted: datagrams,
      bytesEmitted: bytes,
      stoppedEarly: stoppedEarly,
      sinkThrew: sinkError,
      esiCappedLayers: List.unmodifiable(esiCapped),
    );
  }
}
