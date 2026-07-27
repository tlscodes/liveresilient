import 'dart:convert';
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
      throw FormatException(
        'HTTP/2 frame shorter than header: ${frame.length}',
      );
    }
    final int length = (frame[0] << 16) | (frame[1] << 8) | frame[2];
    if (frame[3] != frameTypeData) {
      throw FormatException(
        'Not a DATA frame: type 0x${frame[3].toRadixString(16)}',
      );
    }
    if (frame.length != headerLength + length) {
      throw FormatException(
        'DATA frame length mismatch: header says $length, '
        'body is ${frame.length - headerLength}',
      );
    }
    final int streamId =
        ((frame[5] & 0x7F) << 24) |
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
    // RFC 8831 section 8: PPID 51 carries UTF-8, not UTF-16 code units.
    return DataChannelMessage(
      ppid: ppidString,
      payload: Uint8List.fromList(utf8.encode(text)),
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

/// The fixed HTTP/2 client connection preface (RFC 9113 section 3.4):
/// "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", sent before any frame; it MUST be
/// followed by a SETTINGS frame.
final Uint8List http2ConnectionPreface = Uint8List.fromList(
  ascii.encode('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'),
);

/// RFC 9113 section 6.5 SETTINGS frame: stream 0, zero or more
/// 6-byte (u16 identifier, u32 value) pairs; an ACK carries no payload.
class Http2SettingsFrame {
  const Http2SettingsFrame({this.settings = const {}, this.ack = false});

  static const int frameTypeSettings = 0x4;
  static const int flagAck = 0x1;

  // Setting identifiers (RFC 9113 section 6.5.2).
  static const int settingsHeaderTableSize = 0x1;
  static const int settingsEnablePush = 0x2;
  static const int settingsMaxConcurrentStreams = 0x3;
  static const int settingsInitialWindowSize = 0x4;
  static const int settingsMaxFrameSize = 0x5;
  static const int settingsMaxHeaderListSize = 0x6;

  /// Identifier -> value, each value a u32.
  final Map<int, int> settings;
  final bool ack;

  Uint8List encode() {
    if (ack && settings.isNotEmpty) {
      throw ArgumentError(
        'SETTINGS ACK must carry an empty payload '
        '(RFC 9113 section 6.5)',
      );
    }
    final int length = settings.length * 6;
    final frame = Uint8List(Http2DataFrame.headerLength + length);
    frame[0] = (length >> 16) & 0xFF;
    frame[1] = (length >> 8) & 0xFF;
    frame[2] = length & 0xFF;
    frame[3] = frameTypeSettings;
    frame[4] = ack ? flagAck : 0x0;
    // Bytes 5-8 stay 0: SETTINGS applies to the connection, stream 0.
    var o = Http2DataFrame.headerLength;
    final bd = frame.buffer.asByteData();
    settings.forEach((id, value) {
      if (id < 0 || id > 0xFFFF) {
        throw ArgumentError.value(id, 'settings', 'identifier exceeds u16');
      }
      if (value < 0 || value > 0xFFFFFFFF) {
        throw ArgumentError.value(value, 'settings', 'value exceeds u32');
      }
      bd.setUint16(o, id);
      bd.setUint32(o + 2, value);
      o += 6;
    });
    return frame;
  }

  static Http2SettingsFrame decode(Uint8List frame) {
    if (frame.length < Http2DataFrame.headerLength) {
      throw FormatException(
        'SETTINGS frame shorter than header: ${frame.length}',
      );
    }
    if (frame[3] != frameTypeSettings) {
      throw FormatException(
        'Not a SETTINGS frame: type 0x${frame[3].toRadixString(16)}',
      );
    }
    final int length = (frame[0] << 16) | (frame[1] << 8) | frame[2];
    final int streamId =
        ((frame[5] & 0x7F) << 24) |
        (frame[6] << 16) |
        (frame[7] << 8) |
        frame[8];
    if (streamId != 0) {
      throw FormatException(
        'SETTINGS must be on stream 0, got stream $streamId',
      );
    }
    if (frame.length != Http2DataFrame.headerLength + length) {
      throw FormatException('SETTINGS length mismatch: header says $length');
    }
    final bool ack = (frame[4] & flagAck) != 0;
    if (ack && length != 0) {
      throw const FormatException(
        'SETTINGS ACK with non-empty payload (FRAME_SIZE_ERROR)',
      );
    }
    if (length % 6 != 0) {
      throw FormatException(
        'SETTINGS payload not a multiple of 6: $length (FRAME_SIZE_ERROR)',
      );
    }
    final settings = <int, int>{};
    final bd = frame.buffer.asByteData(
      frame.offsetInBytes,
      frame.lengthInBytes,
    );
    for (var o = Http2DataFrame.headerLength; o < frame.length; o += 6) {
      settings[bd.getUint16(o)] = bd.getUint32(o + 2);
    }
    return Http2SettingsFrame(settings: settings, ack: ack);
  }
}

/// RFC 9113 section 6.2 HEADERS frame carrying an opaque HPACK-encoded
/// header block fragment (HPACK itself, RFC 7541, is out of scope here —
/// the fragment is produced/consumed by the peer's HPACK codec).
class Http2HeadersFrame {
  const Http2HeadersFrame({
    required this.streamId,
    required this.headerBlockFragment,
    this.endHeaders = true,
    this.endStream = false,
  });

  static const int frameTypeHeaders = 0x1;
  static const int flagEndStream = 0x1;
  static const int flagEndHeaders = 0x4;

  final int streamId;
  final Uint8List headerBlockFragment;
  final bool endHeaders;
  final bool endStream;

  Uint8List encode() {
    if (streamId <= 0 || streamId > 0x7FFFFFFF) {
      throw ArgumentError.value(
        streamId,
        'streamId',
        'HEADERS requires a non-zero 31-bit stream identifier',
      );
    }
    final int length = headerBlockFragment.length;
    final frame = Uint8List(Http2DataFrame.headerLength + length);
    frame[0] = (length >> 16) & 0xFF;
    frame[1] = (length >> 8) & 0xFF;
    frame[2] = length & 0xFF;
    frame[3] = frameTypeHeaders;
    frame[4] =
        (endHeaders ? flagEndHeaders : 0) | (endStream ? flagEndStream : 0);
    frame[5] = (streamId >> 24) & 0x7F;
    frame[6] = (streamId >> 16) & 0xFF;
    frame[7] = (streamId >> 8) & 0xFF;
    frame[8] = streamId & 0xFF;
    frame.setRange(
      Http2DataFrame.headerLength,
      frame.length,
      headerBlockFragment,
    );
    return frame;
  }

  static Http2HeadersFrame decode(Uint8List frame) {
    if (frame.length < Http2DataFrame.headerLength) {
      throw FormatException(
        'HEADERS frame shorter than header: ${frame.length}',
      );
    }
    if (frame[3] != frameTypeHeaders) {
      throw FormatException(
        'Not a HEADERS frame: type 0x${frame[3].toRadixString(16)}',
      );
    }
    final int length = (frame[0] << 16) | (frame[1] << 8) | frame[2];
    if (frame.length != Http2DataFrame.headerLength + length) {
      throw FormatException('HEADERS length mismatch: header says $length');
    }
    final int streamId =
        ((frame[5] & 0x7F) << 24) |
        (frame[6] << 16) |
        (frame[7] << 8) |
        frame[8];
    if (streamId == 0) {
      throw const FormatException('HEADERS frame on stream 0');
    }
    return Http2HeadersFrame(
      streamId: streamId,
      headerBlockFragment: Uint8List.sublistView(
        frame,
        Http2DataFrame.headerLength,
      ),
      endHeaders: (frame[4] & flagEndHeaders) != 0,
      endStream: (frame[4] & flagEndStream) != 0,
    );
  }
}

/// RFC 8832 DCEP DATA_CHANNEL_OPEN message (PPID 50).
///
/// Layout: u8 msgType(0x03) · u8 channelType · u16 priority ·
/// u32 reliabilityParameter · u16 labelLength · u16 protocolLength ·
/// label · protocol.
class DcepDataChannelOpen {
  const DcepDataChannelOpen({
    this.channelType = channelTypeReliable,
    this.priority = 0,
    this.reliabilityParameter = 0,
    this.label = '',
    this.protocol = '',
  });

  static const int messageType = 0x03;

  // Channel types (RFC 8832 section 5.1).
  static const int channelTypeReliable = 0x00;
  static const int channelTypeReliableUnordered = 0x80;
  static const int channelTypePartialReliableRexmit = 0x01;
  static const int channelTypePartialReliableRexmitUnordered = 0x81;
  static const int channelTypePartialReliableTimed = 0x02;
  static const int channelTypePartialReliableTimedUnordered = 0x82;

  final int channelType;
  final int priority;
  final int reliabilityParameter;
  final String label;
  final String protocol;

  DataChannelMessage encode() {
    final labelBytes = utf8.encode(label);
    final protocolBytes = utf8.encode(protocol);
    if (labelBytes.length > 0xFFFF || protocolBytes.length > 0xFFFF) {
      throw ArgumentError('label/protocol exceed u16 length fields');
    }
    final body = Uint8List(12 + labelBytes.length + protocolBytes.length);
    final bd = body.buffer.asByteData();
    body[0] = messageType;
    body[1] = channelType;
    bd.setUint16(2, priority);
    bd.setUint32(4, reliabilityParameter);
    bd.setUint16(8, labelBytes.length);
    bd.setUint16(10, protocolBytes.length);
    body.setRange(12, 12 + labelBytes.length, labelBytes);
    body.setRange(12 + labelBytes.length, body.length, protocolBytes);
    return DataChannelMessage(
      ppid: SctpDataChannelFramer.ppidDcep,
      payload: body,
    );
  }

  static DcepDataChannelOpen decode(DataChannelMessage message) {
    if (message.ppid != SctpDataChannelFramer.ppidDcep) {
      throw FormatException('DCEP requires PPID 50, got ${message.ppid}');
    }
    final b = message.payload;
    if (b.length < 12) {
      throw FormatException(
        'DATA_CHANNEL_OPEN shorter than fixed header: '
        '${b.length}',
      );
    }
    if (b[0] != messageType) {
      throw FormatException(
        'Not DATA_CHANNEL_OPEN: type 0x${b[0].toRadixString(16)}',
      );
    }
    final bd = b.buffer.asByteData(b.offsetInBytes, b.lengthInBytes);
    final labelLen = bd.getUint16(8);
    final protocolLen = bd.getUint16(10);
    if (b.length != 12 + labelLen + protocolLen) {
      throw FormatException(
        'DATA_CHANNEL_OPEN length mismatch: header says '
        '${12 + labelLen + protocolLen}, body is ${b.length}',
      );
    }
    return DcepDataChannelOpen(
      channelType: b[1],
      priority: bd.getUint16(2),
      reliabilityParameter: bd.getUint32(4),
      label: utf8.decode(b.sublist(12, 12 + labelLen)),
      protocol: utf8.decode(b.sublist(12 + labelLen)),
    );
  }
}

/// RFC 8832 DCEP DATA_CHANNEL_ACK message (PPID 50): a single 0x02 byte.
class DcepDataChannelAck {
  const DcepDataChannelAck();

  static const int messageType = 0x02;

  DataChannelMessage encode() => DataChannelMessage(
    ppid: SctpDataChannelFramer.ppidDcep,
    payload: Uint8List.fromList(const [messageType]),
  );

  static DcepDataChannelAck decode(DataChannelMessage message) {
    if (message.ppid != SctpDataChannelFramer.ppidDcep) {
      throw FormatException('DCEP requires PPID 50, got ${message.ppid}');
    }
    if (message.payload.length != 1 || message.payload[0] != messageType) {
      throw const FormatException('Malformed DATA_CHANNEL_ACK');
    }
    return const DcepDataChannelAck();
  }
}
