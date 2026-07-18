/// Unit tests for the pure mapping helpers of
/// [FlutterWebRtcPeerConnectionPort]: standard-stats aggregation into
/// [RawRtcCounters] and connection-state mapping. `StatsReport` is a plain
/// data class, so no platform channel is involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:media_webrtc/media_webrtc.dart';
import 'package:media_webrtc_flutter/media_webrtc_flutter.dart';

rtc.StatsReport _report(String id, String type, Map<dynamic, dynamic> values) {
  return rtc.StatsReport(id, type, 0, values);
}

void main() {
  group('countersFromStats', () {
    test('returns null when no rtp streams are reported yet', () {
      final counters = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('t1', 'transport', {'selectedCandidatePairId': 'cp1'}),
        _report('cp1', 'candidate-pair', {'currentRoundTripTime': 0.05}),
      ]);
      expect(counters, isNull);
    });

    test('aggregates inbound/outbound and resolves the selected pair via '
        'transport.selectedCandidatePairId', () {
      final counters = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('in-audio', 'inbound-rtp', {
          'kind': 'audio',
          'packetsReceived': 100,
          'packetsLost': 2,
          'bytesReceived': 8000,
          'jitter': 0.012,
        }),
        _report('in-video', 'inbound-rtp', {
          'kind': 'video',
          'packetsReceived': 50,
          'packetsLost': 1,
          'bytesReceived': 4000,
          'jitter': 0.030,
        }),
        _report('out-audio', 'outbound-rtp', {
          'packetsSent': 90,
          'bytesSent': 7000,
        }),
        _report('t1', 'transport', {'selectedCandidatePairId': 'cp2'}),
        _report('cp1', 'candidate-pair', {
          'currentRoundTripTime': 0.9,
          'availableOutgoingBitrate': 1.0,
        }),
        _report('cp2', 'candidate-pair', {
          'currentRoundTripTime': 0.05,
          'availableOutgoingBitrate': 300000.0,
        }),
      ])!;

      expect(counters.packetsReceived, 150);
      expect(counters.packetsLost, 3);
      expect(counters.packetsSent, 90);
      expect(counters.bytesReceived, 12000);
      expect(counters.bytesSent, 7000);
      // Audio jitter preferred over video's 0.030, seconds preserved.
      expect(counters.jitterSeconds, 0.012);
      expect(counters.currentRoundTripTimeSeconds, 0.05);
      expect(counters.availableOutgoingBitrateBps, 300000.0);
    });

    test('falls back to the nominated+succeeded candidate pair and parses '
        'string-typed platform values', () {
      final counters = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('in1', 'inbound-rtp', {
          'kind': 'audio',
          'packetsReceived': '10',
          'packetsLost': '0',
          'bytesReceived': '800',
          'jitter': '0.005',
        }),
        _report('cp1', 'candidate-pair', {
          'nominated': true,
          'state': 'succeeded',
          'currentRoundTripTime': '0.08',
          'availableOutgoingBitrate': '128000',
        }),
      ])!;

      expect(counters.packetsReceived, 10);
      expect(counters.bytesReceived, 800);
      expect(counters.jitterSeconds, 0.005);
      expect(counters.currentRoundTripTimeSeconds, 0.08);
      expect(counters.availableOutgoingBitrateBps, 128000);
    });

    test('reports null RTT/bitrate when no pair is selected', () {
      final counters = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('out1', 'outbound-rtp', {'packetsSent': 5, 'bytesSent': 500}),
      ])!;
      expect(counters.currentRoundTripTimeSeconds, isNull);
      expect(counters.availableOutgoingBitrateBps, isNull);
      expect(counters.jitterSeconds, 0.0);
    });

    test("falls back to 'mediaType' when 'kind' is absent, identically to "
        "an equivalent report keyed by 'kind'", () {
      final byMediaType = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('in1', 'inbound-rtp', {
          'mediaType': 'audio',
          'packetsReceived': 20,
          'packetsLost': 0,
          'bytesReceived': 1600,
          'jitter': 0.02,
        }),
      ])!;
      final byKind = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('in1', 'inbound-rtp', {
          'kind': 'audio',
          'packetsReceived': 20,
          'packetsLost': 0,
          'bytesReceived': 1600,
          'jitter': 0.02,
        }),
      ])!;

      // The audio jitter branch is only taken when the media-type key
      // (whichever of the two is present) resolves to 'audio'.
      expect(byMediaType.jitterSeconds, 0.02);
      expect(byMediaType.jitterSeconds, byKind.jitterSeconds);
      expect(byMediaType.packetsReceived, byKind.packetsReceived);
      expect(byMediaType.bytesReceived, byKind.bytesReceived);
    });

    test('parses String-typed platform-channel numeric values for both '
        '_asInt and _asDoubleOrNull call sites', () {
      final counters = FlutterWebRtcPeerConnectionPort.countersFromStats([
        _report('in1', 'inbound-rtp', {
          'kind': 'audio',
          // String ints exercise _asInt's String branch.
          'packetsReceived': '1500',
          'packetsLost': '12',
          'bytesReceived': '900000',
          // String double exercises _asDoubleOrNull's String branch.
          'jitter': '0.021',
        }),
        _report('out1', 'outbound-rtp', {
          'packetsSent': '1400',
          'bytesSent': '850000',
        }),
        _report('cp1', 'candidate-pair', {
          'selected': true,
          // Strings again, on the candidate-pair side.
          'currentRoundTripTime': '0.045',
          'availableOutgoingBitrate': '500000',
        }),
      ])!;

      expect(counters.packetsReceived, 1500);
      expect(counters.packetsLost, 12);
      expect(counters.bytesReceived, 900000);
      expect(counters.packetsSent, 1400);
      expect(counters.bytesSent, 850000);
      expect(counters.jitterSeconds, 0.021);
      expect(counters.currentRoundTripTimeSeconds, 0.045);
      expect(counters.availableOutgoingBitrateBps, 500000.0);
    });
  });

  group('mapConnectionState', () {
    test('maps the five reactive states and drops "new"', () {
      const map = FlutterWebRtcPeerConnectionPort.mapConnectionState;
      expect(map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew), isNull);
      expect(
        map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting),
        PeerConnectionStatus.connecting,
      );
      expect(
        map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected),
        PeerConnectionStatus.connected,
      );
      expect(
        map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected),
        PeerConnectionStatus.disconnected,
      );
      expect(
        map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed),
        PeerConnectionStatus.failed,
      );
      expect(
        map(rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed),
        PeerConnectionStatus.closed,
      );
    });
  });
}
