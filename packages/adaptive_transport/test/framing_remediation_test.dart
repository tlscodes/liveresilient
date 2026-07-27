import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

void main() {
  group('MicroDatagramLane u16 pad trailer (MTU truncation regression)', () {
    test('full-MTU blockSize 1400: padLength > 255 roundtrips bit-exact', () {
      final lane =
          MicroDatagramLane(allowInsecureRandom: true, random: Random(42));
      // Payload 100 with blockSize 1400 forces padLength >= 1268 — the
      // exact input that wrapped mod 256 under the single-byte trailer.
      for (var trial = 0; trial < 50; trial++) {
        final payload = Uint8List.fromList(
            List.generate(100 + trial, (i) => (i * 37 + trial) & 0xFF));
        final padded = lane.encodeWithPadding(payload, blockSize: 1400);
        expect(padded.length % 1400, 0);
        final int recordedPad =
            (padded[padded.length - 2] << 8) | padded[padded.length - 1];
        expect(recordedPad, greaterThan(255),
            reason: 'this trial must exercise the >255 pad regime');
        expect(lane.decodeAndStripPadding(padded), equals(payload));
      }
    });

    test('blockSize 1500 and other MTU-scale sizes roundtrip', () {
      final lane =
          MicroDatagramLane(allowInsecureRandom: true, random: Random(7));
      for (final bs in [16, 64, 223, 224, 256, 1400, 1500]) {
        for (final len in [0, 1, 100, 1499, 4096]) {
          final payload =
              Uint8List.fromList(List.generate(len, (i) => i & 0xFF));
          final padded = lane.encodeWithPadding(payload, blockSize: bs);
          expect(padded.length % bs, 0, reason: 'blockSize $bs len $len');
          expect(lane.decodeAndStripPadding(padded), equals(payload),
              reason: 'blockSize $bs len $len');
        }
      }
    });

    test('blockSize outside [1, maxBlockSize] is rejected up front', () {
      final lane = MicroDatagramLane();
      expect(() => lane.encodeWithPadding(Uint8List(4), blockSize: 0),
          throwsArgumentError);
      expect(
          () => lane.encodeWithPadding(Uint8List(4),
              blockSize: MicroDatagramLane.maxBlockSize + 1),
          throwsArgumentError);
      // The boundary itself is provably safe for the u16 trailer.
      final ok = lane.encodeWithPadding(Uint8List(4),
          blockSize: MicroDatagramLane.maxBlockSize);
      expect(lane.decodeAndStripPadding(ok), equals(Uint8List(4)));
    });

    test('corrupted trailer throws instead of returning wrong bytes', () {
      final lane = MicroDatagramLane();
      expect(() => lane.decodeAndStripPadding(Uint8List(0)),
          throwsFormatException);
      expect(() => lane.decodeAndStripPadding(Uint8List.fromList([1])),
          throwsFormatException);
      final padded = lane.encodeWithPadding(Uint8List(10), blockSize: 16);
      // Claim more padding than the frame holds.
      padded[padded.length - 2] = 0xFF;
      padded[padded.length - 1] = 0xFF;
      expect(() => lane.decodeAndStripPadding(padded), throwsFormatException);
    });

    test('injected non-secure RNG requires explicit opt-in', () {
      expect(() => MicroDatagramLane(random: Random(1)), throwsArgumentError);
      expect(
          MicroDatagramLane(random: Random(1), allowInsecureRandom: true),
          isA<MicroDatagramLane>());
    });

    test('block-count jitter breaks rigid quantization', () {
      final lane =
          MicroDatagramLane(allowInsecureRandom: true, random: Random(3));
      final payload = Uint8List(100);
      final blockCounts = <int>{};
      for (var i = 0; i < 200; i++) {
        blockCounts
            .add(lane.encodeWithPadding(payload, blockSize: 64).length ~/ 64);
      }
      expect(blockCounts.length, greaterThanOrEqualTo(3),
          reason: 'identical payloads must spread across multiple '
              'block counts, not one fixed multiple');
    });
  });

  group('RFC 8831 UTF-8 string framing', () {
    final framer = SctpDataChannelFramer();
    test('non-ASCII and emoji encode as strict UTF-8 bytes', () {
      for (final s in ['é', 'سلام', '🎧 voice', 'híⅢ😀']) {
        final msg = framer.encodeString(s);
        expect(msg.ppid, SctpDataChannelFramer.ppidString);
        expect(msg.payload, equals(utf8.encode(s)),
            reason: 'wire bytes for "$s" must be UTF-8, not UTF-16 units');
        expect(utf8.decode(framer.decode(msg)), s);
      }
    });
  });

  group('RFC 9113 handshake framing', () {
    test('connection preface bytes are exact (section 3.4)', () {
      expect(ascii.decode(http2ConnectionPreface),
          'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n');
      expect(http2ConnectionPreface.length, 24);
    });

    test('SETTINGS frame roundtrips on stream 0', () {
      final frame = Http2SettingsFrame(settings: {
        Http2SettingsFrame.settingsMaxFrameSize: 16384,
        Http2SettingsFrame.settingsInitialWindowSize: 65535,
        Http2SettingsFrame.settingsEnablePush: 0,
      }).encode();
      expect(frame[3], Http2SettingsFrame.frameTypeSettings);
      expect(frame.sublist(5, 9), [0, 0, 0, 0]); // stream 0
      final decoded = Http2SettingsFrame.decode(frame);
      expect(decoded.ack, isFalse);
      expect(decoded.settings[Http2SettingsFrame.settingsMaxFrameSize], 16384);
      expect(
          decoded.settings[Http2SettingsFrame.settingsInitialWindowSize],
          65535);
      expect(decoded.settings[Http2SettingsFrame.settingsEnablePush], 0);
    });

    test('SETTINGS ACK is empty; non-empty ACK is FRAME_SIZE_ERROR', () {
      final ack = const Http2SettingsFrame(ack: true).encode();
      expect(ack.length, Http2DataFrame.headerLength);
      expect(Http2SettingsFrame.decode(ack).ack, isTrue);
      expect(
          () => Http2SettingsFrame(
              ack: true,
              settings: {Http2SettingsFrame.settingsEnablePush: 0}).encode(),
          throwsArgumentError);
      final bad = Uint8List.fromList(
          const Http2SettingsFrame(ack: true).encode() + [0, 5, 0, 0, 0, 1]);
      bad[2] = 6;
      expect(() => Http2SettingsFrame.decode(bad), throwsFormatException);
    });

    test('SETTINGS on a non-zero stream or ragged payload is rejected', () {
      final frame = Http2SettingsFrame(
          settings: {Http2SettingsFrame.settingsEnablePush: 1}).encode();
      final onStream = Uint8List.fromList(frame)..[8] = 3;
      expect(() => Http2SettingsFrame.decode(onStream), throwsFormatException);
      final ragged = Uint8List.fromList(frame.sublist(0, frame.length - 1));
      ragged[2] = 5;
      expect(() => Http2SettingsFrame.decode(ragged), throwsFormatException);
    });

    test('HEADERS frame roundtrips with END_HEADERS/END_STREAM flags', () {
      final block = Uint8List.fromList([0x82, 0x86, 0x84, 0x41, 0x0f]);
      final frame = Http2HeadersFrame(
        streamId: 1,
        headerBlockFragment: block,
        endStream: true,
      ).encode();
      expect(frame[3], Http2HeadersFrame.frameTypeHeaders);
      final decoded = Http2HeadersFrame.decode(frame);
      expect(decoded.streamId, 1);
      expect(decoded.endHeaders, isTrue);
      expect(decoded.endStream, isTrue);
      expect(decoded.headerBlockFragment, equals(block));
    });

    test('HEADERS on stream 0 rejected both directions', () {
      expect(
          () => Http2HeadersFrame(
              streamId: 0, headerBlockFragment: Uint8List(1)).encode(),
          throwsArgumentError);
      final frame = Http2HeadersFrame(
              streamId: 1, headerBlockFragment: Uint8List(1))
          .encode();
      final zeroed = Uint8List.fromList(frame)..[8] = 0;
      expect(() => Http2HeadersFrame.decode(zeroed), throwsFormatException);
    });
  });

  group('RFC 8832 DCEP handshake', () {
    test('DATA_CHANNEL_OPEN roundtrips, UTF-8 label, PPID 50', () {
      final open = const DcepDataChannelOpen(
        channelType: DcepDataChannelOpen.channelTypePartialReliableRexmit,
        priority: 7,
        reliabilityParameter: 3,
        label: 'media-لاین',
        protocol: 'rateless/1',
      ).encode();
      expect(open.ppid, SctpDataChannelFramer.ppidDcep);
      expect(open.payload[0], DcepDataChannelOpen.messageType);
      final decoded = DcepDataChannelOpen.decode(open);
      expect(decoded.channelType,
          DcepDataChannelOpen.channelTypePartialReliableRexmit);
      expect(decoded.priority, 7);
      expect(decoded.reliabilityParameter, 3);
      expect(decoded.label, 'media-لاین');
      expect(decoded.protocol, 'rateless/1');
    });

    test('DATA_CHANNEL_ACK roundtrips and rejects malformed input', () {
      final ack = const DcepDataChannelAck().encode();
      expect(ack.ppid, SctpDataChannelFramer.ppidDcep);
      expect(ack.payload, [DcepDataChannelAck.messageType]);
      expect(DcepDataChannelAck.decode(ack), isA<DcepDataChannelAck>());
      expect(
          () => DcepDataChannelAck.decode(DataChannelMessage(
              ppid: SctpDataChannelFramer.ppidDcep,
              payload: Uint8List.fromList([0x03]))),
          throwsFormatException);
      expect(
          () => DcepDataChannelAck.decode(DataChannelMessage(
              ppid: SctpDataChannelFramer.ppidBinary,
              payload: Uint8List.fromList([0x02]))),
          throwsFormatException);
    });

    test('truncated / length-mismatched OPEN rejected', () {
      final good = const DcepDataChannelOpen(label: 'x').encode();
      expect(
          () => DcepDataChannelOpen.decode(DataChannelMessage(
              ppid: SctpDataChannelFramer.ppidDcep,
              payload: Uint8List.sublistView(good.payload, 0, 11))),
          throwsFormatException);
      final lying = Uint8List.fromList(good.payload);
      lying[9] = 200; // labelLength now exceeds the body
      expect(
          () => DcepDataChannelOpen.decode(DataChannelMessage(
              ppid: SctpDataChannelFramer.ppidDcep, payload: lying)),
          throwsFormatException);
    });
  });
}
