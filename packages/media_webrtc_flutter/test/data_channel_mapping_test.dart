/// Pure mapping tests for the data-channel binding — same scope discipline
/// as stats_mapping_test.dart: the plugin's own behavior is device-bound,
/// but every conversion this adapter performs is testable here.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc/media_webrtc.dart';
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';

void main() {
  group('mapDataChannelState', () {
    test('maps all four plugin states, total function', () {
      expect(
        mapDataChannelState(rtc.RTCDataChannelState.RTCDataChannelConnecting),
        MediaDataChannelState.connecting,
      );
      expect(
        mapDataChannelState(rtc.RTCDataChannelState.RTCDataChannelOpen),
        MediaDataChannelState.open,
      );
      expect(
        mapDataChannelState(rtc.RTCDataChannelState.RTCDataChannelClosing),
        MediaDataChannelState.closing,
      );
      expect(
        mapDataChannelState(rtc.RTCDataChannelState.RTCDataChannelClosed),
        MediaDataChannelState.closed,
      );
      // Exhaustiveness: if the plugin ever adds a state, the switch in the
      // adapter stops compiling — this test documents the current total set.
      expect(rtc.RTCDataChannelState.values, hasLength(4));
    });
  });

  group('frameBytesFromMessage', () {
    test('binary message passes through byte-identical', () {
      final bytes = Uint8List.fromList([0, 1, 2, 255, 128]);
      final message = rtc.RTCDataChannelMessage.fromBinary(bytes);
      expect(frameBytesFromMessage(message), bytes);
    });

    test('text message arrives as its UTF-8 bytes (wire codec sees the '
        'same bytes either way)', () {
      const text = '{"t":"msg","body":"سلام"}';
      final message = rtc.RTCDataChannelMessage(text);
      expect(frameBytesFromMessage(message), utf8.encode(text));
    });

    test('empty binary frame maps to an empty byte list, not null', () {
      final message = rtc.RTCDataChannelMessage.fromBinary(Uint8List(0));
      expect(frameBytesFromMessage(message), isEmpty);
    });
  });
}
