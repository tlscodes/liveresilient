import 'dart:typed_data';

/// Encapsulation of rateless datagrams inside standard carrier framings so the
/// media transport can ride an ordinary HTTP/2 connection (RFC 9113) or a
/// WebRTC SCTP DataChannel (RFC 8831) instead of a bespoke wire format.
///
/// Both framings here are byte-exact and reversible: `decode` on the output of
/// `encode` returns the original payload with no loss.

/// RFC 9113 section 6.1 DATA frame.
///
/// Frame header layout (RFC 9113 section 4.1), 9 bytes:
///   Length (24) | Type (8) | Flags (8) | R (1) + Stream Identifier (31)
class Http2DataFrame {
  const Http2DataFrame({
    required this.streamId,
    required this.payload,
    this.endStream = false,
  });

  /// DATA frame type code (RFC 9113 section 6.1).
  static const int frameTypeData = 0x0;

  /// END_STREAM flag (RFC 9113 section 6.1).
  static const int flagEndStream = 0x1;

  /// Fixed frame-header size in bytes (RFC 9113 section 4.1).
  static const int headerLength = 9;

  /// Minimum value a peer must accept for SETTINGS_MAX_FRAME_SIZE
  /// (RFC 9113 section 6.5.2).
  static const int defaultMaxFrameSize = 16384;

  final int streamId;
  final Uint8List payload;
  final bool endStream;

  /// Serializes the frame. A DATA frame must carry a client-initiated,
  /// non-zero stream identifier (RFC 9113 sections 5.1.1 and 6.1).
  Uint8List encode({int maxFrameSize = defaultMaxFrameSize}) {
    if (streamId <= 0 || streamId > 0x7FFFFFFF) {
      throw ArgumentError.value(
        streamId,
        'streamId',
        'DATA frames require a non-zero 31-bit stream identifier',
      );
    }
    if (payload.length > maxFrameSize) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'exceeds max frame size $maxFrameSize',
      );
    }
    final frame = Uint8List(headerLength + payload.length);
    final int length = payload.length;
    frame[0] = (length >> 16) & 0xFF;
    frame[1] = (length >> 8) & 0xFF;
    frame[2] = length & 0xFF;
    frame[3] = frameTypeData;
    frame[4] = endStream ? flagEndStream : 0x0;
    frame[5] = (streamId >> 24) & 0x7F; // R bit stays 0.
    frame[6] = (streamId >> 16) & 0xFF;
    frame[7] = (streamId >> 8) & 0xFF;
    frame[8] = streamId & 0xFF;
    frame.setRange(headerLength, frame.length, payload);
    return frame;
  }

  /// Parses one serialized DATA frame. Throws [FormatException] on a truncated
  /// frame, a non-DATA type, or a zero stream identifier.
  static Http2DataFrame decode(Uint8List frame) {
    if (frame.length < headerLength) {
      throw FormatException('HTTP/2 frame shorter than header: ${frame.length}');
    }
    final int length = (frame[0] << 16) | (frame[1] << 8) | frame[2];
    if (frame[3] != frameTypeData) {
      throw FormatException('Not a DATA frame: type 0x${frame[3].toRadixString(16)}');
    }
    if (frame.length != headerLength + length) {
      throw FormatException(
        'DATA frame length mismatch: header says $length, '
        'body is ${frame.length - headerLength}',
      );
    }
    final int streamId = ((frame[5] & 0x7F) << 24) |
        (frame[6] << 16) |
        (frame[7] << 8) |
        frame[8];
    if (streamId == 0) {
      throw const FormatException('DATA frame on stream 0');
    }
    return Http2DataFrame(
      streamId: streamId,
      payload: Uint8List.sublistView(frame, headerLength),
      endStream: (frame[4] & flagEndStream) != 0,
    );
  }
}

/// One WebRTC DataChannel message: an SCTP payload protocol identifier plus the
/// bytes the receiver hands to the application (RFC 8831 section 8).
class DataChannelMessage {
  const DataChannelMessage({required this.ppid, required this.payload});

  final int ppid;
  final Uint8List payload;

  bool get isEmptyMessage =>
      ppid == SctpDataChannelFramer.ppidBinaryEmpty ||
      ppid == SctpDataChannelFramer.ppidStringEmpty;
}

/// Builds and parses WebRTC DataChannel messages per RFC 8831.
///
/// An empty application message cannot be sent as a zero-length SCTP user
/// message, so RFC 8831 section 6.6 sends a single padding byte with a
/// dedicated "empty" PPID; the receiver discards that byte.
class SctpDataChannelFramer {
  /// PPIDs registered by RFC 8831 section 8.
  static const int ppidDcep = 50;
  static const int ppidString = 51;
  static const int ppidBinary = 53;
  static const int ppidStringEmpty = 56;
  static const int ppidBinaryEmpty = 57;

  DataChannelMessage encodeBinary(Uint8List payload) {
    if (payload.isEmpty) {
      return DataChannelMessage(
        ppid: ppidBinaryEmpty,
        payload: Uint8List.fromList(const [0]),
      );
    }
    return DataChannelMessage(ppid: ppidBinary, payload: payload);
  }

  DataChannelMessage encodeString(String text) {
    if (text.isEmpty) {
      return DataChannelMessage(
        ppid: ppidStringEmpty,
        payload: Uint8List.fromList(const [0]),
      );
    }
    return DataChannelMessage(
      ppid: ppidString,
      payload: Uint8List.fromList(text.codeUnits),
    );
  }

  /// Returns the application bytes carried by [message], dropping the RFC 8831
  /// padding byte of an empty message.
  Uint8List decode(DataChannelMessage message) {
    switch (message.ppid) {
      case ppidBinaryEmpty:
      case ppidStringEmpty:
        if (message.payload.length != 1) {
          throw FormatException(
            'Empty-message PPID ${message.ppid} must carry exactly one '
            'padding byte, got ${message.payload.length}',
          );
        }
        return Uint8List(0);
      case ppidBinary:
      case ppidString:
        if (message.payload.isEmpty) {
          throw FormatException(
            'PPID ${message.ppid} requires a non-empty user message',
          );
        }
        return message.payload;
      default:
        throw FormatException('Unsupported DataChannel PPID: ${message.ppid}');
    }
  }
}
