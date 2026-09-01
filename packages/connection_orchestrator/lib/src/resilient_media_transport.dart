/// Phase 5 — one facade over the whole media stage: per-type front-end
/// compression -> rateless coding -> background queue with strict voice
/// priority. `send(bytes, type)` on one side, `onReceived` on the other.
///
/// Type routing (lab winners, measured 2026-07-25):
///   document -> LiveContextCompressor (own CM codec, lossless)
///   photo    -> progressive thumbnail pyramid (lossy preview form)
///   audioPcm -> QuantizedLpc front-end + CM (lossless)
///   flipbook -> caller pre-codes frames (FlipbookVideoCompressor) and
///               sends the serialized frame stream as a document payload
///
/// Transfer framing (before rateless coding): u8 type · u32 length ·
/// payload. The transport claim is EXACT delivery of these bytes; lossy
/// codecs upstream never dilute that claim.
library;

import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

import 'blind_channel_estimator.dart';
import 'cliff_free_batch.dart';
import 'cliff_free_inbox.dart';
import 'cliff_free_media_sender.dart';
import 'gf256_rlnc_stream.dart';
import 'layered_redundancy_allocator.dart';
import 'media_carriage.dart';
import 'media_codecs/live_context_compressor.dart';
import 'media_codecs/media_frontends.dart';
import 'media_queue.dart';
import 'rateless_stream.dart';
import 'wire_trace_recorder.dart';

enum MediaType { document, photo, audioPcm, flipbook }

class ReceivedMedia {
  ReceivedMedia(this.type, this.bytes, {this.layerIndex, this.layerCount});
  final MediaType type;
  final Uint8List bytes;

  /// Set when this payload is one layer of a layered transfer.
  final int? layerIndex;
  final int? layerCount;

  bool get isLayer => layerIndex != null;

  /// True for the coarsest layer, the one worth rendering immediately.
  bool get isFirstLayer => layerIndex == 0;
}

class ResilientMediaTransport {
  ResilientMediaTransport({
    MediaTransferQueue? queue,
    this.carriage,
    this.relayAllocator,
    this.relayLink,
    this.secureSession,
    this.edgeBridge,
    this.wireTrace,
    TlsParameterNormalizer? tlsParameters,
  }) : queue = queue ?? MediaTransferQueue(),
       tlsParameters = tlsParameters ?? TlsParameterNormalizer();

  final MediaTransferQueue queue;

  /// Phase 7 advanced wire security: when set, every wire datagram carries a
  /// sequence header, incoming datagrams must clear the session's anti-replay
  /// window (replays throw [ReplayedDatagramException]), and admitted traffic
  /// drives the session's HKDF key-rotation budget. Null keeps the plain wire
  /// format earlier phases were measured with.
  final SecureTransportSession? secureSession;

  /// Phase 6/8 wire side: MTU-aligned padding plus carrier framing. Null keeps
  /// the pure-queue behavior earlier phases were measured with.
  final MediaCarriage? carriage;

  /// Phase 8 relay side. Null means no relay is in use (direct path only).
  final TurnRelayAllocator? relayAllocator;

  /// Phase 8 advanced: bound TURN channel for the relayed path. When set,
  /// every wire datagram travels as ChannelData (RFC 8656 section 12.4 —
  /// 4-byte header instead of a ~36-byte Send indication), applied OUTERMOST
  /// so the relay strips it before the secure-session and carriage layers.
  final ChannelRelayLink? relayLink;

  /// Optional egress lane: when set, [flushWireTick] writes each framed
  /// datagram to a pool of edge endpoints using standard gRPC message
  /// framing, continuing the message sequence across endpoint failover.
  /// Null keeps this transport pure — the caller takes [wireTick]'s frames
  /// and moves them itself.
  final DomesticEdgeBridgeLane? edgeBridge;

  /// Optional passive wire-trace recorder. When set, each frame handed to
  /// [edgeBridge] in a flush is recorded as one `tx` record and each
  /// datagram entering [receiveFromWire] as one `rx` record — sizes and
  /// timing only, never payload content. Null (the default) disables
  /// recording at zero per-frame cost.
  final WireTraceRecorder? wireTrace;

  /// The TLS 1.3 client parameter set this transport negotiates with.
  final TlsParameterNormalizer tlsParameters;

  static const _cm = LiveContextCompressor();

  /// Standard ALPN identifiers offered on the TLS handshake (RFC 7301
  /// registrations; `h2` is the one the HTTP/2 carrier needs).
  List<String> get alpnProtocols =>
      TlsParameterNormalizer.standardAlpnProtocols;

  /// Makes sure a relay allocation is in place for [localAddress], allocating,
  /// refreshing or re-allocating as RFC 8656 requires. Returns null when this
  /// transport was built without a relay allocator.
  Future<TurnAllocation?> ensureRelay({required HostPort localAddress}) async {
    final allocator = relayAllocator;
    if (allocator == null) return null;
    return allocator.ensure(localAddress: localAddress);
  }

  /// Releases the relay allocation, if any (RFC 8656 section 7).
  Future<void> releaseRelay() => relayAllocator?.release() ?? Future.value();

  /// One tick of the media queue, framed for the wire.
  ///
  /// Requires a [carriage]; without one there is no wire format to produce.
  List<Uint8List> wireTick({
    required int nowMs,
    required bool voiceIsSpeaking,
  }) {
    final wire = carriage;
    if (wire == null) {
      throw StateError('wireTick needs a MediaCarriage; none was configured');
    }
    final session = secureSession;
    final relay = relayLink;
    Uint8List frame(TaggedDatagram d) {
      final sealed = session == null
          ? wire.wrap(d)
          : session.seal(wire.wrap(d));
      return relay == null ? sealed : relay.wrap(sealed);
    }

    return [
      for (final d in queue.tick(
        nowMs: nowMs,
        voiceIsSpeaking: voiceIsSpeaking,
      ))
        frame(d),
    ];
  }

  /// Runs one [wireTick] and sends its frames over [edgeBridge], in order,
  /// after any frames a previous flush could not deliver.
  ///
  /// Returns one [SendResult] per frame attempted. Sending stops at the
  /// first frame the lane could not deliver, so within a flush the receiver
  /// never sees a gap followed by later frames, and the returned list is
  /// shorter than the attempted frame count. The undelivered remainder
  /// (the failed frame included) is not dropped: it is retained and sent at
  /// the start of the next flush, ahead of that tick's new frames, so wire
  /// order is preserved across flushes too. Under sustained failure the
  /// retained backlog is capped at [_maxPendingFrames]; beyond that the
  /// oldest frames are dropped — upstream rateless coding treats a dropped
  /// datagram as ordinary symbol loss, not corruption.
  ///
  /// Throws [StateError] when no [edgeBridge] was configured, or when a
  /// previous flush is still in flight: two overlapping flushes would
  /// interleave their frames on the wire, which is exactly the ordering
  /// this method exists to preserve. Callers tick one at a time.
  Future<List<SendResult>> flushWireTick({
    required int nowMs,
    required bool voiceIsSpeaking,
  }) async {
    final lane = edgeBridge;
    if (lane == null) {
      throw StateError(
        'flushWireTick needs a DomesticEdgeBridgeLane; none was configured',
      );
    }
    if (_flushInFlight) {
      throw StateError(
        'flushWireTick is already running; overlapping flushes would '
        'reorder frames on the wire',
      );
    }
    _flushInFlight = true;
    try {
      return await _flushFrames(lane, nowMs, voiceIsSpeaking);
    } finally {
      _flushInFlight = false;
    }
  }

  bool _flushInFlight = false;

  /// Frames a previous flush could not deliver, oldest first. Consumed at
  /// the start of the next flush, before that tick's new frames. Only
  /// touched under the [_flushInFlight] guard.
  final List<Uint8List> _pendingFrames = [];

  /// Upper bound on the retained backlog. Beyond it the oldest frames are
  /// dropped; the rateless coding upstream regenerates their coverage.
  static const int _maxPendingFrames = 1024;

  Future<List<SendResult>> _flushFrames(
    DomesticEdgeBridgeLane lane,
    int nowMs,
    bool voiceIsSpeaking,
  ) async {
    // Build the combined list before clearing, so a throwing wireTick
    // leaves the pending backlog intact.
    final frames = <Uint8List>[
      ..._pendingFrames,
      ...wireTick(nowMs: nowMs, voiceIsSpeaking: voiceIsSpeaking),
    ];
    _pendingFrames.clear();
    final results = <SendResult>[];
    var next = 0;
    try {
      while (next < frames.length) {
        wireTrace?.recordTx(frames[next].length);
        final result = await lane.send(frames[next]);
        results.add(result);
        if (!result.delivered) break;
        next++;
      }
    } finally {
      // Retain the unattempted remainder (and the failed frame) whether we
      // stopped on a non-delivered result or lane.send threw.
      if (next < frames.length) {
        var remainder = frames.sublist(next);
        if (remainder.length > _maxPendingFrames) {
          remainder = remainder.sublist(remainder.length - _maxPendingFrames);
        }
        _pendingFrames.addAll(remainder);
      }
    }
    return results;
  }

  /// Reverses [wireTick] for one datagram taken off the wire.
  ///
  /// With a [secureSession], the sequence header is checked first: a replayed
  /// or stale datagram throws [ReplayedDatagramException] before any carriage
  /// parsing happens.
  CarriedDatagram receiveFromWire(Uint8List bytes) {
    final wire = carriage;
    if (wire == null) {
      throw StateError(
        'receiveFromWire needs a MediaCarriage; none was configured',
      );
    }
    wireTrace?.recordRx(bytes.length);
    final session = secureSession;
    final relay = relayLink;
    final unrelayed = relay == null ? bytes : relay.unwrap(bytes);
    return wire.unwrap(session == null ? unrelayed : session.open(unrelayed));
  }

  /// Compress per type and enqueue. Returns (transfer, compressedSize).
  (MediaTransfer, int) send(Uint8List bytes, MediaType type) {
    final compressed = _compress(bytes, type);
    final framed = Uint8List(5 + compressed.length);
    framed[0] = type.index;
    ByteData.sublistView(framed).setUint32(1, bytes.length);
    framed.setRange(5, framed.length, compressed);
    return (queue.enqueue(framed), compressed.length);
  }

  static Uint8List _compress(Uint8List bytes, MediaType type) {
    switch (type) {
      case MediaType.audioPcm:
        return _cm.compress(QuantizedLpc.encode(bytes));
      case MediaType.document:
      case MediaType.photo:
      case MediaType.flipbook:
        // photo/flipbook arrive pre-coded by their phase-4 codecs; the
        // CM pass here squeezes framing/header redundancy losslessly.
        return _cm.compress(bytes);
    }
  }

  /// Enqueue [layers] as independent transfers, coarsest first.
  ///
  /// Each layer is its own rateless stream, so the queue's round-robin
  /// scheduler advances all of them together and the receiver can use
  /// layer 0 the moment it decodes rather than waiting for the whole
  /// object. Returns one (transfer, compressedSize) record per layer, in
  /// the order given.
  List<(MediaTransfer, int)> sendLayered(
    List<Uint8List> layers,
    MediaType type,
  ) {
    if (layers.isEmpty) throw ArgumentError('no layers to send');
    if (layers.length > 0xFF) {
      throw ArgumentError('at most 255 layers per object');
    }
    final out = <(MediaTransfer, int)>[];
    for (var i = 0; i < layers.length; i++) {
      final compressed = _compress(layers[i], type);
      // u8 type | u32 original length | u8 layer index | u8 layer count
      final framed = Uint8List(7 + compressed.length);
      framed[0] = type.index | _layeredFlag;
      ByteData.sublistView(framed).setUint32(1, layers[i].length);
      framed[5] = i;
      framed[6] = layers.length;
      framed.setRange(7, framed.length, compressed);
      out.add((queue.enqueue(framed), compressed.length));
    }
    return out;
  }

  /// High bit of the type byte marks a layered frame, so a receiver can
  /// tell the two framings apart without a separate channel.
  static const int _layeredFlag = 0x80;

  // ---------------------------------------------------------------------
  // Cliff-free path
  //
  // [sendLayered] above rides `MediaTransferQueue`, whose rateless stage is
  // the LT code (measured epsilon 1.33). The cliff-free path uses GF(256)
  // RLNC instead (epsilon ~1.004) with estimator-driven per-layer redundancy,
  // so it does not share that queue: at 90% loss the difference between 1.33
  // and 1.004 is the difference between arriving and not.
  //
  // The two paths coexist on purpose. `MediaSendRouter` decides which one a
  // payload takes; neither is removed, because the acknowledged path is still
  // the cheaper answer for small text on a good link.
  // ---------------------------------------------------------------------

  final CliffFreeMediaSender _cliffFreeSender = CliffFreeMediaSender();

  /// Receive side of the cliff-free path.
  final CliffFreeInbox cliffFreeInbox = CliffFreeInbox();

  int _nextObjectId = 1;

  /// Allocates the next object id, wrapping inside the 16 bits the transfer id
  /// reserves for it. Wrapping is safe because ids only have to be unique
  /// among objects in flight, and [CliffFreeInbox] holds at most a handful.
  int allocateObjectId() {
    final id = _nextObjectId;
    _nextObjectId = _nextObjectId >= CliffFreeTransferId.maxObjectId
        ? 1
        : _nextObjectId + 1;
    return id;
  }

  /// Sends [layers] as rateless symbols, base layer first, BATCHED into
  /// self-describing frames.
  ///
  /// [sink] receives `(objectId, frame)` and returns false to stop the pass —
  /// a full lane or a closed session. Stopping early is not an error: whatever
  /// decoded on the far side is still exact.
  ///
  /// WHY IT IS `objectId` AND NOT `transferId`, AND WHY THE RENAME MATTERS.
  ///
  /// This used to emit one bare 60-byte datagram per call, addressed by a
  /// 32-bit `CliffFreeTransferId` packing (objectId · layerCount · layerIndex).
  /// Two measurements retired that scheme (Run I):
  ///
  /// - `MediaCarriage.maxTransferId` is `0xFFFF`, and objectId occupies the
  ///   HIGH sixteen bits, so `wrap` threw on the second object ever sent. The
  ///   throw was the good outcome: truncation would have mapped two objects
  ///   onto one address, past an aliasing guard that cannot see it because the
  ///   layerCounts match, and two photos would have decoded into one and
  ///   rendered as a success.
  /// - A 60-byte datagram costs 218.6 bytes mean on the wire (x3.64), because
  ///   `MicroDatagramLane` adds up to three whole blocks of anti-fingerprinting
  ///   jitter. That padding is a real defence, correctly implemented; its cost
  ///   is simply ABSOLUTE while the datagram is tiny.
  ///
  /// Batching fixes the second and dissolves the first. The pad is paid once
  /// per frame (x1.24 at ten symbols), and the nine-byte batch header carries
  /// the layer address in-band — so the carriage id needs to hold only
  /// `objectId`, and sixteen bits is exactly a u16 objectId. The media type
  /// travels too, which it never did before: the receiver used to invent the
  /// value that decides how an object renders.
  ///
  /// The parameter is renamed rather than kept, so that every call site has to
  /// be read rather than silently compiling against a different meaning.
  ///
  /// [budgetBytes] caps the spend for this object. [estimate] is the blind
  /// channel model when the estimator is warm; [lossPrior] drives the measured
  /// cold-start law otherwise. [linkBytesPerSecond] sizes the frames: a frame
  /// is atomic, so on a slow link a large one is simply a delay before
  /// anything can render. Null means "rate unknown", which takes the
  /// conservative default rather than assuming a fast link.
  ///
  /// [beforeSend] runs once before any symbol is emitted, with the base
  /// layer's encoder. This is where lane aggregation is decided: the probe
  /// measures through THESE symbols (so it costs nothing extra) and the caller
  /// applies the verdict to its router before the object starts flowing.
  Future<LayeredSendReport> sendCliffFree(
    List<MediaLayer> layers,
    MediaType type, {
    required Future<bool> Function(int objectId, Uint8List frame) sink,
    required int budgetBytes,
    int? objectId,
    GilbertElliottEstimate? estimate,
    double lossPrior = 0.0,
    double? linkBytesPerSecond,
    Duration headBudget = const Duration(milliseconds: 500),
    Future<void> Function(RlncEncoder tier0Encoder)? beforeSend,
  }) async {
    final id = objectId ?? allocateObjectId();
    final layerCount = layers.length;
    if (layerCount > 0xFF) {
      throw ArgumentError.value(
        layerCount,
        'layers.length',
        'the batch header carries layerCount in one byte',
      );
    }

    if (beforeSend != null && layers.isNotEmpty) {
      await beforeSend(
        RlncEncoder(
          layers.first.bytes,
          blockSize: LayeredRedundancyAllocator.mandatedBlockSize,
        ),
      );
    }

    if (layers.isEmpty) {
      return _cliffFreeSender.send(
        layers,
        budgetBytes: budgetBytes,
        estimate: estimate,
        lossPrior: lossPrior,
        sink: (_, __) async => true,
      );
    }

    final batcher = linkBytesPerSecond == null
        ? CliffFreeBatcher(objectId: id, type: type, layerCount: layerCount)
        : CliffFreeBatcher.forLink(
            objectId: id,
            type: type,
            layerCount: layerCount,
            bytesPerSecond: linkBytesPerSecond,
            headBudget: headBudget,
          );

    // A sink that has refused once must not be called again: `false` means the
    // lane is full or the session is closed, and the batcher's tail flush
    // would otherwise push one more frame at a peer that already said stop.
    var stopped = false;

    final report = await _cliffFreeSender.send(
      layers,
      budgetBytes: budgetBytes,
      estimate: estimate,
      lossPrior: lossPrior,
      sink: (layerIndex, datagram) async {
        if (stopped) return false;
        final frame = batcher.add(layerIndex, datagram);
        if (frame == null) return true;
        final accepted = await sink(id, frame);
        if (!accepted) stopped = true;
        return accepted;
      },
    );

    // THE TAIL IS NOT OPTIONAL. Symbols accumulated since the last full frame
    // are real bytes the allocator already budgeted for and the encoder already
    // produced; dropping them silently would cost decode rank on exactly the
    // marginal transfers this path exists to rescue. Emitting it after
    // `send` returns is correct even when the pass stopped early — except when
    // the sink is the thing that stopped it.
    if (!stopped) {
      final tail = batcher.flush();
      if (tail != null) await sink(id, tail);
    }

    return report;
  }

  /// Feeds one received cliff-free FRAME to the inbox.
  ///
  /// Returns the most advanced render event the frame produced, or null if the
  /// renderable prefix did not grow. Growth is the whole point: the base layer
  /// is shown while the rest is still in flight.
  ///
  /// The media type is no longer a parameter. It arrives inside the frame, so
  /// a caller can no longer supply a type the sender never chose — which it
  /// previously had to, since nothing on the wire carried one.
  ///
  /// Throws [CliffFreeBatchException] for a frame that claims this format and
  /// then contradicts itself. That is deliberate: a malformed frame on a
  /// lossy link is either an attack or a bug, and swallowing it makes both
  /// look like packet loss — the one confusion this transport can least
  /// afford. Use [CliffFreeBatchCodec.tryDecode] first if the lane is shared
  /// with traffic that is legitimately not ours.
  CliffFreeRenderEvent? receiveCliffFree(Uint8List frame) {
    final batch = CliffFreeBatchCodec.decode(frame);
    CliffFreeRenderEvent? latest;
    for (final symbol in batch.symbols) {
      final id = CliffFreeTransferId.of(
        objectId: batch.objectId,
        layerCount: batch.layerCount,
        layerIndex: batch.layerIndex,
      );
      final event = cliffFreeInbox.accept(id.raw, symbol, batch.type);
      // Every symbol is offered even after one produces an event: a later
      // symbol in the same frame can complete a further layer, and returning
      // on the first growth would leave decoded data unreported until the next
      // frame arrived.
      if (event != null) latest = event;
    }
    return latest;
  }

  /// Reassemble one completed transfer on the receiving side.
  static ReceivedMedia receive(RatelessDecoder decoder) {
    final framed = decoder.data;
    final layered = (framed[0] & _layeredFlag) != 0;
    final type = MediaType.values[framed[0] & ~_layeredFlag];
    final originalLen = ByteData.sublistView(framed).getUint32(1);
    if (layered) {
      final compressed = Uint8List.sublistView(framed, 7);
      final bytes = type == MediaType.audioPcm
          ? QuantizedLpc.decode(_cm.decompress(compressed), originalLen)
          : _cm.decompress(compressed);
      return ReceivedMedia(
        type,
        bytes,
        layerIndex: framed[5],
        layerCount: framed[6],
      );
    }
    final compressed = Uint8List.sublistView(framed, 5);
    switch (type) {
      case MediaType.audioPcm:
        return ReceivedMedia(
          type,
          QuantizedLpc.decode(_cm.decompress(compressed), originalLen),
        );
      case MediaType.document:
      case MediaType.photo:
      case MediaType.flipbook:
        return ReceivedMedia(type, _cm.decompress(compressed));
    }
  }
}
