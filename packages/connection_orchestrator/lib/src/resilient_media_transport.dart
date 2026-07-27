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

import 'media_carriage.dart';
import 'media_codecs/live_context_compressor.dart';
import 'media_codecs/media_frontends.dart';
import 'media_queue.dart';
import 'rateless_stream.dart';

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
    TlsParameterNormalizer? tlsParameters,
  })  : queue = queue ?? MediaTransferQueue(),
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

  /// The TLS 1.3 client parameter set this transport negotiates with.
  final TlsParameterNormalizer tlsParameters;

  static const _cm = LiveContextCompressor();

  /// Standard ALPN identifiers offered on the TLS handshake (RFC 7301
  /// registrations; `h2` is the one the HTTP/2 carrier needs).
  List<String> get alpnProtocols => TlsParameterNormalizer.standardAlpnProtocols;

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
      final sealed =
          session == null ? wire.wrap(d) : session.seal(wire.wrap(d));
      return relay == null ? sealed : relay.wrap(sealed);
    }

    return [
      for (final d in queue.tick(nowMs: nowMs, voiceIsSpeaking: voiceIsSpeaking))
        frame(d),
    ];
  }

  /// Runs one [wireTick] and sends every frame over [edgeBridge], in order.
  ///
  /// Returns one [SendResult] per frame. Sending stops at the first frame
  /// the lane could not deliver, so the caller never sees a gap followed by
  /// later frames — the undelivered remainder simply is not attempted, and
  /// the returned list is shorter than the tick's frame count.
  ///
  /// Throws [StateError] when no [edgeBridge] was configured.
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
    final results = <SendResult>[];
    for (final frame
        in wireTick(nowMs: nowMs, voiceIsSpeaking: voiceIsSpeaking)) {
      final result = await lane.send(frame);
      results.add(result);
      if (!result.delivered) break;
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
      List<Uint8List> layers, MediaType type) {
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
      return ReceivedMedia(type, bytes,
          layerIndex: framed[5], layerCount: framed[6]);
    }
    final compressed = Uint8List.sublistView(framed, 5);
    switch (type) {
      case MediaType.audioPcm:
        return ReceivedMedia(
            type, QuantizedLpc.decode(_cm.decompress(compressed), originalLen));
      case MediaType.document:
      case MediaType.photo:
      case MediaType.flipbook:
        return ReceivedMedia(type, _cm.decompress(compressed));
    }
  }
}
