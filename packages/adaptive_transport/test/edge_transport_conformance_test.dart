import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

void main() {
  group('MicroDatagramLane', () {
    test('restores payload bit-exact across variable length inputs', () {
      final lane = MicroDatagramLane(allowInsecureRandom: true, random: Random(1));
      for (final len in [0, 1, 15, 16, 17, 63, 64, 200]) {
        final payload = Uint8List.fromList(
          List.generate(len, (i) => i % 256),
        );
        final padded = lane.encodeWithPadding(payload);
        expect(padded.length % 16, 0);
        final restored = lane.decodeAndStripPadding(padded);
        expect(restored, equals(payload));
      }
    });

    test('rejects a frame whose padding length exceeds the frame', () {
      final lane = MicroDatagramLane();
      final bogus = Uint8List.fromList([1, 2, 250]);
      expect(() => lane.decodeAndStripPadding(bogus), throwsFormatException);
    });

    test('rejects an empty frame', () {
      final lane = MicroDatagramLane();
      expect(
        () => lane.decodeAndStripPadding(Uint8List(0)),
        throwsFormatException,
      );
    });
  });

  group('TlsParameterNormalizer', () {
    test('emits valid RFC 8701 GREASE values', () {
      final normalizer = TlsParameterNormalizer();
      for (var i = 0; i < 50; i++) {
        final v = normalizer.pickGreaseValue();
        expect(normalizer.isGreaseValue(v), isTrue);
        expect(v & 0x0F0F, 0x0A0A);
      }
    });

    test('cipher suite list leads with a GREASE value then standard suites',
        () {
      final normalizer = TlsParameterNormalizer();
      final suites = normalizer.buildCipherSuites();
      expect(normalizer.isGreaseValue(suites.first), isTrue);
      expect(suites.skip(1), contains(0x1301));
      expect(suites.toSet().length, suites.length);
    });

    test('standard ALPN protocol list matches RFC-registered identifiers',
        () {
      expect(
        TlsParameterNormalizer.standardAlpnProtocols,
        equals(['h2', 'http/1.1']),
      );
    });
  });

  group('Http2DataFrame (RFC 9113)', () {
    test('header matches the RFC 9113 section 4.1 layout', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame =
          Http2DataFrame(streamId: 0x01020304, payload: payload, endStream: true)
              .encode();
      expect(frame.length, Http2DataFrame.headerLength + payload.length);
      expect(frame.sublist(0, 3), [0x00, 0x00, 0x05]); // Length (24)
      expect(frame[3], Http2DataFrame.frameTypeData);
      expect(frame[4], Http2DataFrame.flagEndStream);
      expect(frame[5] & 0x80, 0); // Reserved bit must be clear.
      expect(frame.sublist(5, 9), [0x01, 0x02, 0x03, 0x04]);
      expect(frame.sublist(9), payload);
    });

    test('round-trips payloads bit-exact including the max frame size', () {
      for (final len in [1, 15, 16, 1500, Http2DataFrame.defaultMaxFrameSize]) {
        final payload =
            Uint8List.fromList(List<int>.generate(len, (i) => (i * 37) & 0xFF));
        final decoded = Http2DataFrame.decode(
          Http2DataFrame(streamId: 3, payload: payload).encode(),
        );
        expect(decoded.streamId, 3);
        expect(decoded.endStream, isFalse);
        expect(decoded.payload, payload, reason: 'length $len');
      }
    });

    test('rejects stream 0, oversized payloads and truncated frames', () {
      expect(
        () => Http2DataFrame(streamId: 0, payload: Uint8List(4)).encode(),
        throwsArgumentError,
      );
      expect(
        () => Http2DataFrame(
          streamId: 1,
          payload: Uint8List(Http2DataFrame.defaultMaxFrameSize + 1),
        ).encode(),
        throwsArgumentError,
      );
      expect(
        () => Http2DataFrame.decode(Uint8List(8)),
        throwsA(isA<FormatException>()),
      );
      final good = Http2DataFrame(streamId: 1, payload: Uint8List(4)).encode();
      expect(
        () => Http2DataFrame.decode(Uint8List.sublistView(good, 0, 11)),
        throwsA(isA<FormatException>()),
      );
      final wrongType = Uint8List.fromList(good)..[3] = 0x01; // HEADERS
      expect(
        () => Http2DataFrame.decode(wrongType),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SctpDataChannelFramer (RFC 8831)', () {
    final framer = SctpDataChannelFramer();

    test('uses the RFC-registered PPIDs for binary and string messages', () {
      final binary = framer.encodeBinary(Uint8List.fromList([9, 8, 7]));
      expect(binary.ppid, SctpDataChannelFramer.ppidBinary);
      expect(framer.decode(binary), [9, 8, 7]);

      final text = framer.encodeString('ok');
      expect(text.ppid, SctpDataChannelFramer.ppidString);
      expect(framer.decode(text), 'ok'.codeUnits);
    });

    test('sends an empty message as one padding byte with an empty PPID', () {
      final emptyBinary = framer.encodeBinary(Uint8List(0));
      expect(emptyBinary.ppid, SctpDataChannelFramer.ppidBinaryEmpty);
      expect(emptyBinary.payload.length, 1);
      expect(emptyBinary.isEmptyMessage, isTrue);
      expect(framer.decode(emptyBinary), isEmpty);

      final emptyString = framer.encodeString('');
      expect(emptyString.ppid, SctpDataChannelFramer.ppidStringEmpty);
      expect(framer.decode(emptyString), isEmpty);
    });

    test('rejects unsupported PPIDs and malformed empty messages', () {
      expect(
        () => framer.decode(
          DataChannelMessage(
            ppid: SctpDataChannelFramer.ppidDcep,
            payload: Uint8List(1),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => framer.decode(
          DataChannelMessage(
            ppid: SctpDataChannelFramer.ppidBinaryEmpty,
            payload: Uint8List(2),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => framer.decode(
          DataChannelMessage(
            ppid: SctpDataChannelFramer.ppidBinary,
            payload: Uint8List(0),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('end-to-end encapsulation of a padded rateless datagram', () {
    test('HTTP/2 carriage recovers the payload bit-exact', () {
      final lane = MicroDatagramLane(allowInsecureRandom: true, random: Random(7));
      final framer = SctpDataChannelFramer();
      for (final len in [0, 1, 16, 17, 500, 1400]) {
        final payload =
            Uint8List.fromList(List<int>.generate(len, (i) => (i * 91) & 0xFF));
        final padded = lane.encodeWithPadding(payload);

        // Carrier A: HTTP/2 DATA frame.
        final viaHttp2 = Http2DataFrame.decode(
          Http2DataFrame(streamId: 5, payload: padded).encode(),
        );
        expect(lane.decodeAndStripPadding(viaHttp2.payload), payload,
            reason: 'http2 length $len');

        // Carrier B: WebRTC SCTP DataChannel.
        final viaDataChannel = framer.decode(framer.encodeBinary(padded));
        expect(lane.decodeAndStripPadding(viaDataChannel), payload,
            reason: 'datachannel length $len');
      }
    });

    test('padded frames land on the MTU block boundary', () {
      final lane = MicroDatagramLane(allowInsecureRandom: true, random: Random(11));
      for (final len in [0, 5, 31, 64, 700]) {
        final padded = lane.encodeWithPadding(Uint8List(len), blockSize: 64);
        expect(padded.length % 64, 0, reason: 'length $len');
        expect(
          padded.length + Http2DataFrame.headerLength <=
              Http2DataFrame.defaultMaxFrameSize,
          isTrue,
        );
      }
    });
  });
}
