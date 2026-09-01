import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc_flutter/src/flutter_webrtc_peer_connection_port.dart';

/// `createPeerConnection` needs a device, so the config it would be handed is
/// built by a pure function and asserted here instead. This is the test that
/// would have caught the original bug: every call was placed with an empty ICE
/// server list because nothing ever passed one in.
void main() {
  group('buildPeerConnectionConfig', () {
    test('carries the ICE servers it is given', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
        iceServers: const [
          {
            'urls': ['turns:relay.example:443'],
            'username': 'u',
            'credential': 'c',
          },
        ],
      );
      expect(cfg['iceServers'], hasLength(1));
      expect((cfg['iceServers'] as List).first, containsPair('username', 'u'));
    });

    test(
      'defaults to policy all — relaying everything is never the default',
      () {
        final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig();
        expect(cfg['iceTransportPolicy'], 'all');
        expect(cfg['iceServers'], isEmpty);
      },
    );

    test('passes relay policy through when asked', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig(
        iceTransportPolicy: 'relay',
      );
      expect(cfg['iceTransportPolicy'], 'relay');
    });

    test('keeps unified-plan semantics', () {
      final cfg = FlutterWebRtcPeerConnectionPort.buildPeerConnectionConfig();
      expect(cfg['sdpSemantics'], 'unified-plan');
    });
  });
}
