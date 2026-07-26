/// Phase 8 — the wire side of the media facade: taking a queued rateless
/// datagram from length-normalized bytes to something an ordinary carrier
/// accepts, and back again.
///
/// The queue hands out `TaggedDatagram(transferId, bytes)`, where the transfer
/// id is out-of-band metadata. On a real wire it has to travel somewhere, and
/// each carrier already has the right place for it:
///
/// - **HTTP/2** (RFC 9113): the DATA frame's stream identifier. One transfer is
///   one stream, using client-initiated odd identifiers (RFC 9113 section
///   5.1.1), so the framing carries the routing with zero added bytes.
/// - **WebRTC DataChannel** (RFC 8831): SCTP delivers one message per send with
///   no per-message stream field available to us here, so the transfer id rides
///   as a 2-byte big-endian prefix inside the message. That is 2 bytes of real
///   overhead, stated plainly rather than hidden.
///
/// Both paths pad to an MTU block boundary first (RFC 3711 style), so datagram
/// length does not vary with payload content.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';

import 'media_queue.dart';

enum MediaCarrier { http2DataFrame, sctpDataChannel }

/// One datagram recovered from the wire.
class CarriedDatagram {
  const CarriedDatagram(this.transferId, this.bytes);
  final int transferId;
  final Uint8List bytes;
}

/// Wraps and unwraps queue datagrams for one carrier.
class MediaCarriage {
  MediaCarriage({
    this.carrier = MediaCarrier.http2DataFrame,
    this.mtuBlockSize = 64,
    MicroDatagramLane? lane,
    SctpDataChannelFramer? framer,
    Random? random,
  })  : lane = lane ?? MicroDatagramLane(random: random ?? Random.secure()),
        _framer = framer ?? SctpDataChannelFramer() {
    if (mtuBlockSize < 1) {
      throw ArgumentError.value(mtuBlockSize, 'mtuBlockSize', 'must be >= 1');
    }
  }

  final MediaCarrier carrier;

  /// Datagrams are padded up to a multiple of this many bytes.
  final int mtuBlockSize;

  final MicroDatagramLane lane;
  final SctpDataChannelFramer _framer;

  /// Highest transfer id the carrier can express.
  static const int maxTransferId = 0xFFFF;

  /// HTTP/2 stream identifier for [transferId]: client-initiated streams are
  /// odd-numbered (RFC 9113 section 5.1.1).
  static int streamIdFor(int transferId) => transferId * 2 + 1;

  static int transferIdForStream(int streamId) {
    if (streamId <= 0 || streamId.isEven) {
      throw FormatException(
        'Expected a client-initiated odd stream id, got $streamId',
      );
    }
    return (streamId - 1) ~/ 2;
  }

  Uint8List wrap(TaggedDatagram datagram) {
    if (datagram.transferId < 0 || datagram.transferId > maxTransferId) {
      throw ArgumentError.value(
        datagram.transferId,
        'transferId',
        'must fit in 16 bits for either carrier',
      );
    }
    final padded = lane.encodeWithPadding(
      datagram.bytes,
      blockSize: mtuBlockSize,
    );
    switch (carrier) {
      case MediaCarrier.http2DataFrame:
        return Http2DataFrame(
          streamId: streamIdFor(datagram.transferId),
          payload: padded,
        ).encode();
      case MediaCarrier.sctpDataChannel:
        final body = Uint8List(2 + padded.length);
        body[0] = (datagram.transferId >> 8) & 0xFF;
        body[1] = datagram.transferId & 0xFF;
        body.setRange(2, body.length, padded);
        return _framer.encodeBinary(body).payload;
    }
  }

  CarriedDatagram unwrap(Uint8List wire) {
    switch (carrier) {
      case MediaCarrier.http2DataFrame:
        final frame = Http2DataFrame.decode(wire);
        return CarriedDatagram(
          transferIdForStream(frame.streamId),
          lane.decodeAndStripPadding(frame.payload),
        );
      case MediaCarrier.sctpDataChannel:
        final body = _framer.decode(
          DataChannelMessage(
            ppid: SctpDataChannelFramer.ppidBinary,
            payload: wire,
          ),
        );
        if (body.length < 3) {
          throw FormatException(
            'DataChannel message too short to carry a transfer id and a '
            'padded datagram: ${body.length} bytes',
          );
        }
        return CarriedDatagram(
          (body[0] << 8) | body[1],
          lane.decodeAndStripPadding(Uint8List.sublistView(body, 2)),
        );
    }
  }

  /// Bytes this carrier adds on top of the padded datagram.
  int get framingOverheadBytes => switch (carrier) {
        MediaCarrier.http2DataFrame => Http2DataFrame.headerLength,
        MediaCarrier.sctpDataChannel => 2,
      };
}
